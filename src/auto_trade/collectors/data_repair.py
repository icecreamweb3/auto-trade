from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.collectors.binance_usdm import (
    BinanceRateLimitError,
    BinanceUsdMClient,
)
from auto_trade.collectors.publisher import JetStreamEventPublisher
from auto_trade.collectors.service import (
    TRADE_5M_SERIES,
    BinanceCollectionService,
    KlineSeries,
)
from auto_trade.config import Settings, get_settings
from auto_trade.contracts import PriceType
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.infrastructure.nats_streams import connect, ensure_streams
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class GapRange:
    instrument_id: int
    symbol: str
    start: datetime
    end: datetime
    expected_count: int
    series: KlineSeries = TRADE_5M_SERIES


@dataclass(frozen=True, slots=True)
class BackfillJob:
    job_id: UUID
    gap_id: UUID
    instrument_id: int
    symbol: str
    start: datetime
    end: datetime
    expected_count: int
    series: KlineSeries


REPAIR_SERIES = (
    KlineSeries(PriceType.TRADE, 60),
    KlineSeries(PriceType.MARK, 60),
    TRADE_5M_SERIES,
)

MAX_KLINE_POINTS_PER_BACKFILL_JOB = 1500


def group_missing_points(
    rows: list[tuple[int, str, datetime]], interval: timedelta
) -> list[GapRange]:
    gaps: list[GapRange] = []
    current: GapRange | None = None
    for instrument_id, symbol, point in rows:
        if (
            current is not None
            and current.instrument_id == instrument_id
            and current.end == point
        ):
            current = GapRange(
                instrument_id,
                symbol,
                current.start,
                point + interval,
                current.expected_count + 1,
                current.series,
            )
            gaps[-1] = current
        else:
            current = GapRange(instrument_id, symbol, point, point + interval, 1)
            gaps.append(current)
    return gaps


def split_gap_range(
    gap: GapRange, *, max_points: int = MAX_KLINE_POINTS_PER_BACKFILL_JOB
) -> list[GapRange]:
    """Split a gap into Binance Kline API-sized jobs."""
    if max_points < 1:
        raise ValueError("max_points must be positive")
    interval = timedelta(seconds=gap.series.interval_seconds)
    maximum_span = interval * max_points
    ranges: list[GapRange] = []
    start = gap.start
    while start < gap.end:
        end = min(start + maximum_span, gap.end)
        expected_count = int((end - start) / interval)
        ranges.append(
            GapRange(
                gap.instrument_id,
                gap.symbol,
                start,
                end,
                expected_count,
                gap.series,
            )
        )
        start = end
    return ranges


def align_kline_range(
    start: datetime, end: datetime, series: KlineSeries
) -> tuple[datetime, datetime]:
    interval_seconds = series.interval_seconds
    start_epoch = int(start.timestamp()) // interval_seconds * interval_seconds
    end_epoch = int(end.timestamp()) // interval_seconds * interval_seconds
    return (
        datetime.fromtimestamp(start_epoch, tz=UTC),
        datetime.fromtimestamp(end_epoch, tz=UTC),
    )


def next_cycle_delay(
    result: dict[str, int],
    *,
    batch_limit: int,
    idle_interval_seconds: int,
) -> int:
    del batch_limit
    if result["succeeded"] + result["failed"] > 0:
        return 1
    return idle_interval_seconds


class DataRepairRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def detect_5m_gaps(self, lookback_hours: int) -> list[GapRange]:
        return await self.detect_kline_gaps(
            lookback_hours, TRADE_5M_SERIES
        )

    async def detect_kline_gaps(
        self,
        lookback_hours: int,
        series: KlineSeries,
    ) -> list[GapRange]:
        now = datetime.now(UTC).replace(microsecond=0)
        start = now - timedelta(hours=lookback_hours)
        end = now
        return await self.detect_kline_gaps_in_range(start, end, series)

    async def detect_kline_gaps_in_range(
        self,
        start: datetime,
        end: datetime,
        series: KlineSeries,
    ) -> list[GapRange]:
        aligned_start, aligned_end = align_kline_range(start, end, series)
        if aligned_start >= aligned_end:
            return []
        step = timedelta(seconds=series.interval_seconds)
        async with self._engine.connect() as connection:
            result = await connection.execute(
                text(
                    """
                    WITH expected AS (
                        SELECT i.instrument_id, i.symbol, point AS open_time
                        FROM core.instruments i
                        CROSS JOIN generate_series(
                            CAST(:range_start AS timestamptz),
                            CAST(:range_end AS timestamptz) - CAST(:step AS interval),
                            CAST(:step AS interval)
                        ) AS point
                        WHERE i.trading_status = 'TRADING'
                          AND (i.onboard_at IS NULL OR i.onboard_at <= point)
                    )
                    SELECT e.instrument_id, e.symbol, e.open_time
                    FROM expected e
                    LEFT JOIN market.klines k
                      ON k.instrument_id = e.instrument_id
                     AND k.price_type = :price_type
                     AND k.interval_seconds = :interval_seconds
                     AND k.open_time = e.open_time
                     AND k.is_current
                    LEFT JOIN market.data_gaps g
                      ON g.instrument_id = e.instrument_id
                     AND g.data_type = :data_type
                     AND g.interval_seconds = :interval_seconds
                     AND e.open_time >= g.gap_start
                     AND e.open_time < g.gap_end
                     AND g.status IN ('OPEN','QUEUED','BACKFILLING')
                    WHERE k.instrument_id IS NULL
                      AND g.gap_id IS NULL
                    ORDER BY e.instrument_id, e.open_time
                    """
                ),
                {
                    "range_start": aligned_start,
                    "range_end": aligned_end,
                    "step": step,
                    "price_type": series.price_type.value,
                    "data_type": series.data_type,
                    "interval_seconds": series.interval_seconds,
                },
            )
            rows = [
                (cast(int, row[0]), cast(str, row[1]), cast(datetime, row[2]))
                for row in result.all()
            ]
        return [
            GapRange(
                gap.instrument_id,
                gap.symbol,
                gap.start,
                gap.end,
                gap.expected_count,
                series,
            )
            for gap in group_missing_points(rows, step)
        ]

    async def queue_gaps(self, gaps: list[GapRange]) -> int:
        queued = 0
        async with self._engine.begin() as connection:
            for detected_gap in gaps:
                for gap in split_gap_range(detected_gap):
                    gap_id = cast(
                        UUID,
                        (
                            await connection.execute(
                                text(
                                    """
                                    INSERT INTO market.data_gaps (
                                        instrument_id, data_type, interval_seconds,
                                        gap_start, gap_end, expected_count, actual_count,
                                        status, detected_at, reason_code, details
                                    ) VALUES (
                                        :instrument_id, :data_type, :interval_seconds,
                                        :gap_start, :gap_end,
                                        :expected_count, 0, 'QUEUED', clock_timestamp(),
                                        'MISSING_INTERVAL', '{}'::jsonb
                                    )
                                    ON CONFLICT (
                                        instrument_id, data_type, interval_seconds,
                                        gap_start, gap_end
                                    ) DO UPDATE SET
                                        expected_count = EXCLUDED.expected_count,
                                        actual_count = 0,
                                        status = CASE
                                            WHEN market.data_gaps.status = 'VERIFIED'
                                            THEN market.data_gaps.status
                                            ELSE 'QUEUED'
                                        END
                                    RETURNING gap_id
                                    """
                                ),
                                {
                                    "instrument_id": gap.instrument_id,
                                    "data_type": gap.series.data_type,
                                    "interval_seconds": gap.series.interval_seconds,
                                    "gap_start": gap.start,
                                    "gap_end": gap.end,
                                    "expected_count": gap.expected_count,
                                },
                            )
                        ).scalar_one(),
                    )
                    result = await connection.execute(
                        text(
                            """
                            INSERT INTO market.backfill_jobs (
                                gap_id, instrument_id, data_type, range_start, range_end,
                                source_priority, status
                            )
                            SELECT :gap_id, :instrument_id, :data_type,
                                   :range_start, :range_end,
                                   '["BINANCE_REST"]'::jsonb, 'PENDING'
                            WHERE NOT EXISTS (
                                SELECT 1 FROM market.backfill_jobs
                                WHERE gap_id = :gap_id
                                  AND status IN ('PENDING','RUNNING','SUCCEEDED')
                            )
                            """
                        ),
                        {
                            "gap_id": gap_id,
                            "instrument_id": gap.instrument_id,
                            "data_type": gap.series.data_type,
                            "range_start": gap.start,
                            "range_end": gap.end,
                        },
                    )
                    queued += result.rowcount
        return queued

    async def claim_job(self) -> BackfillJob | None:
        async with self._engine.begin() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        WITH type_progress AS (
                            SELECT data_type,
                                   count(*) FILTER (WHERE status = 'SUCCEEDED') AS completed
                            FROM market.backfill_jobs
                            GROUP BY data_type
                        ), candidate AS (
                            SELECT j.backfill_job_id
                            FROM market.backfill_jobs j
                            JOIN market.data_gaps g ON g.gap_id = j.gap_id
                            LEFT JOIN type_progress p ON p.data_type = j.data_type
                            WHERE j.status = 'PENDING'
                            ORDER BY
                                CASE
                                    WHEN g.expected_count <= 5 THEN 0
                                    WHEN g.expected_count <= 60 THEN 1
                                    ELSE 2
                                END,
                                j.attempts,
                                COALESCE(p.completed, 0),
                                j.created_at
                            LIMIT 1
                            FOR UPDATE OF j SKIP LOCKED
                        )
                        UPDATE market.backfill_jobs j
                        SET status = 'RUNNING', started_at = clock_timestamp(),
                            finished_at = NULL, attempts = attempts + 1
                        FROM candidate c, core.instruments i, market.data_gaps g
                        WHERE j.backfill_job_id = c.backfill_job_id
                          AND i.instrument_id = j.instrument_id
                          AND g.gap_id = j.gap_id
                        RETURNING j.backfill_job_id, j.gap_id, j.instrument_id,
                                  i.symbol, j.range_start, j.range_end,
                                  g.expected_count, g.data_type, g.interval_seconds
                        """
                    )
                )
            ).one_or_none()
            if row is not None:
                await connection.execute(
                    text(
                        """
                        UPDATE market.data_gaps
                        SET status = 'BACKFILLING'
                        WHERE gap_id = :gap_id
                        """
                    ),
                    {"gap_id": row[1]},
                )
        if row is None:
            return None
        data_type = str(row[7])
        price_type = (
            PriceType.TRADE
            if data_type == "KLINE"
            else PriceType(data_type.removeprefix("KLINE_"))
        )
        return BackfillJob(
            cast(UUID, row[0]),
            cast(UUID, row[1]),
            cast(int, row[2]),
            cast(str, row[3]),
            cast(datetime, row[4]),
            cast(datetime, row[5]),
            cast(int, row[6]),
            KlineSeries(
                price_type,
                cast(int, row[8]),
            ),
        )

    async def recover_interrupted_jobs(
        self,
        *,
        stale_after_seconds: int,
        failed_retry_limit: int,
    ) -> dict[str, int]:
        stale_after = timedelta(seconds=stale_after_seconds)
        async with self._engine.begin() as connection:
            stale_rows = (
                await connection.execute(
                    text(
                        """
                        UPDATE market.backfill_jobs
                        SET status = 'PENDING', started_at = NULL,
                            error_details = error_details ||
                                '{"recovered_after_restart": true}'::jsonb
                        WHERE status = 'RUNNING'
                          AND started_at < clock_timestamp() - CAST(:stale_after AS interval)
                        RETURNING gap_id
                        """
                    ),
                    {"stale_after": stale_after},
                )
            ).all()
            failed_rows = (
                await connection.execute(
                    text(
                        """
                        UPDATE market.backfill_jobs
                        SET status = 'PENDING', started_at = NULL, finished_at = NULL,
                            error_details = error_details ||
                                '{"scheduled_retry": true}'::jsonb
                        WHERE status = 'FAILED'
                          AND attempts < :retry_limit
                        RETURNING gap_id
                        """
                    ),
                    {"retry_limit": failed_retry_limit},
                )
            ).all()
            gap_ids = [row[0] for row in [*stale_rows, *failed_rows]]
            if gap_ids:
                await connection.execute(
                    text(
                        """
                        UPDATE market.data_gaps
                        SET status = 'QUEUED', resolved_at = NULL
                        WHERE gap_id = ANY(CAST(:gap_ids AS uuid[]))
                        """
                    ),
                    {"gap_ids": gap_ids},
                )
        return {"stale": len(stale_rows), "failed": len(failed_rows)}

    async def _actual_count(self, job: BackfillJob) -> int:
        async with self._engine.connect() as connection:
            return cast(
                int,
                (
                    await connection.execute(
                        text(
                            """
                            SELECT count(DISTINCT open_time)
                            FROM market.klines
                            WHERE instrument_id = :instrument_id
                              AND price_type = :price_type
                              AND interval_seconds = :interval_seconds
                              AND is_current
                              AND open_time >= :range_start
                              AND open_time < :range_end
                            """
                        ),
                        {
                            "instrument_id": job.instrument_id,
                            "range_start": job.start,
                            "range_end": job.end,
                            "price_type": job.series.price_type.value,
                            "interval_seconds": job.series.interval_seconds,
                        },
                    )
                ).scalar_one(),
            )

    async def _record_result(
        self,
        job: BackfillJob,
        *,
        published: int,
        actual: int,
        prefilled: bool,
    ) -> bool:
        success = actual >= job.expected_count
        async with self._engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.backfill_jobs
                    SET status = :status, finished_at = clock_timestamp(),
                        cursor_state = CAST(:cursor_state AS jsonb)
                    WHERE backfill_job_id = :job_id
                    """
                ),
                {
                    "status": "SUCCEEDED" if success else "PENDING",
                    "cursor_state": json.dumps(
                        {
                            "published": published,
                            "verified": actual,
                            "prefilled": prefilled,
                        }
                    ),
                    "job_id": job.job_id,
                },
            )
            await connection.execute(
                text(
                    """
                    UPDATE market.data_gaps
                    SET status = :gap_status, actual_count = :actual_count,
                        resolved_at = CASE WHEN :success THEN clock_timestamp() ELSE NULL END,
                        details = CAST(:details AS jsonb)
                    WHERE gap_id = :gap_id
                    """
                ),
                {
                    "gap_status": "VERIFIED" if success else "QUEUED",
                    "actual_count": actual,
                    "success": success,
                    "details": json.dumps(
                        {
                            "published": published,
                            "verified": actual,
                            "prefilled": prefilled,
                        }
                    ),
                    "gap_id": job.gap_id,
                },
            )
        return success

    async def complete_if_filled(self, job: BackfillJob) -> bool:
        actual = await self._actual_count(job)
        if actual < job.expected_count:
            return False
        return await self._record_result(
            job,
            published=0,
            actual=actual,
            prefilled=True,
        )

    async def finish_job(
        self,
        job: BackfillJob,
        published: int,
        *,
        timeout_seconds: float,
        poll_interval_seconds: float,
    ) -> bool:
        deadline = time.monotonic() + timeout_seconds
        while True:
            actual = await self._actual_count(job)
            if actual >= job.expected_count:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            await asyncio.sleep(min(poll_interval_seconds, remaining))
        return await self._record_result(
            job,
            published=published,
            actual=actual,
            prefilled=False,
        )

    async def fail_job(self, job: BackfillJob, error: Exception) -> None:
        async with self._engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.backfill_jobs
                    SET status = 'FAILED', finished_at = clock_timestamp(),
                        error_details = CAST(:error AS jsonb)
                    WHERE backfill_job_id = :job_id
                    """
                ),
                {
                    "job_id": job.job_id,
                    "error": json.dumps(
                        {"type": type(error).__name__, "message": str(error)[:1000]}
                    ),
                },
            )
            await connection.execute(
                text(
                    """
                    UPDATE market.data_gaps SET status = 'OPEN' WHERE gap_id = :gap_id
                    """
                ),
                {"gap_id": job.gap_id},
            )

    async def defer_job(self, job: BackfillJob, error: Exception) -> None:
        async with self._engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.backfill_jobs
                    SET status = 'PENDING', started_at = NULL, finished_at = NULL,
                        attempts = GREATEST(attempts - 1, 0),
                        error_details = CAST(:error AS jsonb)
                    WHERE backfill_job_id = :job_id
                    """
                ),
                {
                    "job_id": job.job_id,
                    "error": json.dumps(
                        {"type": type(error).__name__, "message": str(error)[:1000]}
                    ),
                },
            )
            await connection.execute(
                text(
                    """
                    UPDATE market.data_gaps SET status = 'QUEUED' WHERE gap_id = :gap_id
                    """
                ),
                {"gap_id": job.gap_id},
            )


