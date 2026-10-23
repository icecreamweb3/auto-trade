from datetime import UTC, datetime, timedelta

import pytest

from auto_trade.paper_trading.engine import (
    PaperSession,
    liquidation_price,
    utc8_price_anchor,
)
from auto_trade.paper_trading.models import (
    GameStatus,
    NotionalUnit,
    PaperCandle,
    PositionSide,
)


def candle(
    index: int,
    *,
    open_price: float = 100.0,
    close: float = 100.0,
    high: float | None = None,
    low: float | None = None,
) -> PaperCandle:
    opened = datetime(2026, 1, 1, tzinfo=UTC) + timedelta(minutes=5 * index)
    return PaperCandle(
        open_time=opened,
        close_time=opened + timedelta(minutes=5),
        open_price=open_price,
        high_price=high if high is not None else max(open_price, close),
        low_price=low if low is not None else min(open_price, close),
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
    expected_price = liquidation_price(
        PositionSide.LONG,
        entry_price=100,
        quantity=100,
        account_balance=1000,
    )
    assert expected_price == pytest.approx(90.4522613)

    game.open_position(PositionSide.LONG, notional=10000, leverage=10)
    result = game.advance()

    assert result.status is GameStatus.LIQUIDATED
    assert result.position is None
    assert result.balance == pytest.approx(45.2261307)
    assert result.trades[0].exit_price == pytest.approx(expected_price)
    assert result.trades[0].realized_pnl == pytest.approx(-954.7738693)


def test_short_liquidation_uses_intrabar_high() -> None:
    game = session(candle(0), candle(1, close=100, high=111), candle(2))
    game.open_position(PositionSide.SHORT, notional=10000, leverage=10)

    result = game.advance()

    assert result.status is GameStatus.LIQUIDATED
    assert result.balance == pytest.approx(54.7263682)


def test_cross_margin_uses_full_account_balance_as_position_buffer() -> None:
    game = session(candle(0), candle(1, close=50, low=1), candle(2))

    opened = game.open_position(PositionSide.LONG, notional=1000, leverage=100)
    advanced = game.advance()

    assert opened.position is not None
    assert opened.position.margin == pytest.approx(10)
    assert opened.position.liquidation_price == 0
    assert opened.available_balance == pytest.approx(990)
    assert advanced.status is GameStatus.RUNNING
    assert advanced.position is not None


def test_range_end_closes_open_position() -> None:
    game = session(candle(0), candle(1, close=105))
    game.open_position(PositionSide.LONG, notional=200, leverage=2)

    result = game.advance()

    assert result.status is GameStatus.COMPLETED
    assert result.position is None
    assert result.balance == pytest.approx(1010)
    assert result.trades[0].exit_reason == "RANGE_END"


def test_range_end_settles_untriggered_risk_orders_at_last_close() -> None:
    game = session(
        candle(0, close=100),
        candle(1, close=105, high=110, low=95),
    )
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    configured = game.set_risk_orders(take_profit_price=120, stop_loss_price=90)

    result = game.advance()

    assert len(configured.pending_orders) == 2
    assert result.status is GameStatus.COMPLETED
    assert result.position is None
    assert result.pending_orders == ()
    assert result.balance == pytest.approx(1050)
    assert result.trades[0].exit_price == 105
    assert result.trades[0].exit_reason == "RANGE_END"
    assert result.message == "已回放到所选行情末尾, 剩余头寸已按最后一根 K 线收盘价结算"


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


def test_limit_open_order_is_listed_reserves_margin_and_fills_when_touched() -> None:
    game = session(
        candle(0, close=100),
        candle(1, close=97, high=101, low=94),
        candle(2, close=98),
    )

    placed = game.place_limit_open_order(
        PositionSide.LONG,
        notional=1000,
        leverage=10,
        price=95,
    )
    filled = game.advance()

    assert placed.position is None
    assert placed.available_balance == pytest.approx(900)
    assert len(placed.pending_orders) == 1
    assert placed.pending_orders[0].order_kind.value == "OPEN"
    assert placed.pending_orders[0].price == 95
    assert filled.pending_orders == ()
    assert filled.position is not None
    assert filled.position.entry_price == 95
    assert filled.position.quantity == pytest.approx(1000 / 95)


def test_limit_open_order_can_be_cancelled_before_fill() -> None:
    game = session(candle(0, close=100), candle(1, close=99, low=98))
    placed = game.place_limit_open_order(
        PositionSide.LONG,
        notional=100,
        leverage=2,
        price=95,
    )

    cancelled = game.cancel_order(placed.pending_orders[0].order_id)
    advanced = game.advance()

    assert cancelled.pending_orders == ()
    assert cancelled.available_balance == 1000
    assert advanced.position is None


def test_session_uses_persisted_account_balance_without_resetting_it() -> None:
    game = session(candle(0), candle(1, close=110))
    game.balance = 1250

    opened = game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    closed = game.advance()

    assert opened.balance == 1250
    assert opened.available_balance == 1150
    assert closed.balance == pytest.approx(1350)
    assert closed.realized_pnl == pytest.approx(350)


def test_snapshot_calculates_change_from_utc8_0800_open_price() -> None:
    game = session(candle(12, open_price=105, close=110), candle(13, close=115))
    game.lookback_candles = (candle(0, open_price=100, close=101),)

    initial = game.snapshot()
    advanced = game.advance()

    assert initial.anchored_price_change == pytest.approx(10)
    assert initial.anchored_price_change_percent == pytest.approx(10)
    assert advanced.anchored_price_change == pytest.approx(15)
    assert advanced.anchored_price_change_percent == pytest.approx(15)


def test_utc8_anchor_uses_previous_day_before_0800_and_resets_at_0800() -> None:
    before_reset = datetime(2026, 1, 2, 23, 59, tzinfo=UTC)
    at_reset = datetime(2026, 1, 3, 0, 0, tzinfo=UTC)

    assert utc8_price_anchor(before_reset) == datetime(2026, 1, 2, tzinfo=UTC)
    assert utc8_price_anchor(at_reset) == datetime(2026, 1, 3, tzinfo=UTC)


def test_snapshot_resets_anchored_change_at_next_utc8_0800() -> None:
    game = session(
        candle(287, close=120),
        candle(288, open_price=200, close=202),
    )
    game.lookback_candles = (candle(0, open_price=100, close=101),)

    before_reset = game.snapshot()
    after_reset = game.advance()

    assert before_reset.anchored_price_change == pytest.approx(20)
    assert before_reset.anchored_price_change_percent == pytest.approx(20)
    assert after_reset.anchored_price_change == pytest.approx(2)
    assert after_reset.anchored_price_change_percent == pytest.approx(1)


def test_snapshot_uses_previous_close_when_utc8_0800_candle_is_missing() -> None:
    game = session(candle(12, close=110), candle(13, close=115))
    game.lookback_candles = (candle(-1, close=90),)

    result = game.snapshot()

    assert result.anchored_price_change == pytest.approx(20)
    assert result.anchored_price_change_percent == pytest.approx(22.2222222)


def test_snapshot_omits_anchored_change_when_reference_candle_is_missing() -> None:
    game = session(candle(12), candle(13))
    game.lookback_candles = (candle(-2, close=80),)

    result = game.snapshot()

    assert result.anchored_price_change is None
    assert result.anchored_price_change_percent is None


def test_snapshot_uses_precomputed_ema_for_current_revealed_candle() -> None:
    game = session(candle(0, close=120), candle(1, close=140))
    game.ema_values = ((110.0, 90.0), (120.0, 95.0))

    initial = game.snapshot()
    advanced = game.advance()

    assert initial.ema20 == 110
    assert initial.ema240 == 90
    assert advanced.ema20 == 120
    assert advanced.ema240 == 95


def test_take_profit_closes_position_at_trigger_price() -> None:
    game = session(candle(0), candle(1, close=108, high=112, low=99), candle(2))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)

    configured = game.set_risk_orders(take_profit_price=110, stop_loss_price=95)
    result = game.advance()

    assert configured.position is not None
    assert configured.position.take_profit_price == 110
    assert configured.position.stop_loss_price == 95
    assert [order.order_type.value for order in configured.pending_orders] == [
        "LIMIT",
        "STOP_MARKET",
    ]
    assert result.position is None
    assert result.balance == pytest.approx(1100)
    assert result.trades[0].exit_price == 110
    assert result.trades[0].exit_reason == "TAKE_PROFIT"


