from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

from auto_trade.collectors.kline_15m import (
    OpenInterestPoint,
    _instrument_ids,
    aggregate_15m_bars,
    attach_open_interest,
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


def _source_row(start: datetime, offset_minutes: int, price: int) -> dict[str, object]:
    return {
        "open_time": start + timedelta(minutes=offset_minutes),
        "close_time": start + timedelta(minutes=offset_minutes + 5),
        "open_price": price,
        "high_price": price + 3,
        "low_price": price - 2,
        "close_price": price + 1,
        "base_volume": 10,
        "quote_volume": 100,
        "trade_count": 4,
        "taker_buy_base": 6,
        "taker_buy_quote": 60,
    }


def test_aggregate_15m_persists_complete_ohlcv_totals() -> None:
    start = datetime(2026, 10, 20, tzinfo=UTC)
    rows = [_source_row(start, offset, price) for offset, price in ((0, 100), (5, 105), (10, 103))]

    bars = aggregate_15m_bars(rows)

    assert len(bars) == 1
    assert bars[0].open_time == start
    assert bars[0].close_time == start + timedelta(minutes=15)
    assert bars[0].open_price == Decimal(100)
    assert bars[0].high_price == Decimal(108)
    assert bars[0].low_price == Decimal(98)
    assert bars[0].close_price == Decimal(104)
    assert bars[0].base_volume == Decimal(30)
    assert bars[0].quote_volume == Decimal(300)
    assert bars[0].trade_count == 12
    assert bars[0].taker_buy_base == Decimal(18)
    assert bars[0].taker_buy_quote == Decimal(180)


def test_aggregate_15m_skips_incomplete_bucket() -> None:
    start = datetime(2026, 10, 20, tzinfo=UTC)
    rows = [_source_row(start, offset, 100) for offset in (0, 10)]

    assert aggregate_15m_bars(rows) == ()


def test_attach_open_interest_uses_latest_available_point_in_bucket() -> None:
    start = datetime(2026, 10, 20, tzinfo=UTC)
    bar = aggregate_15m_bars([_source_row(start, offset, 100) for offset in (0, 5, 10)])[0]
    points = (
        OpenInterestPoint(
            start + timedelta(minutes=4),
            Decimal(1000),
            Decimal(5000),
            "VALID",
        ),
        OpenInterestPoint(
            start + timedelta(minutes=14),
            Decimal(1200),
            Decimal(6200),
            "VALID",
        ),
    )

    result = attach_open_interest((bar,), points)

    assert result[0].open_interest_qty == Decimal(1200)
    assert result[0].open_interest_value == Decimal(6200)
    assert result[0].oi_observed_at == start + timedelta(minutes=14)


def test_attach_open_interest_preserves_missing_value_as_missing() -> None:
    start = datetime(2026, 10, 20, tzinfo=UTC)
    bar = aggregate_15m_bars([_source_row(start, offset, 100) for offset in (0, 5, 10)])[0]

    result = attach_open_interest((bar,), ())

    assert result[0].open_interest_qty is None
    assert result[0].open_interest_value is None
    assert result[0].oi_observed_at is None
