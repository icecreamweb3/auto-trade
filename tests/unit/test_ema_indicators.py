from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

from auto_trade.collectors.ema_history import parse_utc_start
from auto_trade.collectors.ema_indicators import (
    SourceBar,
    _instrument_ids,
    _recompute_interval,
    aggregate_source_bars,
    align_time,
    calculate_indicators,
    indicator_lock_key,
    iter_time_windows,
)


async def test_explicit_symbols_resolve_without_scanning_kline_chunks() -> None:
    result = MagicMock()
    result.scalars.return_value.all.return_value = [1, 2]
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)

    instrument_ids = await _instrument_ids(engine, (" btcusdt ", "ETHUSDT"))

    statement, parameters = connection.execute.await_args.args
    assert instrument_ids == (1, 2)
    assert "FROM market.klines" not in str(statement)
    assert "upper(i.symbol) = ANY" in str(statement)
    assert parameters == {"symbols": ["BTCUSDT", "ETHUSDT"]}


async def test_new_realtime_checkpoint_uses_bounded_bootstrap_window() -> None:
    lock_result = MagicMock()
    checkpoint_result = MagicMock()
    checkpoint_result.mappings.return_value.one_or_none.return_value = None
    dirty_result = MagicMock()
    dirty_result.scalar_one.return_value = None
    save_result = MagicMock()
    connection = MagicMock()
    connection.execute = AsyncMock(
        side_effect=(lock_result, checkpoint_result, dirty_result, save_result)
    )
    checked_until = datetime(2026, 10, 24, tzinfo=UTC)

    updated = await _recompute_interval(
        connection,
        instrument_id=7,
        interval_seconds=300,
        checked_until=checked_until,
        batch_size=1000,
        bootstrap_bars=2880,
        chunk_days=7,
    )

    dirty_statement, dirty_parameters = connection.execute.await_args_list[2].args
    assert updated == 0
    assert "ORDER BY k.open_time DESC" in str(dirty_statement)
    assert "LIMIT :bootstrap_bars" in str(dirty_statement)
    assert dirty_parameters["bootstrap_bars"] == 2880


def test_indicator_lock_key_separates_instrument_and_interval() -> None:
    keys = {
        indicator_lock_key(instrument_id, interval_seconds)
        for instrument_id in (1, 2)
        for interval_seconds in (300, 900, 3600)
    }

    assert len(keys) == 6


def test_history_windows_are_bounded_and_cover_final_partial_chunk() -> None:
    start = parse_utc_start("2020-04-01")
    end = start + timedelta(days=15, hours=3)

    windows = iter_time_windows(start, end, chunk_days=7)

    assert windows == (
        (start, start + timedelta(days=7)),
        (start + timedelta(days=7), start + timedelta(days=14)),
        (start + timedelta(days=14), end),
    )


def test_align_time_uses_utc_interval_boundary() -> None:
    value = datetime(2026, 10, 18, 0, 17, 34, tzinfo=UTC)

    assert align_time(value, 900) == datetime(2026, 10, 18, 0, 15, tzinfo=UTC)


def test_aggregate_15m_requires_all_three_source_bars() -> None:
    start = datetime(2026, 10, 18, tzinfo=UTC)
    rows = [
        {
            "open_time": start + timedelta(minutes=offset),
            "close_time": start + timedelta(minutes=offset + 5),
            "open_price": price - 1,
            "high_price": price + 2,
            "low_price": price - 2,
            "close_price": price,
        }
        for offset, price in ((0, 10), (5, 20), (10, 30), (15, 40), (20, 50))
    ]

    bars = aggregate_source_bars(rows, 900)

    assert len(bars) == 1
    assert bars[0].open_time == start
    assert bars[0].open_price == Decimal(9)
    assert bars[0].high_price == Decimal(32)
    assert bars[0].low_price == Decimal(8)
    assert bars[0].close_price == Decimal(30)
    assert bars[0].source_bar_count == 3


def test_aggregate_1h_requires_all_twelve_source_bars() -> None:
    start = datetime(2026, 10, 18, tzinfo=UTC)
    rows = [
        {
            "open_time": start + timedelta(minutes=offset),
            "close_time": start + timedelta(minutes=offset + 5),
            "open_price": 100 + offset,
            "high_price": 102 + offset,
            "low_price": 99 + offset,
            "close_price": 101 + offset,
        }
        for offset in range(0, 60, 5)
    ]

    bars = aggregate_source_bars(rows, 3600)

    assert len(bars) == 1
    assert bars[0].open_time == start
    assert bars[0].close_price == Decimal(156)
    assert bars[0].source_bar_count == 12


def test_calculate_indicators_continues_from_persisted_warm_state() -> None:
    start = datetime(2026, 10, 18, tzinfo=UTC)
    bars = (
        SourceBar(
            start,
            start + timedelta(minutes=5),
            Decimal(100),
            Decimal(112),
            Decimal(98),
            Decimal(110),
            1,
        ),
        SourceBar(
            start + timedelta(minutes=5),
            start + timedelta(minutes=10),
            Decimal(110),
            Decimal(122),
            Decimal(108),
            Decimal(120),
            1,
        ),
    )

    result = calculate_indicators(
        bars,
        previous_ema20=Decimal(100),
        previous_ema240=Decimal(80),
    )

    assert result[0].ema20 == Decimal(100) + Decimal(2) / Decimal(21) * Decimal(10)
    assert result[0].ema240 == Decimal(80) + Decimal(2) / Decimal(241) * Decimal(30)
    assert result[1].ema20 > result[0].ema20
    assert result[0].price_change_percent == Decimal(10)
    assert result[0].amplitude_percent == Decimal(14)


def test_calculate_indicators_seeds_first_historical_close() -> None:
    start = datetime(2026, 10, 18, tzinfo=UTC)
    bar = SourceBar(
        start,
        start + timedelta(minutes=5),
        Decimal("12.5"),
        Decimal("13"),
        Decimal("12"),
        Decimal("12.5"),
        1,
    )

    result = calculate_indicators((bar,))

    assert result[0].ema20 == Decimal("12.5")
    assert result[0].ema240 == Decimal("12.5")