class DataRepairService:
    def __init__(
        self,
        repository: DataRepairRepository,
        collector: BinanceCollectionService,
        settings: Settings,
    ) -> None:
        self._repository = repository
        self._collector = collector
        self._settings = settings
        self._historical_scan_cursor: datetime | None = None
        self._historical_scan_stop: datetime | None = None

    def _gap_scan_ranges(
        self, now: datetime
    ) -> tuple[tuple[datetime, datetime], ...]:
        scan_end = now - timedelta(
            seconds=self._settings.gap_scan_safety_delay_seconds
        )
        recent_hours = self._settings.gap_scan_recent_lookback_hours
        historical_hours = self._settings.gap_scan_lookback_hours
        window_hours = self._settings.gap_scan_historical_window_hours
        recent_start = scan_end - timedelta(hours=recent_hours)
        ranges: list[tuple[datetime, datetime]] = [(recent_start, scan_end)]
        if historical_hours <= recent_hours:
            return tuple(ranges)
        if self._historical_scan_cursor is None:
            self._historical_scan_cursor = scan_end - timedelta(
                hours=historical_hours
            )
            self._historical_scan_stop = recent_start
        assert self._historical_scan_stop is not None
        if self._historical_scan_cursor < self._historical_scan_stop:
            historical_end = min(
                self._historical_scan_cursor + timedelta(hours=window_hours),
                self._historical_scan_stop,
            )
            ranges.append((self._historical_scan_cursor, historical_end))
        return tuple(ranges)

    def _complete_historical_scan(
        self, ranges: tuple[tuple[datetime, datetime], ...]
    ) -> None:
        if len(ranges) > 1:
            self._historical_scan_cursor = ranges[-1][1]

    async def run_cycle(self, *, scan_gaps: bool = True) -> dict[str, int]:
        gaps: list[GapRange] = []
        if scan_gaps:
            scan_ranges = self._gap_scan_ranges(datetime.now(UTC).replace(microsecond=0))
            gap_groups = await asyncio.gather(
                *(
                    self._repository.detect_kline_gaps_in_range(start, end, series)
                    for start, end in scan_ranges
                    for series in REPAIR_SERIES
                )
            )
            gaps = [gap for group in gap_groups for gap in group]
            self._complete_historical_scan(scan_ranges)
        queued = await self._repository.queue_gaps(gaps) if gaps else 0
        succeeded = 0
        failed = 0
        remaining = self._settings.backfill_jobs_per_cycle
        stop_workers = asyncio.Event()
        rate_limit_errors: list[BinanceRateLimitError] = []

        async def worker() -> None:
            nonlocal failed, remaining, succeeded
            while remaining > 0 and not stop_workers.is_set():
                remaining -= 1
                job = await self._repository.claim_job()
                if job is None:
                    return
                try:
                    if await self._repository.complete_if_filled(job):
                        succeeded += 1
                        continue
                    published = await self._collector.collect_kline_range(
                        job.symbol, job.start, job.end, job.series
                    )
                    if await self._repository.finish_job(
                        job,
                        published,
                        timeout_seconds=self._settings.backfill_verify_timeout_seconds,
                        poll_interval_seconds=(
                            self._settings.backfill_verify_poll_interval_seconds
                        ),
                    ):
                        succeeded += 1
                    else:
                        failed += 1
                    await asyncio.sleep(
                        self._settings.backfill_request_interval_seconds
                    )
                except BinanceRateLimitError as error:
                    await self._repository.defer_job(job, error)
                    rate_limit_errors.append(error)
                    stop_workers.set()
                    logger.warning(
                        "Binance rate limit paused backfill status=%d retry_after=%.0fs",
                        error.status_code,
                        error.retry_after_seconds,
                    )
                except Exception as error:
                    await self._repository.fail_job(job, error)
                    logger.exception(
                        "backfill job failed id=%s symbol=%s", job.job_id, job.symbol
                    )
                    failed += 1

        await asyncio.gather(
            *(worker() for _index in range(self._settings.backfill_worker_count))
        )
        if rate_limit_errors:
            raise rate_limit_errors[0]
        return {"detected": len(gaps), "queued": queued, "succeeded": succeeded, "failed": failed}

    async def run_forever(self) -> None:
        logger.info(
            "data repair starting workers=%d jobs_per_cycle=%d request_interval=%.1fs",
            self._settings.backfill_worker_count,
            self._settings.backfill_jobs_per_cycle,
            self._settings.backfill_request_interval_seconds,
        )
        recovered = await self._repository.recover_interrupted_jobs(
            stale_after_seconds=self._settings.backfill_stale_job_seconds,
            failed_retry_limit=self._settings.backfill_failed_retry_limit,
        )
        logger.info("recovered interrupted backfill jobs result=%s", recovered)
        next_scan_at = 0.0
        delay: float
        while True:
            try:
                now = time.monotonic()
                scan_gaps = now >= next_scan_at
                result = await self.run_cycle(scan_gaps=scan_gaps)
                if scan_gaps:
                    recovered = await self._repository.recover_interrupted_jobs(
                        stale_after_seconds=self._settings.backfill_stale_job_seconds,
                        failed_retry_limit=self._settings.backfill_failed_retry_limit,
                    )
                    if recovered["stale"] or recovered["failed"]:
                        logger.info(
                            "recovered backfill jobs during scan result=%s", recovered
                        )
                    next_scan_at = (
                        now + self._settings.gap_scan_interval_seconds
                    )
                delay = next_cycle_delay(
                    result,
                    batch_limit=self._settings.backfill_jobs_per_cycle,
                    idle_interval_seconds=self._settings.gap_scan_interval_seconds,
                )
                logger.info("data repair cycle result=%s next_delay=%d", result, delay)
            except BinanceRateLimitError as error:
                delay = max(
                    error.retry_after_seconds,
                    self._settings.backfill_rate_limit_cooldown_seconds,
                )
                logger.warning(
                    "data repair cooling down after Binance rate limit "
                    "status=%d delay=%.0fs",
                    error.status_code,
                    delay,
                )
            except Exception:
                logger.exception("data repair cycle failed")
                delay = self._settings.gap_scan_interval_seconds
            await asyncio.sleep(delay)


async def run(command: str, settings: Settings) -> object:
    engine = create_database_engine(settings)
    connection = await connect(settings)
    try:
        jetstream = connection.jetstream()
        await ensure_streams(jetstream)
        async with BinanceUsdMClient(
            base_url=settings.binance_usdm_base_url,
            timeout_seconds=settings.binance_request_timeout_seconds,
            max_concurrency=settings.binance_max_concurrency,
            attempts=settings.binance_request_attempts,
        ) as client:
            collector = BinanceCollectionService(
                client=client,
                publisher=JetStreamEventPublisher(jetstream),
                node_id=settings.node_id,
                shard_id=settings.shard_id,
            )
            service = DataRepairService(DataRepairRepository(engine), collector, settings)
            if command == "once":
                return await service.run_cycle()
            await service.run_forever()
            return {"stopped": True}
    finally:
        await connection.close()
        await engine.dispose()


def main() -> None:
    import argparse

    settings = get_settings()
    configure_logging(settings, "data-repair")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    parser = argparse.ArgumentParser(description="Detect and repair market data gaps")
    parser.add_argument("command", choices=("once", "run"))
    args = parser.parse_args()
    print(json.dumps(asyncio.run(run(args.command, settings)), default=str))


if __name__ == "__main__":
    main()
