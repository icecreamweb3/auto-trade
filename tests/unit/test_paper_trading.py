from datetime import UTC, datetime, timedelta

import pytest

from auto_trade.paper_trading.engine import PaperSession, liquidation_price
from auto_trade.paper_trading.models import (
    GameStatus,
    NotionalUnit,
    PaperCandle,
    PositionSide,
)


def candle(
    index: int,
    *,
    close: float = 100.0,
    high: float | None = None,
    low: float | None = None,
) -> PaperCandle:
    opened = datetime(2026, 1, 1, tzinfo=UTC) + timedelta(minutes=5 * index)
    return PaperCandle(
        open_time=opened,
        close_time=opened + timedelta(minutes=5),
        open_price=100,
        high_price=high if high is not None else max(100, close),
        low_price=low if low is not None else min(100, close),
        close_price=close,
        base_volume=1,
        quote_volume=100,
    )


def session(*candles: PaperCandle) -> PaperSession:
    return PaperSession(
        symbol="BTCUSDT",
        interval_seconds=300,
        candles=tuple(candles),
        range_start=candles[0].open_time,
        range_end=candles[-1].close_time,
    )


def test_long_position_updates_unrealized_and_manual_close() -> None:
    game = session(candle(0), candle(1, close=110), candle(2, close=110))

    opened = game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    advanced = game.advance()
    closed = game.close_position()

    assert opened.available_balance == 900
    assert opened.position is not None
    assert opened.position.entry_price == 100
    assert opened.position.quantity == 10
    assert advanced.position is not None
    assert advanced.position.unrealized_pnl == pytest.approx(100)
    assert advanced.equity == pytest.approx(1100)
    assert closed.position is None
    assert closed.balance == pytest.approx(1100)
    assert closed.trades[0].exit_reason == "MANUAL"


def test_long_liquidation_uses_intrabar_low_and_ends_game() -> None:
    game = session(candle(0), candle(1, close=100, low=89), candle(2))
    expected_price = liquidation_price(PositionSide.LONG, 100, 10)
    assert expected_price == pytest.approx(90.4522613)

    game.open_position(PositionSide.LONG, notional=2500, leverage=10)
    result = game.advance()

    assert result.status is GameStatus.LIQUIDATED
    assert result.position is None
    assert result.balance == 750
    assert result.trades[0].exit_price == pytest.approx(expected_price)
    assert result.trades[0].realized_pnl == -250


def test_short_liquidation_uses_intrabar_high() -> None:
    game = session(candle(0), candle(1, close=100, high=111), candle(2))
    game.open_position(PositionSide.SHORT, notional=1000, leverage=10)

    result = game.advance()

    assert result.status is GameStatus.LIQUIDATED
    assert result.balance == 900


def test_range_end_closes_open_position() -> None:
    game = session(candle(0), candle(1, close=105))
    game.open_position(PositionSide.LONG, notional=200, leverage=2)

    result = game.advance()

    assert result.status is GameStatus.COMPLETED
    assert result.position is None
    assert result.balance == pytest.approx(1010)
    assert result.trades[0].exit_reason == "RANGE_END"


def test_rejects_second_position_and_excess_margin() -> None:
    game = session(candle(0), candle(1))
    with pytest.raises(ValueError, match="保证金"):
        game.open_position(PositionSide.LONG, notional=1001, leverage=1)

    game.open_position(PositionSide.LONG, notional=100, leverage=1)
    with pytest.raises(ValueError, match="已有持仓"):
        game.open_position(PositionSide.SHORT, notional=100, leverage=1)


def test_base_asset_notional_uses_close_price_and_requested_quantity() -> None:
    game = session(candle(0, close=125), candle(1, close=130))

    opened = game.open_position(
        PositionSide.LONG,
        notional=2,
        leverage=100,
        notional_unit=NotionalUnit.BASE,
    )

    assert opened.position is not None
    assert opened.position.entry_price == 125
    assert opened.position.quantity == 2
    assert opened.position.margin == pytest.approx(2.5)
    assert opened.available_balance == pytest.approx(997.5)
