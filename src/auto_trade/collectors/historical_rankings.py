from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from typing import cast
from uuid import NAMESPACE_URL, UUID, uuid5

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.collectors.binance_usdm import BinanceUsdMClient
from auto_trade.config import get_settings
from auto_trade.infrastructure.database import create_database_engine

logger = logging.getLogger(__name__)
FIVE_MINUTES_MS = 300_000
EXPECTED_BARS = 287
KLINE_LIMIT = 1000


@dataclass(frozen=True, slots=True)
class Instrument:
    instrument_id: int
    symbol: str
    onboard_at: datetime | None
    delisted_at: datetime | None


@dataclass(frozen=True, slots=True)
class DailyMetric:
    utc_trade_date: date
    window_start: datetime
    snapshot_at: datetime
    source_kline_time: datetime | None
    reference_open_price: Decimal | None
    snapshot_price: Decimal | None
    period_high_price: Decimal | None
    period_high_at: datetime | None
    period_low_price: Decimal | None
    period_low_at: datetime | None
    base_volume: Decimal
    quote_volume: Decimal
    price_change: Decimal | None
    amplitude: Decimal | None
    actual_bar_count: int
    quality_status: str
    metrics: dict[str, object]


def utc_day_bounds(day: date) -> tuple[datetime, datetime]:
    start = datetime.combine(day, time.min, tzinfo=UTC)
    return start, start + timedelta(days=1)


def instrument_is_eligible(instrument: Instrument, day: date) -> bool:
    start, snapshot_at = utc_day_bounds(day)
    snapshot_at -= timedelta(minutes=5)
    onboard = instrument.onboard_at
    delisted = instrument.delisted_at
    return (onboard is None or onboard <= start) and (
        delisted is None or delisted > snapshot_at
    )


def aggregate_daily_klines(day: date, raw_rows: list[object]) -> DailyMetric:
    start, end = utc_day_bounds(day)
    expected_times = {
        int(start.timestamp() * 1000) + index * FIVE_MINUTES_MS
        for index in range(EXPECTED_BARS)
    }
    rows_by_time: dict[int, list[object]] = {}
    for raw in raw_rows:
        if not isinstance(raw, list) or len(raw) < 8:
            continue
        open_ms = int(str(raw[0]))
        if open_ms in expected_times:
            rows_by_time[open_ms] = raw
    ordered = [rows_by_time[key] for key in sorted(rows_by_time)]
    count = len(ordered)
    complete = count == EXPECTED_BARS and set(rows_by_time) == expected_times
    snapshot_at = end - timedelta(minutes=5)
    if not ordered:
        return DailyMetric(
            day, start, snapshot_at, None, None, None, None, None, None, None,
            Decimal(0), Decimal(0), None, None, 0, "INVALID",
            {"reason": "NO_KLINES", "provenance": "DERIVED_RANKING"},
        )

    first = ordered[0]
    last = ordered[-1]
    open_price = Decimal(str(first[1]))
    close_price = Decimal(str(last[4]))
    highest = max(ordered, key=lambda row: Decimal(str(row[2])))
    lowest = min(ordered, key=lambda row: Decimal(str(row[3])))
    high_price = Decimal(str(highest[2]))
    low_price = Decimal(str(lowest[3]))
    base_volume = sum((Decimal(str(row[5])) for row in ordered), Decimal(0))
    quote_volume = sum((Decimal(str(row[7])) for row in ordered), Decimal(0))
    price_change = ((close_price / open_price) - 1) * 100 if open_price > 0 else None
    amplitude = ((high_price - low_price) / open_price) * 100 if open_price > 0 else None
    first_ms = int(str(first[0]))
    last_ms = int(str(last[0]))
    aligned_endpoints = (
        first_ms == int(start.timestamp() * 1000)
        and last_ms == int((snapshot_at - timedelta(minutes=5)).timestamp() * 1000)
    )
    quality = "VALID" if complete and aligned_endpoints and open_price > 0 else "PARTIAL"
    return DailyMetric(
        utc_trade_date=day,
        window_start=start,
        snapshot_at=snapshot_at,
        source_kline_time=datetime.fromtimestamp(last_ms / 1000, tz=UTC),
        reference_open_price=open_price,
        snapshot_price=close_price,
        period_high_price=high_price,
        period_high_at=datetime.fromtimestamp(int(str(highest[0])) / 1000, tz=UTC),
        period_low_price=low_price,
        period_low_at=datetime.fromtimestamp(int(str(lowest[0])) / 1000, tz=UTC),
        base_volume=base_volume,
        quote_volume=quote_volume,
        price_change=price_change,
        amplitude=amplitude,
        actual_bar_count=count,
        quality_status=quality,
        metrics={
            "provenance": "DERIVED_RANKING",
            "source": "BINANCE_REST_KLINE_5M",
            "expected_bar_count": EXPECTED_BARS,
            "first_open_time_ms": first_ms,
            "last_open_time_ms": last_ms,
        },
    )


