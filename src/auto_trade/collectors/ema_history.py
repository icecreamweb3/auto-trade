from __future__ import annotations

import argparse
import asyncio
import logging
from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime, time
from decimal import Decimal
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from auto_trade.collectors.ema_indicators import (
    CALCULATION_VERSION,
    SUPPORTED_INTERVALS,
    IndicatorBar,
    _instrument_ids,
    _save_checkpoint,
    aggregate_source_bars,
    align_time,
    calculate_indicators,
    indicator_lock_key,
    iter_time_windows,
)
from auto_trade.config import Settings, get_settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)

DEFAULT_SYMBOLS = ("BTCUSDT", "ETHUSDT")
DEFAULT_START = date(2020, 4, 1)


def parse_utc_start(value: str) -> datetime:
    parsed = date.fromisoformat(value)
    return datetime.combine(parsed, time.min, tzinfo=UTC)


async def _latest_source_close(
    connection: AsyncConnection,
    *,
    instrument_id: int,
    checked_until: datetime,
) -> datetime | None:
    result = await connection.execute(
        text(
            """
            SELECT max(k.close_time)
            FROM market.klines k
            WHERE k.instrument_id = :instrument_id
              AND k.price_type = 'TRADE'
              AND k.interval_seconds = 300
              AND k.is_current
              AND k.is_closed
              AND k.quality_status = 'VALID'
              AND k.effective_at <= CAST(:checked_until AS timestamptz)
            """
        ),
        {"instrument_id": instrument_id, "checked_until": checked_until},
    )
    return cast(datetime | None, result.scalar_one())