def test_take_profit_pending_order_can_be_cancelled() -> None:
    game = session(candle(0), candle(1, close=105, high=111), candle(2))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    configured = game.set_risk_orders(take_profit_price=110, stop_loss_price=None)

    cancelled = game.cancel_order(configured.pending_orders[0].order_id)
    advanced = game.advance()

    assert cancelled.position is not None
    assert cancelled.position.take_profit_price is None
    assert cancelled.pending_orders == ()
    assert advanced.position is not None


def test_replacing_take_profit_cancels_old_order_and_uses_latest_order() -> None:
    game = session(candle(0), candle(1, close=106, high=111, low=99), candle(2))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    game.set_risk_orders(
        take_profit_price=105,
        stop_loss_price=95,
        take_profit_quantity=4,
    )

    replaced = game.set_risk_orders(
        take_profit_price=110,
        stop_loss_price=95,
        take_profit_quantity=6,
    )
    result = game.advance()

    assert replaced.message == "已取消原止盈委托, 并创建最新止盈委托"
    assert replaced.position is not None
    assert replaced.position.take_profit_price == 110
    assert replaced.position.take_profit_quantity == 6
    assert result.position is not None
    assert result.position.quantity == pytest.approx(4)
    assert result.position.take_profit_price is None
    assert result.balance == pytest.approx(1060)
    assert result.trades[0].quantity == pytest.approx(6)
    assert result.trades[0].exit_price == 110


