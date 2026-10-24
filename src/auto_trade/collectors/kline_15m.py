from __future__ import annotations

import logging
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import cast

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

logger = logging.getLogger(__name__)

DERIVATION_VERSION = "trade-5m-aggregate-v1"
FIVE_MINUTES = 300
FIFTEEN_MINUTES = 900


@dataclass(frozen=True, slots=True)
class Derived15mBar:
    open_time: datetime
    close_time: datetime
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal
    base_volume: Decimal
    quote_volume: Decimal
    trade_count: int | None
    taker_buy_base: Decimal | None
    taker_buy_quote: Decimal | None
    open_interest_qty: Decimal | None = None
    open_interest_value: Decimal | None = None
    oi_observed_at: datetime | None = None
    oi_quality_status: str | None = None
    source_bar_count: int = 3


@dataclass(frozen=True, slots=True)
class OpenInterestPoint:
    observed_at: datetime
    open_interest_qty: Decimal
    open_interest_value: Decimal | None
    quality_status: str


def align_15m(value: datetime) -> datetime:
    value_utc = value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
    timestamp = int(value_utc.timestamp())
    return datetime.fromtimestamp(timestamp // FIFTEEN_MINUTES * FIFTEEN_MINUTES, tz=UTC)


def _time_windows(
    start: datetime, end: datetime, *, chunk_days: int
) -> tuple[tuple[datetime, datetime], ...]:
    windows: list[tuple[datetime, datetime]] = []
    cursor = start
    step = timedelta(days=chunk_days)
    while cursor < end:
        window_end = min(cursor + step, end)
        windows.append((cursor, window_end))
        cursor = window_end
    return tuple(windows)


def _optional_decimal_sum(rows: Sequence[Mapping[str, object]], key: str) -> Decimal | None:
    values = [row[key] for row in rows]
    if any(value is None for value in values):
        return None
    return sum((Decimal(str(value)) for value in values), start=Decimal(0))


def _optional_int_sum(rows: Sequence[Mapping[str, object]], key: str) -> int | None:
    values = [row[key] for row in rows]
    if any(value is None for value in values):
        return None
    return sum(int(cast(int, value)) for value in values)


def aggregate_15m_bars(
    rows: Sequence[Mapping[str, object]],
) -> tuple[Derived15mBar, ...]:
    buckets: dict[datetime, list[Mapping[str, object]]] = {}
    for row in rows:
        bucket = align_15m(cast(datetime, row["open_time"]))
        buckets.setdefault(bucket, []).append(row)

    result: list[Derived15mBar] = []
    for bucket, unordered_rows in sorted(buckets.items()):
        bucket_rows = sorted(unordered_rows, key=lambda row: cast(datetime, row["open_time"]))
        expected_times = {
            datetime.fromtimestamp(bucket.timestamp() + offset, tz=UTC)
            for offset in (0, FIVE_MINUTES, FIVE_MINUTES * 2)
        }
        actual_times = {cast(datetime, row["open_time"]) for row in bucket_rows}
        if len(bucket_rows) != 3 or actual_times != expected_times:
            continue
        first = bucket_rows[0]
        last = bucket_rows[-1]
        base_volume = _optional_decimal_sum(bucket_rows, "base_volume")
        quote_volume = _optional_decimal_sum(bucket_rows, "quote_volume")
        if base_volume is None or quote_volume is None:
            continue
        result.append(
            Derived15mBar(
                open_time=bucket,
                close_time=cast(datetime, last["close_time"]),
                open_price=Decimal(str(first["open_price"])),
                high_price=max(Decimal(str(row["high_price"])) for row in bucket_rows),
                low_price=min(Decimal(str(row["low_price"])) for row in bucket_rows),
                close_price=Decimal(str(last["close_price"])),
                base_volume=base_volume,
                quote_volume=quote_volume,
                trade_count=_optional_int_sum(bucket_rows, "trade_count"),
                taker_buy_base=_optional_decimal_sum(bucket_rows, "taker_buy_base"),
                taker_buy_quote=_optional_decimal_sum(bucket_rows, "taker_buy_quote"),
            )
        )
    return tuple(result)


def attach_open_interest(
    bars: Sequence[Derived15mBar], points: Sequence[OpenInterestPoint]
) -> tuple[Derived15mBar, ...]:
    latest_by_bucket: dict[datetime, OpenInterestPoint] = {}
    for point in points:
        bucket = align_15m(point.observed_at)
        previous = latest_by_bucket.get(bucket)
        if previous is None or point.observed_at > previous.observed_at:
            latest_by_bucket[bucket] = point
    return tuple(
        replace(
            bar,
            open_interest_qty=matched.open_interest_qty,
            open_interest_value=matched.open_interest_value,
            oi_observed_at=matched.observed_at,
            oi_quality_status=matched.quality_status,
        )
        if (matched := latest_by_bucket.get(bar.open_time)) is not None
        else bar
        for bar in bars
    )


async def _instrument_ids(
    engine: AsyncEngine, symbols: Sequence[str] | None = None
) -> tuple[int, ...]:
    normalized_symbols = tuple(
        symbol.strip().upper() for symbol in symbols or () if symbol.strip()
    )
    if normalized_symbols:
        statement = text(
            """
            SELECT i.instrument_id
            FROM core.instruments i
            WHERE upper(i.symbol) = ANY(CAST(:symbols AS text[]))
            ORDER BY i.instrument_id
            """
        )
        parameters: dict[str, object] = {"symbols": list(normalized_symbols)}
    else:
        statement = text(
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
        parameters = {}
    async with engine.connect() as connection:
        result = await connection.execute(statement, parameters)
        return tuple(cast(Sequence[int], result.scalars().all()))


async def _save_checkpoint(
    connection: AsyncConnection,
    *,
    instrument_id: int,
    checked_until: datetime,
    last_open_time: datetime | None,
    preserve_last_open_time: bool = False,
) -> None:
    await connection.execute(
        text(
            """
            INSERT INTO market.kline_15m_checkpoints (
                instrument_id, kline_checked_at, oi_checked_at,
                last_open_time, derivation_version, updated_at
            ) VALUES (
                :instrument_id, :checked_until, :checked_until,
                :last_open_time, :derivation_version, clock_timestamp()
            )
            ON CONFLICT (instrument_id) DO UPDATE SET
                kline_checked_at = EXCLUDED.kline_checked_at,
                oi_checked_at = EXCLUDED.oi_checked_at,
                last_open_time = CASE
                    WHEN :preserve_last_open_time
                    THEN market.kline_15m_checkpoints.last_open_time
                    ELSE EXCLUDED.last_open_time
                END,
                derivation_version = EXCLUDED.derivation_version,
                updated_at = clock_timestamp()
            """
        ),
        {
            "instrument_id": instrument_id,
            "checked_until": checked_until,
            "last_open_time": last_open_time,
            "derivation_version": DERIVATION_VERSION,
            "preserve_last_open_time": preserve_last_open_time,
        },
    )


async def _clear_consumed_dirty_marker(
    connection: AsyncConnection,
    *,
    instrument_id: int,
    dirty_marker: Mapping[str, object] | None,
    checked_until: datetime,
) -> None:
    # Do not issue an unconditional DELETE after observing no marker: a writer
    # can insert one concurrently after our SELECT, and that new work must remain
    # queued for the next cycle.
    if (
        dirty_marker is None
        or cast(datetime, dirty_marker["changed_at"]) > checked_until
    ):
        return
    await connection.execute(
        text(
            """
            DELETE FROM market.kline_15m_dirty_ranges
            WHERE instrument_id = :instrument_id
            """
        ),
        {"instrument_id": instrument_id},
    )


async def _recompute_instrument(
    connection: AsyncConnection,
    *,
    instrument_id: int,
    checked_until: datetime,
    batch_size: int,
    bootstrap_bars: int,
    chunk_days: int,
) -> int:
    # This transaction is executed once per instrument with the same prepared
    # statements. Keep custom plans so bounded source windows can prune TimescaleDB
    # chunks using their actual timestamp parameters.
    await connection.execute(
        text("SELECT set_config('plan_cache_mode', 'force_custom_plan', true)")
    )
    checkpoint_result = await connection.execute(
        text(
            """
            SELECT kline_checked_at, oi_checked_at, derivation_version
            FROM market.kline_15m_checkpoints
            WHERE instrument_id = :instrument_id
            FOR UPDATE
            """
        ),
        {"instrument_id": instrument_id},
    )
    checkpoint = checkpoint_result.mappings().one_or_none()
    dirty_marker_result = await connection.execute(
        text(
            """
            SELECT dirty_start, changed_at
            FROM market.kline_15m_dirty_ranges
            WHERE instrument_id = :instrument_id
            FOR UPDATE
            """
        ),
        {"instrument_id": instrument_id},
    )
    dirty_marker = cast(
        Mapping[str, object] | None,
        dirty_marker_result.mappings().one_or_none(),
    )
    if checkpoint is not None and checkpoint["derivation_version"] == DERIVATION_VERSION:
        kline_checked_at = cast(datetime, checkpoint["kline_checked_at"])
        oi_checked_at = cast(datetime, checkpoint["oi_checked_at"])
    else:
        kline_checked_at = None
        oi_checked_at = None

    if kline_checked_at is None and oi_checked_at is None:
        dirty_statement = text(
            """
            SELECT min(recent.open_time)
            FROM (
                SELECT k.open_time
                FROM market.klines k
                WHERE k.instrument_id = :instrument_id
                  AND k.price_type = 'TRADE'
                  AND k.interval_seconds = 300
                  AND k.is_current
                  AND k.is_closed
                  AND k.quality_status = 'VALID'
                  AND k.effective_at <= CAST(:checked_until AS timestamptz)
                ORDER BY k.open_time DESC
                LIMIT :bootstrap_bars
            ) recent
            """
        )
        dirty_parameters: dict[str, object] = {
            "instrument_id": instrument_id,
            "checked_until": checked_until,
            "bootstrap_bars": bootstrap_bars,
        }
    elif dirty_marker is not None:
        assert kline_checked_at is not None
        assert oi_checked_at is not None
        dirty_start = cast(datetime, dirty_marker["dirty_start"])
    else:
        dirty_start = None

    if kline_checked_at is None and oi_checked_at is None:
        dirty_result = await connection.execute(dirty_statement, dirty_parameters)
        dirty_start = cast(datetime | None, dirty_result.scalar_one())
    if dirty_start is None:
        await _save_checkpoint(
            connection,
            instrument_id=instrument_id,
            checked_until=checked_until,
            last_open_time=None,
            preserve_last_open_time=True,
        )
        await _clear_consumed_dirty_marker(
            connection,
            instrument_id=instrument_id,
            dirty_marker=dirty_marker,
            checked_until=checked_until,
        )
        return 0

    recompute_start = align_15m(dirty_start)
    await connection.execute(
        text(
            """
            DELETE FROM market.klines_15m
            WHERE instrument_id = :instrument_id
              AND open_time >= CAST(:recompute_start AS timestamptz)
            """
        ),
        {"instrument_id": instrument_id, "recompute_start": recompute_start},
    )
    insert_statement = text(
        """
        INSERT INTO market.klines_15m (
            instrument_id, price_type, interval_seconds, open_time, close_time,
            open_price, high_price, low_price, close_price,
            base_volume, quote_volume, trade_count,
            taker_buy_base, taker_buy_quote,
            open_interest_qty, open_interest_value,
            oi_observed_at, oi_quality_status,
            source_bar_count, derivation_version, computed_at
        ) VALUES (
            :instrument_id, 'TRADE', 900, :open_time, :close_time,
            :open_price, :high_price, :low_price, :close_price,
            :base_volume, :quote_volume, :trade_count,
            :taker_buy_base, :taker_buy_quote,
            :open_interest_qty, :open_interest_value,
            :oi_observed_at, :oi_quality_status,
            3, :derivation_version, clock_timestamp()
        )
        """
    )
    updated = 0
    last_open_time: datetime | None = None
    for window_start, window_end in _time_windows(
        recompute_start, checked_until, chunk_days=chunk_days
    ):
        source_result = await connection.execute(
            text(
                """
                SELECT k.open_time, k.close_time, k.open_price, k.high_price,
                       k.low_price, k.close_price, k.base_volume, k.quote_volume,
                       k.trade_count, k.taker_buy_base, k.taker_buy_quote
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
                ORDER BY k.open_time
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
            cast(Mapping[str, object], row) for row in source_result.mappings().all()
        ]
        oi_result = await connection.execute(
            text(
                """
                SELECT o.observed_at, o.open_interest_qty,
                       o.open_interest_value, o.quality_status
                FROM market.open_interest_observations o
                WHERE o.instrument_id = :instrument_id
                  AND o.observed_at >= CAST(:window_start AS timestamptz)
                  AND o.observed_at < CAST(:window_end AS timestamptz)
                  AND o.quality_status IN ('VALID', 'PARTIAL')
                  AND o.collected_at <= CAST(:checked_until AS timestamptz)
                ORDER BY o.observed_at
                """
            ),
            {
                "instrument_id": instrument_id,
                "window_start": window_start,
                "window_end": window_end,
                "checked_until": checked_until,
            },
        )
        points = tuple(
            OpenInterestPoint(
                observed_at=cast(datetime, row["observed_at"]),
                open_interest_qty=Decimal(str(row["open_interest_qty"])),
                open_interest_value=(
                    Decimal(str(row["open_interest_value"]))
                    if row["open_interest_value"] is not None
                    else None
                ),
                quality_status=cast(str, row["quality_status"]),
            )
            for row in oi_result.mappings()
        )
        bars = attach_open_interest(aggregate_15m_bars(source_rows), points)
        payload = [
            {
                "instrument_id": instrument_id,
                "open_time": bar.open_time,
                "close_time": bar.close_time,
                "open_price": bar.open_price,
                "high_price": bar.high_price,
                "low_price": bar.low_price,
                "close_price": bar.close_price,
                "base_volume": bar.base_volume,
                "quote_volume": bar.quote_volume,
                "trade_count": bar.trade_count,
                "taker_buy_base": bar.taker_buy_base,
                "taker_buy_quote": bar.taker_buy_quote,
                "open_interest_qty": bar.open_interest_qty,
                "open_interest_value": bar.open_interest_value,
                "oi_observed_at": bar.oi_observed_at,
                "oi_quality_status": bar.oi_quality_status,
                "derivation_version": DERIVATION_VERSION,
            }
            for bar in bars
        ]
        for offset in range(0, len(payload), batch_size):
            await connection.execute(
                insert_statement, payload[offset : offset + batch_size]
            )
        if bars:
            updated += len(bars)
            last_open_time = bars[-1].open_time

    await _save_checkpoint(
        connection,
        instrument_id=instrument_id,
        checked_until=checked_until,
        last_open_time=last_open_time,
        preserve_last_open_time=last_open_time is None,
    )
    await _clear_consumed_dirty_marker(
        connection,
        instrument_id=instrument_id,
        dirty_marker=dirty_marker,
        checked_until=checked_until,
    )
    return updated


async def update_15m_klines(
    engine: AsyncEngine,
    *,
    checked_until: datetime,
    batch_size: int,
    bootstrap_bars: int = 2880,
    chunk_days: int = 7,
    symbols: Sequence[str] | None = None,
) -> int:
    updated = 0
    for instrument_id in await _instrument_ids(engine, symbols):
        try:
            async with engine.begin() as connection:
                count = await _recompute_instrument(
                    connection,
                    instrument_id=instrument_id,
                    checked_until=checked_until,
                    batch_size=batch_size,
                    bootstrap_bars=bootstrap_bars,
                    chunk_days=chunk_days,
                )
            updated += count
            if count:
                logger.info(
                    "15m K-lines updated instrument_id=%d rows=%d",
                    instrument_id,
                    count,
                )
        except SQLAlchemyError:
            logger.exception(
                "15m K-line database update failed; aborting cycle instrument_id=%d",
                instrument_id,
            )
            raise
        except Exception:
            logger.exception("15m K-line update failed instrument_id=%d", instrument_id)
    return updated