def _indicator_payload(
    instrument_id: int, interval_seconds: int, indicators: Sequence[IndicatorBar]
) -> list[dict[str, object]]:
    return [
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


INSERT_INDICATORS = text(
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


async def _backfill_interval(
    engine: AsyncEngine,
    *,
    instrument_id: int,
    interval_seconds: int,
    start: datetime,
    checked_until: datetime,
    chunk_days: int,
    batch_size: int,
) -> int:
    recompute_start = align_time(start, interval_seconds)
    connection = await engine.connect()
    lock_key = indicator_lock_key(instrument_id, interval_seconds)
    lock_acquired = False
    try:
        await connection.execute(
            text("SELECT pg_advisory_lock(:lock_key)"), {"lock_key": lock_key}
        )
        lock_acquired = True
        await connection.commit()

        latest_close = await _latest_source_close(
            connection,
            instrument_id=instrument_id,
            checked_until=checked_until,
        )
        await connection.commit()
        if latest_close is None or latest_close <= recompute_start:
            logger.warning(
                "No source K-lines in history range instrument_id=%d interval=%ds",
                instrument_id,
                interval_seconds,
            )
            return 0

        previous_ema20: Decimal | None = None
        previous_ema240: Decimal | None = None

        async with connection.begin():
            await connection.execute(
                text(
                    """
                    DELETE FROM market.kline_ema_indicators
                    WHERE instrument_id = :instrument_id
                      AND price_type = 'TRADE'
                      AND interval_seconds = :interval_seconds
                      AND open_time >= CAST(:recompute_start AS timestamptz)
                      AND open_time < CAST(:latest_close AS timestamptz)
                    """
                ),
                {
                    "instrument_id": instrument_id,
                    "interval_seconds": interval_seconds,
                    "recompute_start": recompute_start,
                    "latest_close": latest_close,
                },
            )

        inserted = 0
        last_open_time: datetime | None = None
        for window_start, window_end in iter_time_windows(
            recompute_start, latest_close, chunk_days=chunk_days
        ):
            async with connection.begin():
                source_result = await connection.execute(
                    text(
                        """
                        SELECT k.open_time, k.close_time, k.open_price, k.high_price,
                               k.low_price, k.close_price
                        FROM market.klines k
                        WHERE k.instrument_id = :instrument_id
                          AND k.price_type = 'TRADE'
                          AND k.interval_seconds = 300
                          AND k.open_time >= CAST(:window_start AS timestamptz)
                          AND k.open_time < CAST(:window_end AS timestamptz)
                          AND k.is_current
                          AND k.is_closed
                          AND k.quality_status = 'VALID'
                          AND k.effective_at <= CAST(:checked_until AS timestamptz)
                        ORDER BY k.open_time ASC
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "window_start": window_start,
                        "window_end": window_end,
                        "checked_until": checked_until,
                    },
                )
                source_rows = [
                    cast(Mapping[str, object], row)
                    for row in source_result.mappings().all()
                ]
                bars = aggregate_source_bars(source_rows, interval_seconds)
                indicators = calculate_indicators(
                    bars,
                    previous_ema20=previous_ema20,
                    previous_ema240=previous_ema240,
                )
                payload = _indicator_payload(
                    instrument_id, interval_seconds, indicators
                )
                for offset in range(0, len(payload), batch_size):
                    await connection.execute(
                        INSERT_INDICATORS, payload[offset : offset + batch_size]
                    )
                if indicators:
                    previous_ema20 = indicators[-1].ema20
                    previous_ema240 = indicators[-1].ema240
                    last_open_time = indicators[-1].open_time
                    inserted += len(indicators)
            logger.info(
                "EMA history chunk completed instrument_id=%d interval=%ds "
                "start=%s end=%s rows=%d",
                instrument_id,
                interval_seconds,
                window_start.isoformat(),
                window_end.isoformat(),
                len(indicators),
            )

        async with connection.begin():
            await _save_checkpoint(
                connection,
                instrument_id=instrument_id,
                interval_seconds=interval_seconds,
                checked_until=checked_until,
                last_open_time=last_open_time,
                preserve_last_open_time=last_open_time is None,
            )
        return inserted
    finally:
        if connection.in_transaction():
            await connection.rollback()
        try:
            if lock_acquired:
                await connection.execute(
                    text("SELECT pg_advisory_unlock(:lock_key)"),
                    {"lock_key": lock_key},
                )
                await connection.commit()
        finally:
            await connection.close()


async def backfill_ema_history(
    settings: Settings,
    *,
    symbols: Sequence[str],
    start: datetime,
) -> int:
    engine = create_database_engine(settings)
    checked_until = datetime.now(UTC)
    total = 0
    try:
        instrument_ids = await _instrument_ids(engine, symbols)
        if len(instrument_ids) != len({symbol.upper() for symbol in symbols}):
            raise RuntimeError("Not all requested EMA history symbols exist")
        for instrument_id in instrument_ids:
            for interval_seconds in SUPPORTED_INTERVALS:
                count = await _backfill_interval(
                    engine,
                    instrument_id=instrument_id,
                    interval_seconds=interval_seconds,
                    start=start,
                    checked_until=checked_until,
                    chunk_days=settings.ema_history_chunk_days,
                    batch_size=settings.ema_indicator_write_batch_size,
                )
                total += count
                logger.info(
                    "EMA history interval completed instrument_id=%d interval=%ds rows=%d",
                    instrument_id,
                    interval_seconds,
                    count,
                )
        return total
    finally:
        await engine.dispose()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="One-shot, chunked EMA history backfill for long-history symbols"
    )
    parser.add_argument("--symbols", nargs="+", default=list(DEFAULT_SYMBOLS))
    parser.add_argument("--start", default=DEFAULT_START.isoformat())
    args = parser.parse_args()
    settings = get_settings()
    configure_logging(settings, "ema-indicators-history")
    rows = asyncio.run(
        backfill_ema_history(
            settings,
            symbols=args.symbols,
            start=parse_utc_start(args.start),
        )
    )
    logger.info("EMA history backfill completed rows=%d", rows)


if __name__ == "__main__":
    main()
