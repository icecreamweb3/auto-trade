from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine


@dataclass(frozen=True, slots=True)
class CoverageRow:
    key: str
    latest_at: datetime | None
    age_seconds: float | None
    actual_symbols: int
    websocket_symbols: int | None


@dataclass(frozen=True, slots=True)
class BackfillRows:
    counts: dict[str, int]
    open_gaps: int
    oldest_pending_seconds: float | None
    succeeded_last_hour: int = 0
    created_last_hour: int = 0
    finished_last_hour: int = 0
    last_succeeded_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class RestUsageRow:
    request_rate_1m: int | None
    used_weight_1m: int | None
    observed_at: datetime | None


@dataclass(frozen=True, slots=True)
class DatabaseSnapshot:
    active_symbols: int
    coverage: tuple[CoverageRow, ...]
    backfill: BackfillRows
    rest_usage: RestUsageRow
    database_size_bytes: int
    database_size_display: str


class MonitoringRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def snapshot(self) -> DatabaseSnapshot:
        async with self._engine.connect() as connection:
            active_symbols = cast(
                int,
                (
                    await connection.execute(
                        text(
                            """
                            SELECT count(*)
                            FROM core.instruments
                            WHERE exchange = 'BINANCE'
                              AND market = 'USD_M_FUTURES'
                              AND quote_asset = 'USDT'
                              AND contract_type = 'PERPETUAL'
                              AND trading_status = 'TRADING'
                            """
                        )
                    )
                ).scalar_one(),
            )

            coverage = list(await self._kline_coverage(connection))
            coverage.append(await self._ticker_coverage(connection))
            coverage.append(await self._open_interest_coverage(connection))

            backfill = await self._backfill(connection)
            rest_usage = await self._rest_usage(connection)
            database_row = (
                await connection.execute(
                    text(
                        """
                        SELECT pg_database_size(current_database()) AS size_bytes,
                               pg_size_pretty(
                                   pg_database_size(current_database())
                               ) AS size_display
                        """
                    )
                )
            ).mappings().one()

        return DatabaseSnapshot(
            active_symbols=active_symbols,
            coverage=tuple(coverage),
            backfill=backfill,
            rest_usage=rest_usage,
            database_size_bytes=cast(int, database_row["size_bytes"]),
            database_size_display=cast(str, database_row["size_display"]),
        )

    async def _kline_coverage(
        self, connection: AsyncConnection
    ) -> tuple[CoverageRow, ...]:
        rows = (
            await connection.execute(
                text(
                    """
                    WITH latest AS (
                        SELECT price_type, interval_seconds, max(open_time) AS open_time
                        FROM market.klines
                        WHERE is_current
                          AND (price_type, interval_seconds) IN (
                              ('TRADE', 60), ('MARK', 60), ('TRADE', 300)
                          )
                        GROUP BY 1, 2
                    )
                    SELECT
                        lower(k.price_type) || '_' || k.interval_seconds::text AS key,
                        l.open_time AS latest_at,
                        extract(epoch FROM clock_timestamp() - l.open_time) AS age_seconds,
                        count(DISTINCT k.instrument_id) AS actual_symbols,
                        count(DISTINCT k.instrument_id)
                            FILTER (WHERE k.source = 'WEBSOCKET') AS websocket_symbols
                    FROM market.klines k
                    JOIN latest l USING (price_type, interval_seconds, open_time)
                    WHERE k.is_current
                    GROUP BY 1, 2
                    ORDER BY 1
                    """
                )
            )
        ).mappings().all()
        return tuple(
            CoverageRow(
                key=cast(str, row["key"]),
                latest_at=cast(datetime, row["latest_at"]),
                age_seconds=float(row["age_seconds"]),
                actual_symbols=cast(int, row["actual_symbols"]),
                websocket_symbols=cast(int, row["websocket_symbols"]),
            )
            for row in rows
        )

    async def _ticker_coverage(self, connection: AsyncConnection) -> CoverageRow:
        row = (
            await connection.execute(
                text(
                    """
                    WITH latest AS (
                        SELECT max(minute_time) AS minute_time
                        FROM market.ticker_minutes
                    )
                    SELECT
                        l.minute_time AS latest_at,
                        extract(epoch FROM clock_timestamp() - l.minute_time) AS age_seconds,
                        count(t.instrument_id) FILTER (
                            WHERE t.mark_price IS NOT NULL
                              AND t.price_change_24h IS NOT NULL
                        ) AS actual_symbols,
                        count(t.instrument_id) FILTER (
                            WHERE t.source = 'WEBSOCKET'
                              AND t.mark_price IS NOT NULL
                              AND t.price_change_24h IS NOT NULL
                        ) AS websocket_symbols
                    FROM latest l
                    LEFT JOIN market.ticker_minutes t
                      ON t.minute_time = l.minute_time
                    GROUP BY l.minute_time
                    """
                )
            )
        ).mappings().one()
        latest_at = cast(datetime | None, row["latest_at"])
        return CoverageRow(
            key="ticker_60",
            latest_at=latest_at,
            age_seconds=(
                float(row["age_seconds"])
                if row["age_seconds"] is not None
                else None
            ),
            actual_symbols=cast(int, row["actual_symbols"] or 0),
            websocket_symbols=cast(int, row["websocket_symbols"] or 0),
        )

    async def _open_interest_coverage(
        self, connection: AsyncConnection
    ) -> CoverageRow:
        row = (
            await connection.execute(
                text(
                    """
                    WITH latest AS (
                        SELECT max(observed_at) AS observed_at
                        FROM market.open_interest_observations
                    )
                    SELECT
                        l.observed_at AS latest_at,
                        extract(epoch FROM clock_timestamp() - l.observed_at) AS age_seconds,
                        count(DISTINCT o.instrument_id) AS actual_symbols
                    FROM latest l
                    LEFT JOIN market.open_interest_observations o
                      ON o.observed_at >= l.observed_at - interval '10 minutes'
                     AND o.observed_at <= l.observed_at
                    GROUP BY l.observed_at
                    """
                )
            )
        ).mappings().one()
        latest_at = cast(datetime | None, row["latest_at"])
        return CoverageRow(
            key="open_interest_300",
            latest_at=latest_at,
            age_seconds=(
                float(row["age_seconds"])
                if row["age_seconds"] is not None
                else None
            ),
            actual_symbols=cast(int, row["actual_symbols"] or 0),
            websocket_symbols=None,
        )

    async def _backfill(self, connection: AsyncConnection) -> BackfillRows:
        status_rows = (
            await connection.execute(
                text(
                    """
                    SELECT status, count(*) AS count
                    FROM market.backfill_jobs
                    GROUP BY status
                    """
                )
            )
        ).mappings().all()
        summary = (
            await connection.execute(
                text(
                    """
                    WITH job_stats AS (
                        SELECT
                            min(created_at) FILTER (WHERE status = 'PENDING')
                                AS oldest_pending_at,
                            count(*) FILTER (
                                WHERE status = 'SUCCEEDED'
                                  AND finished_at >= clock_timestamp() - interval '1 hour'
                            ) AS succeeded_last_hour,
                            count(*) FILTER (
                                WHERE created_at >= clock_timestamp() - interval '1 hour'
                            ) AS created_last_hour,
                            count(*) FILTER (
                                WHERE status IN (
                                    'SUCCEEDED', 'PARTIAL', 'FAILED', 'CANCELLED'
                                )
                                  AND finished_at >= clock_timestamp() - interval '1 hour'
                            ) AS finished_last_hour,
                            max(finished_at) FILTER (WHERE status = 'SUCCEEDED')
                                AS last_succeeded_at
                        FROM market.backfill_jobs
                    ), gap_stats AS (
                        SELECT count(*) FILTER (
                            WHERE status IN ('OPEN', 'QUEUED', 'BACKFILLING')
                        ) AS open_gaps
                        FROM market.data_gaps
                    )
                    SELECT
                        job_stats.*,
                        extract(
                            epoch FROM clock_timestamp() - job_stats.oldest_pending_at
                        ) AS oldest_pending_seconds,
                        gap_stats.open_gaps
                    FROM job_stats CROSS JOIN gap_stats
                    """
                )
            )
        ).mappings().one()
        return BackfillRows(
            counts={
                cast(str, row["status"]): cast(int, row["count"])
                for row in status_rows
            },
            open_gaps=cast(int, summary["open_gaps"] or 0),
            oldest_pending_seconds=(
                float(summary["oldest_pending_seconds"])
                if summary["oldest_pending_seconds"] is not None
                else None
            ),
            succeeded_last_hour=cast(int, summary["succeeded_last_hour"] or 0),
            created_last_hour=cast(int, summary["created_last_hour"] or 0),
            finished_last_hour=cast(int, summary["finished_last_hour"] or 0),
            last_succeeded_at=cast(datetime | None, summary["last_succeeded_at"]),
        )

    async def _rest_usage(self, connection: AsyncConnection) -> RestUsageRow:
        row = (
            await connection.execute(
                text(
                    """
                    SELECT
                        max((payload ->> 'request_rate_1m')::integer) AS request_rate_1m,
                        max((payload ->> 'used_weight_1m')::integer) AS used_weight_1m,
                        max(collected_at) AS observed_at
                    FROM market.raw_events
                    WHERE collected_at >= clock_timestamp() - interval '10 minutes'
                      AND payload ? 'used_weight_1m'
                      AND payload ->> 'used_weight_1m' IS NOT NULL
                    """
                )
            )
        ).mappings().one()
        return RestUsageRow(
            request_rate_1m=cast(int | None, row["request_rate_1m"]),
            used_weight_1m=cast(int | None, row["used_weight_1m"]),
            observed_at=cast(datetime | None, row["observed_at"]),
        )