def test_partial_market_close_keeps_remaining_position_open() -> None:
    game = session(candle(0), candle(1, close=110), candle(2))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    game.advance()

    result = game.close_position(quantity=2.5)

    assert result.position is not None
    assert result.position.quantity == pytest.approx(7.5)
    assert result.position.margin == pytest.approx(75)
    assert result.balance == pytest.approx(1025)
    assert result.trades[0].quantity == pytest.approx(2.5)
    assert result.trades[0].exit_reason == "MANUAL"


def test_marketable_long_limit_close_fills_at_current_close() -> None:
    game = session(candle(0, close=100), candle(1, close=105), candle(2))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    game.advance()

    result = game.place_limit_close_order(price=103)

    assert result.position is None
    assert result.pending_orders == ()
    assert result.balance == pytest.approx(1050)
    assert result.trades[0].exit_price == 105
    assert result.trades[0].exit_reason == "TAKE_PROFIT"
    assert result.message == "平仓限价已按当前收盘价成交"


def test_marketable_short_limit_close_fills_at_current_close() -> None:
    game = session(candle(0, close=100), candle(1, close=95), candle(2))
    game.open_position(PositionSide.SHORT, notional=1000, leverage=10)
    game.advance()

    result = game.place_limit_close_order(price=97)

    assert result.position is None
    assert result.pending_orders == ()
    assert result.balance == pytest.approx(1050)
    assert result.trades[0].exit_price == 95
    assert result.trades[0].exit_reason == "TAKE_PROFIT"


def test_non_marketable_limit_close_remains_pending() -> None:
    game = session(candle(0, close=100), candle(1, close=105), candle(2))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)
    game.advance()

    result = game.place_limit_close_order(price=110, quantity=4)

    assert result.position is not None
    assert result.position.take_profit_price == 110
    assert result.position.take_profit_quantity == 4
    assert len(result.pending_orders) == 1
    assert result.pending_orders[0].price == 110


def test_rejects_close_quantity_above_current_position() -> None:
    game = session(candle(0), candle(1))
    game.open_position(PositionSide.LONG, notional=1000, leverage=10)

    with pytest.raises(ValueError, match="不能超过"):
        game.close_position(quantity=10.1)


def test_stop_loss_has_conservative_priority_when_both_triggers_touch() -> None:
    game = session(candle(0), candle(1, close=100, high=106, low=94), candle(2))
    game.open_position(PositionSide.LONG, notional=200, leverage=2)
    game.set_risk_orders(take_profit_price=105, stop_loss_price=95)

    result = game.advance()

    assert result.position is None
    assert result.balance == pytest.approx(990)
    assert result.trades[0].exit_price == 95
    assert result.trades[0].exit_reason == "STOP_LOSS"


def test_stop_loss_prevents_liquidation_and_session_can_continue() -> None:
    game = session(
        candle(0),
        candle(1, close=92, low=89),
        candle(2, close=98),
        candle(3, close=101),
    )
    game.open_position(PositionSide.LONG, notional=10000, leverage=10)
    game.set_risk_orders(take_profit_price=None, stop_loss_price=95)

    stopped = game.advance()

    assert stopped.status is GameStatus.RUNNING
    assert stopped.position is None
    assert stopped.balance == pytest.approx(500)
    assert stopped.trades[0].exit_reason == "STOP_LOSS"
    assert stopped.message == "价格触及止损价, 持仓已平仓, 可继续交易"

    continued = game.advance()
    reopened = game.open_position(PositionSide.LONG, notional=100, leverage=2)

    assert continued.status is GameStatus.RUNNING
    assert continued.revealed_count == 3
    assert reopened.position is not None


def test_rejects_risk_prices_on_wrong_side_of_current_market() -> None:
    game = session(candle(0), candle(1))
    game.open_position(PositionSide.SHORT, notional=100, leverage=2)

    with pytest.raises(ValueError, match="空仓止盈价"):
        game.set_risk_orders(take_profit_price=101, stop_loss_price=None)
    with pytest.raises(ValueError, match="空仓止损价"):
        game.set_risk_orders(take_profit_price=None, stop_loss_price=99)
