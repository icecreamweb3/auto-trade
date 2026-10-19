from datetime import UTC, datetime, timedelta
from decimal import Decimal

from auto_trade.collectors.ema_indicators import (
    SourceBar,
    aggregate_source_bars,
    align_time,
    calculate_indicators,
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
