from __future__ import annotations

import asyncio
import logging
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from auto_trade.config import Settings, get_settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)

CALCULATION_VERSION = "ema-close-v2-change-amplitude"
SUPPORTED_INTERVALS = (300, 900)


@dataclass(frozen=True, slots=True)
class SourceBar:
    open_time: datetime
    close_time: datetime
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal
    source_bar_count: int


@dataclass(frozen=True, slots=True)
class IndicatorBar:
    open_time: datetime
    close_time: datetime
    close_price: Decimal
    ema20: Decimal
    ema240: Decimal
    price_change_percent: Decimal
    amplitude_percent: Decimal
    source_bar_count: int


def align_time(value: datetime, interval_seconds: int) -> datetime:
    value_utc = value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
    timestamp = int(value_utc.timestamp())
    return datetime.fromtimestamp(timestamp // interval_seconds * interval_seconds, tz=UTC)


def aggregate_source_bars(
    rows: Sequence[Mapping[str, object]], interval_seconds: int
) -> tuple[SourceBar, ...]:
    if interval_seconds not in SUPPORTED_INTERVALS:
        raise ValueError("interval_seconds must be 300 or 900")

    if interval_seconds == 300:
        return tuple(
            SourceBar(
                open_time=cast(datetime, row["open_time"]),
                close_time=cast(datetime, row["close_time"]),
                open_price=Decimal(str(row["open_price"])),
                high_price=Decimal(str(row["high_price"])),
                low_price=Decimal(str(row["low_price"])),
                close_price=Decimal(str(row["close_price"])),
                source_bar_count=1,
            )
            for row in rows
        )

    buckets: dict[datetime, list[Mapping[str, object]]] = {}
    for row in rows:
        bucket = align_time(cast(datetime, row["open_time"]), interval_seconds)
        buckets.setdefault(bucket, []).append(row)

    bars: list[SourceBar] = []
    five_minutes = 300
    for bucket, bucket_rows in sorted(buckets.items()):
        expected_times = {
            datetime.fromtimestamp(bucket.timestamp() + offset, tz=UTC)
            for offset in (0, five_minutes, five_minutes * 2)
        }
        actual_times = {cast(datetime, row["open_time"]) for row in bucket_rows}
        if len(bucket_rows) != 3 or actual_times != expected_times:
            continue
        last = bucket_rows[-1]
        bars.append(
            SourceBar(
                open_time=bucket,
                close_time=cast(datetime, last["close_time"]),
                open_price=Decimal(str(bucket_rows[0]["open_price"])),
                high_price=max(Decimal(str(row["high_price"])) for row in bucket_rows),
                low_price=min(Decimal(str(row["low_price"])) for row in bucket_rows),
                close_price=Decimal(str(last["close_price"])),
                source_bar_count=3,
            )
        )
    return tuple(bars)


def calculate_indicators(
    bars: Sequence[SourceBar],
    *,
    previous_ema20: Decimal | None = None,
    previous_ema240: Decimal | None = None,
) -> tuple[IndicatorBar, ...]:
    alpha20 = Decimal(2) / Decimal(21)
    alpha240 = Decimal(2) / Decimal(241)
    ema20 = previous_ema20
    ema240 = previous_ema240
    indicators: list[IndicatorBar] = []
    for bar in bars:
        ema20 = (
            bar.close_price
            if ema20 is None
            else alpha20 * bar.close_price + (Decimal(1) - alpha20) * ema20
        )
        ema240 = (
            bar.close_price
            if ema240 is None
            else alpha240 * bar.close_price + (Decimal(1) - alpha240) * ema240
        )
        indicators.append(
            IndicatorBar(
                open_time=bar.open_time,
                close_time=bar.close_time,
                close_price=bar.close_price,
                ema20=ema20,
                ema240=ema240,
                price_change_percent=(bar.close_price / bar.open_price - Decimal(1)) * Decimal(100),
                amplitude_percent=(bar.high_price - bar.low_price) / bar.open_price * Decimal(100),
                source_bar_count=bar.source_bar_count,
            )
        )
    return tuple(indicators)


async def _instrument_ids(engine: AsyncEngine) -> tuple[int, ...]:
    async with engine.connect() as connection:
        result = await connection.execute(
            text(
                """
                SELECT i.instrument_id
                FROM core.instruments i
                WHERE EXISTS (
                    SELECT 1
                    FROM market.klines k
                    WHERE k.instrument_id = i.instrument_id
                      AND k.price_type = 'TRADE'
                      AND k.interval_seconds = 300
                      AND k.is_current
                      AND k.is_closed
                      AND k.quality_status = 'VALID'
                )
                ORDER BY i.instrument_id
                """
            )
        )
        return tuple(cast(Sequence[int], result.scalars().all()))


async def _recompute_interval(
    connection: AsyncConnection,
    *,
    instrument_id: int,
    interval_seconds: int,
    checked_until: datetime,
    batch_size: int,
) -> int:
    checkpoint_result = await connection.execute(
        text(
            """
                SELECT source_checked_at, calculation_version
                FROM market.kline_ema_checkpoints
                WHERE instrument_id = :instrument_id
                  AND interval_seconds = :interval_seconds
                FOR UPDATE
            """
        ),
        {"instrument_id": instrument_id, "interval_seconds": interval_seconds},
    )
    checkpoint = checkpoint_result.mappings().one_or_none()

    previous_checked_at = (
        cast(datetime, checkpoint["source_checked_at"])
        if checkpoint is not None and checkpoint["calculation_version"] == CALCULATION_VERSION
        else None
    )
    if previous_checked_at is None:
        dirty_statement = text(
            """
                SELECT min(k.open_time)
                FROM market.klines k
                WHERE k.instrument_id = :instrument_id
                  AND k.price_type = 'TRADE'
                  AND k.interval_seconds = 300
                  AND k.is_current
                  AND k.is_closed
                  AND k.quality_status = 'VALID'
                  AND k.effective_at <= CAST(:checked_until AS timestamptz)
            """
        )
        dirty_parameters = {
            "instrument_id": instrument_id,
            "checked_until": checked_until,
        }
    else:
        dirty_statement = text(
            """
                SELECT min(k.open_time)
                FROM market.klines k
                WHERE k.instrument_id = :instrument_id
                  AND k.price_type = 'TRADE'
                  AND k.interval_seconds = 300
                  AND k.is_current
                  AND k.is_closed
                  AND k.quality_status = 'VALID'
                  AND k.effective_at > CAST(:previous_checked_at AS timestamptz)
                  AND k.effective_at <= CAST(:checked_until AS timestamptz)
            """
        )
        dirty_parameters = {
            "instrument_id": instrument_id,
            "previous_checked_at": previous_checked_at,
            "checked_until": checked_until,
        }
    dirty_result = await connection.execute(
        dirty_statement,
        dirty_parameters,
    )
    dirty_start = cast(datetime | None, dirty_result.scalar_one())

    if dirty_start is None:
        await _save_checkpoint(
            connection,
            instrument_id=instrument_id,
            interval_seconds=interval_seconds,
            checked_until=checked_until,
            last_open_time=None,
            preserve_last_open_time=True,
        )
        return 0

    recompute_start = align_time(dirty_start, interval_seconds)
    seed_result = await connection.execute(
        text(
            """
                SELECT ema20, ema240
                FROM market.kline_ema_indicators
                WHERE instrument_id = :instrument_id
                  AND price_type = 'TRADE'
                  AND interval_seconds = :interval_seconds
                  AND open_time < CAST(:recompute_start AS timestamptz)
                ORDER BY open_time DESC
                LIMIT 1
            """
        ),
        {
            "instrument_id": instrument_id,
            "interval_seconds": interval_seconds,
            "recompute_start": recompute_start,
        },
    )
    seed = seed_result.mappings().one_or_none()
    source_result = await connection.execute(
        text(
            """
                SELECT k.open_time, k.close_time, k.open_price, k.high_price,
                       k.low_price, k.close_price
                FROM market.klines k
                WHERE k.instrument_id = :instrument_id
                  AND k.price_type = 'TRADE'
                  AND k.interval_seconds = 300
                  AND k.open_time >= CAST(:recompute_start AS timestamptz)
                  AND k.is_current
                  AND k.is_closed
                  AND k.quality_status = 'VALID'
                ORDER BY k.open_time ASC
            """
        ),
        {"instrument_id": instrument_id, "recompute_start": recompute_start},
    )
    source_rows = source_result.mappings().all()
    bars = aggregate_source_bars(
        [cast(Mapping[str, object], row) for row in source_rows], interval_seconds
    )
    indicators = calculate_indicators(
        bars,
        previous_ema20=(Decimal(str(seed["ema20"])) if seed is not None else None),
        previous_ema240=(Decimal(str(seed["ema240"])) if seed is not None else None),
    )

    await connection.execute(
        text(
            """
            DELETE FROM market.kline_ema_indicators
            WHERE instrument_id = :instrument_id
              AND price_type = 'TRADE'
              AND interval_seconds = :interval_seconds
              AND open_time >= CAST(:recompute_start AS timestamptz)
            """
        ),
        {
            "instrument_id": instrument_id,
            "interval_seconds": interval_seconds,
            "recompute_start": recompute_start,
        },
    )
    insert_statement = text(
        """
        INSERT INTO market.kline_ema_indicators (
            instrument_id, price_type, interval_seconds,
            open_time, close_time, close_price, ema20, ema240,
            price_change_percent, amplitude_percent,
            source_bar_count, calculation_version, computed_at
        ) VALUES (
            :instrument_id, 'TRADE', :interval_seconds,
            :open_time, :close_time, :close_price, :ema20, :ema240,
            :price_change_percent, :amplitude_percent,
            :source_bar_count, :calculation_version, clock_timestamp()
        )
        """
    )
    payload = [
        {
            "instrument_id": instrument_id,
            "interval_seconds": interval_seconds,
            "open_time": item.open_time,
            "close_time": item.close_time,
            "close_price": item.close_price,
            "ema20": item.ema20,
            "ema240": item.ema240,
            "price_change_percent": item.price_change_percent,
            "amplitude_percent": item.amplitude_percent,
            "source_bar_count": item.source_bar_count,
            "calculation_version": CALCULATION_VERSION,
        }
        for item in indicators
    ]
    for offset in range(0, len(payload), batch_size):
        await connection.execute(insert_statement, payload[offset : offset + batch_size])

    await _save_checkpoint(
        connection,
        instrument_id=instrument_id,
        interval_seconds=interval_seconds,
        checked_until=checked_until,
        last_open_time=indicators[-1].open_time if indicators else None,
    )
    return len(indicators)


async def _save_checkpoint(
    connection: AsyncConnection,
    *,
    instrument_id: int,
    interval_seconds: int,
    checked_until: datetime,
    last_open_time: datetime | None,
    preserve_last_open_time: bool = False,
) -> None:
    await connection.execute(
        text(
            """
            INSERT INTO market.kline_ema_checkpoints (
                instrument_id, interval_seconds, source_checked_at,
                last_open_time, calculation_version, updated_at
            ) VALUES (
                :instrument_id, :interval_seconds, :checked_until,
                :last_open_time, :calculation_version, clock_timestamp()
            )
            ON CONFLICT (instrument_id, interval_seconds) DO UPDATE SET
                source_checked_at = EXCLUDED.source_checked_at,
                last_open_time = CASE
                    WHEN :preserve_last_open_time
                    THEN market.kline_ema_checkpoints.last_open_time
                    ELSE EXCLUDED.last_open_time
                END,
                calculation_version = EXCLUDED.calculation_version,
                updated_at = clock_timestamp()
            """
        ),
        {
            "instrument_id": instrument_id,
            "interval_seconds": interval_seconds,
            "checked_until": checked_until,
            "last_open_time": last_open_time,
            "calculation_version": CALCULATION_VERSION,
            "preserve_last_open_time": preserve_last_open_time,
        },
    )


async def update_ema_indicators(engine: AsyncEngine, settings: Settings) -> int:
    checked_until = datetime.now(UTC)
    updated = 0
    for instrument_id in await _instrument_ids(engine):
        for interval_seconds in SUPPORTED_INTERVALS:
            try:
                async with engine.begin() as connection:
                    count = await _recompute_interval(
                        connection,
                        instrument_id=instrument_id,
                        interval_seconds=interval_seconds,
                        checked_until=checked_until,
                        batch_size=settings.ema_indicator_write_batch_size,
                    )
                updated += count
                if count:
                    logger.info(
                        "EMA indicators updated instrument_id=%d interval=%ds rows=%d",
                        instrument_id,
                        interval_seconds,
                        count,
                    )
            except Exception:
                logger.exception(
                    "EMA indicator update failed instrument_id=%d interval=%ds",
                    instrument_id,
                    interval_seconds,
                )
    return updated


async def run_forever(settings: Settings) -> None:
    engine = create_database_engine(settings)
    try:
        while True:
            updated = await update_ema_indicators(engine, settings)
            logger.info("EMA indicator cycle completed updated_rows=%d", updated)
            await asyncio.sleep(settings.ema_indicator_scan_interval_seconds)
    finally:
        await engine.dispose()


def main() -> None:
    settings = get_settings()
    configure_logging(settings, "ema-indicators")
    asyncio.run(run_forever(settings))


if __name__ == "__main__":
    main()