async def fetch_klines(
    client: BinanceUsdMClient,
    symbol: str,
    first_day: date,
    last_day: date,
    request_delay: float,
) -> list[object]:
    start, _ = utc_day_bounds(first_day)
    _, end = utc_day_bounds(last_day)
    cursor = int(start.timestamp() * 1000)
    end_ms = int(end.timestamp() * 1000)
    rows: list[object] = []
    while cursor < end_ms:
        result = await client.klines(
            symbol,
            "5m",
            limit=KLINE_LIMIT,
            start_time_ms=cursor,
            end_time_ms=end_ms - 1,
        )
        page = cast(list[object], result.payload)
        if not page:
            break
        rows.extend(page)
        last = page[-1]
        if not isinstance(last, list) or not last:
            raise TypeError(f"invalid Binance kline response for {symbol}")
        next_cursor = int(str(last[0])) + FIVE_MINUTES_MS
        if next_cursor <= cursor:
            raise RuntimeError(f"Binance kline cursor did not advance for {symbol}")
        cursor = next_cursor
        if cursor < end_ms and request_delay > 0:
            await asyncio.sleep(request_delay)
    return rows


def _metric_hash(metric: DailyMetric) -> str:
    payload = json.dumps(asdict(metric), default=str, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


async def load_instruments(engine: AsyncEngine, symbols: tuple[str, ...]) -> list[Instrument]:
    statement = text(
        """
        SELECT instrument_id, symbol, onboard_at, delisted_at
        FROM core.instruments
        WHERE exchange = 'BINANCE' AND market = 'USD_M_FUTURES'
          AND quote_asset = 'USDT' AND contract_type = 'PERPETUAL'
          AND (:all_symbols OR symbol IN :symbols)
        ORDER BY symbol
        """
    ).bindparams(bindparam("symbols", expanding=True))
    async with engine.connect() as connection:
        result = await connection.execute(
            statement,
            {"all_symbols": not symbols, "symbols": symbols or ("__ALL__",)},
        )
    return [
        Instrument(int(row.instrument_id), row.symbol, row.onboard_at, row.delisted_at)
        for row in result
    ]


async def existing_days(engine: AsyncEngine, instrument_id: int) -> set[date]:
    async with engine.connect() as connection:
        result = await connection.execute(
            text(
                "SELECT utc_trade_date FROM market.utc_daily_metrics "
                "WHERE instrument_id=:id AND quality_status='VALID'"
            ),
            {"id": instrument_id},
        )
    return {row.utc_trade_date for row in result}


async def save_metrics(
    engine: AsyncEngine, instrument_id: int, metrics: list[DailyMetric]
) -> None:
    if not metrics:
        return
    values = []
    for metric in metrics:
        row = asdict(metric)
        row.update(
            instrument_id=instrument_id,
            source="BINANCE_REST_KLINE_5M",
            payload_hash=_metric_hash(metric),
            metrics_json=json.dumps(metric.metrics, separators=(",", ":"), sort_keys=True),
        )
        values.append(row)
    statement = text(
        """
        INSERT INTO market.utc_daily_metrics (
            instrument_id, utc_trade_date, window_start, snapshot_at,
            source_kline_time, reference_open_price, snapshot_price,
            period_high_price, period_high_at, period_low_price, period_low_at,
            base_volume, quote_volume, price_change, amplitude, actual_bar_count,
            source, quality_status, metrics, payload_hash
        ) VALUES (
            :instrument_id, :utc_trade_date, :window_start, :snapshot_at,
            :source_kline_time, :reference_open_price, :snapshot_price,
            :period_high_price, :period_high_at, :period_low_price, :period_low_at,
            :base_volume, :quote_volume, :price_change, :amplitude, :actual_bar_count,
            :source, :quality_status, CAST(:metrics_json AS jsonb), :payload_hash
        ) ON CONFLICT (instrument_id, utc_trade_date) DO UPDATE SET
            window_start=EXCLUDED.window_start, snapshot_at=EXCLUDED.snapshot_at,
            source_kline_time=EXCLUDED.source_kline_time,
            reference_open_price=EXCLUDED.reference_open_price,
            snapshot_price=EXCLUDED.snapshot_price,
            period_high_price=EXCLUDED.period_high_price, period_high_at=EXCLUDED.period_high_at,
            period_low_price=EXCLUDED.period_low_price, period_low_at=EXCLUDED.period_low_at,
            base_volume=EXCLUDED.base_volume, quote_volume=EXCLUDED.quote_volume,
            price_change=EXCLUDED.price_change, amplitude=EXCLUDED.amplitude,
            actual_bar_count=EXCLUDED.actual_bar_count, source=EXCLUDED.source,
            quality_status=EXCLUDED.quality_status, metrics=EXCLUDED.metrics,
            payload_hash=EXCLUDED.payload_hash, updated_at=clock_timestamp()
        """
    )
    async with engine.begin() as connection:
        await connection.execute(statement, values)


async def build_rankings(engine: AsyncEngine, first_day: date, last_day: date) -> int:
    query = text(
        """
        SELECT m.*, i.symbol,
               oi.open_interest_qty, oi.open_interest_value, oi.observed_at AS oi_observed_at
        FROM market.utc_daily_metrics m
        JOIN core.instruments i USING (instrument_id)
        LEFT JOIN LATERAL (
            SELECT o.open_interest_qty, o.open_interest_value, o.observed_at
            FROM market.open_interest_observations o
            WHERE o.instrument_id=m.instrument_id
              AND o.observed_at <= m.snapshot_at
              AND o.observed_at >= m.snapshot_at - INTERVAL '10 minutes'
            ORDER BY o.observed_at DESC LIMIT 1
        ) oi ON true
        WHERE m.utc_trade_date=:day AND m.quality_status='VALID'
        ORDER BY m.price_change DESC, i.symbol ASC
        LIMIT 50
        """
    )
    generated = 0
    day = first_day
    while day <= last_day:
        async with engine.begin() as connection:
            rows = (await connection.execute(query, {"day": day})).mappings().all()
            start, end = utc_day_bounds(day)
            snapshot_at = end - timedelta(minutes=5)
            snapshot_id = uuid5(
                NAMESPACE_URL,
                f"auto-trade:UTC_DAILY_2355:{snapshot_at.isoformat()}",
            )
            serialized = [
                {"symbol": row["symbol"], "rank": index, "change": str(row["price_change"])}
                for index, row in enumerate(rows, 1)
            ]
            snapshot_hash = hashlib.sha256(
                json.dumps(serialized, separators=(",", ":"), sort_keys=True).encode()
            ).hexdigest()
            await connection.execute(
                text(
                    """
                    INSERT INTO market.ranking_snapshots (
                        ranking_snapshot_id, ranking_type, snapshot_at, utc_trade_date,
                        scheduled_at, generated_at, generation_mode, source_kline_time,
                        window_start, window_end, item_count, source_event_ids,
                        snapshot_hash, quality_status
                    ) VALUES (
                        :id, 'UTC_DAILY_2355', :snapshot_at, :day, :snapshot_at,
                        clock_timestamp(), 'DERIVED', :source_time, :start, :end,
                        :count, '{}', :hash, :quality
                    ) ON CONFLICT (ranking_type, snapshot_at) DO UPDATE SET
                        utc_trade_date=EXCLUDED.utc_trade_date,
                        generated_at=EXCLUDED.generated_at,
                        generation_mode=EXCLUDED.generation_mode,
                        source_kline_time=EXCLUDED.source_kline_time,
                        window_start=EXCLUDED.window_start, window_end=EXCLUDED.window_end,
                        item_count=EXCLUDED.item_count, snapshot_hash=EXCLUDED.snapshot_hash,
                        quality_status=EXCLUDED.quality_status
                    RETURNING ranking_snapshot_id
                    """
                ),
                {
                    "id": snapshot_id, "snapshot_at": snapshot_at, "day": day,
                    "source_time": snapshot_at - timedelta(minutes=5), "start": start,
                    "end": snapshot_at, "count": len(rows), "hash": snapshot_hash,
                    "quality": "VALID" if len(rows) == 50 else "PARTIAL",
                },
            )
            actual_id = cast(
                UUID,
                (
                    await connection.execute(
                        text(
                            "SELECT ranking_snapshot_id FROM market.ranking_snapshots "
                            "WHERE ranking_type='UTC_DAILY_2355' AND snapshot_at=:at"
                        ),
                        {"at": snapshot_at},
                    )
                ).scalar_one(),
            )
            await connection.execute(
                text("DELETE FROM market.ranking_entries WHERE ranking_snapshot_id=:id"),
                {"id": actual_id},
            )
            entry_sql = text(
                """
                INSERT INTO market.ranking_entries (
                    ranking_snapshot_id, rank_no, instrument_id, price_change,
                    reference_open_price, snapshot_price, base_volume, quote_volume,
                    amplitude, period_high_price, period_high_at, period_low_price,
                    period_low_at, open_interest_qty, open_interest_value, metrics
                ) VALUES (
                    :snapshot_id, :rank_no, :instrument_id, :price_change,
                    :reference_open_price, :snapshot_price, :base_volume, :quote_volume,
                    :amplitude, :period_high_price, :period_high_at, :period_low_price,
                    :period_low_at, :open_interest_qty, :open_interest_value,
                    CAST(:metrics AS jsonb)
                )
                """
            )
            entries = []
            for rank_no, row in enumerate(rows, 1):
                oi_at = row["oi_observed_at"]
                entries.append(
                    dict(row)
                    | {
                        "snapshot_id": actual_id,
                        "rank_no": rank_no,
                        "metrics": json.dumps(
                            {
                                "provenance": "DERIVED_RANKING",
                                "source": "BINANCE_REST_KLINE_5M",
                                "actual_bar_count": row["actual_bar_count"],
                                "open_interest_status": (
                                    "LOCAL_OBSERVATION" if oi_at else "UNAVAILABLE"
                                ),
                                "open_interest_observed_at": oi_at.isoformat() if oi_at else None,
                            },
                            separators=(",", ":"),
                            sort_keys=True,
                        ),
                    }
                )
            if entries:
                await connection.execute(entry_sql, entries)
        generated += 1
        day += timedelta(days=1)
    return generated


async def run(args: argparse.Namespace) -> None:
    settings = get_settings()
    engine = create_database_engine(settings)
    last_day = args.end_date or (datetime.now(UTC).date() - timedelta(days=1))
    first_day = last_day - timedelta(days=args.days - 1)
    symbols = tuple(item.strip().upper() for item in args.symbols.split(",") if item.strip())
    try:
        instruments = await load_instruments(engine, symbols)
        logger.info(
            "historical ranking build range=%s..%s instruments=%d rank_only=%s",
            first_day, last_day, len(instruments), args.rank_only,
        )
        if not args.rank_only:
            queue: asyncio.Queue[Instrument] = asyncio.Queue()
            for instrument in instruments:
                queue.put_nowait(instrument)
            failures: list[str] = []
            async with BinanceUsdMClient(
                base_url=settings.binance_usdm_base_url,
                timeout_seconds=settings.binance_request_timeout_seconds,
                max_concurrency=args.concurrency,
                attempts=settings.binance_request_attempts,
            ) as client:
                async def worker() -> None:
                    while True:
                        try:
                            instrument = queue.get_nowait()
                        except asyncio.QueueEmpty:
                            return
                        try:
                            eligible = [
                                first_day + timedelta(days=offset)
                                for offset in range(args.days)
                                if instrument_is_eligible(
                                    instrument, first_day + timedelta(days=offset)
                                )
                            ]
                            if not args.refresh:
                                present = await existing_days(engine, instrument.instrument_id)
                                eligible = [day for day in eligible if day not in present]
                            if not eligible:
                                continue
                            rows = await fetch_klines(
                                client, instrument.symbol, min(eligible), max(eligible),
                                args.request_delay,
                            )
                            metrics = [aggregate_daily_klines(day, rows) for day in eligible]
                            await save_metrics(engine, instrument.instrument_id, metrics)
                            logger.info(
                                "stored daily metrics symbol=%s days=%d valid=%d",
                                instrument.symbol, len(metrics),
                                sum(metric.quality_status == "VALID" for metric in metrics),
                            )
                        except Exception:
                            failures.append(instrument.symbol)
                            logger.exception(
                                "historical ranking fetch failed symbol=%s",
                                instrument.symbol,
                            )
                        finally:
                            queue.task_done()
                await asyncio.gather(*(worker() for _ in range(args.concurrency)))
            if failures:
                raise RuntimeError(
                    f"historical fetch failed for {len(failures)} symbols; rerun resumes: "
                    + ",".join(failures[:20])
                )
        generated = await build_rankings(engine, first_day, last_day)
        logger.info("historical daily rankings generated days=%d", generated)
    finally:
        await engine.dispose()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build derived UTC 23:55 daily top-50 rankings")
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--end-date", type=date.fromisoformat)
    parser.add_argument("--symbols", default="")
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--request-delay", type=float, default=0.25)
    parser.add_argument("--rank-only", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    if args.days < 1 or args.days > 366:
        parser.error("--days must be between 1 and 366")
    if args.concurrency < 1 or args.concurrency > 8:
        parser.error("--concurrency must be between 1 and 8")
    if args.request_delay < 0:
        parser.error("--request-delay cannot be negative")
    return args


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run(parse_args()))


if __name__ == "__main__":
    main()
