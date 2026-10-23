from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime, time, timedelta, timezone
from uuid import uuid4

from auto_trade.paper_trading.models import (
    GameStatus,
    NotionalUnit,
    PaperCandle,
    PaperOrderKind,
    PaperOrderType,
    PaperPendingOrder,
    PaperPosition,
    PaperSessionSnapshot,
    PaperTrade,
    PositionSide,
)

STARTING_BALANCE = 1000.0
MAINTENANCE_MARGIN_RATE = 0.005
UTC8 = timezone(timedelta(hours=8))


def utc8_price_anchor(value: datetime) -> datetime:
    local_value = value.astimezone(UTC8)
    anchor = datetime.combine(local_value.date(), time(hour=8), tzinfo=UTC8)
    if local_value < anchor:
        anchor -= timedelta(days=1)
    return anchor.astimezone(UTC)


@dataclass(slots=True)
class OpenPosition:
    side: PositionSide
    leverage: int
    margin: float
    quantity: float
    entry_price: float
    liquidation_price: float
    opened_at: datetime
    take_profit_price: float | None = None
    take_profit_quantity: float | None = None
    take_profit_order_id: str | None = None
    take_profit_created_at: datetime | None = None
    stop_loss_price: float | None = None
    stop_loss_order_id: str | None = None
    stop_loss_created_at: datetime | None = None


@dataclass(slots=True)
class PendingOpenOrder:
    order_id: str
    side: PositionSide
    leverage: int
    margin: float
    quantity: float
    price: float
    created_at: datetime


@dataclass(slots=True)
class PaperSession:
    symbol: str
    interval_seconds: int
    candles: tuple[PaperCandle, ...]
    range_start: datetime
    range_end: datetime
    lookback_candles: tuple[PaperCandle, ...] = ()
    ema_values: tuple[tuple[float | None, float | None], ...] = ()
    session_id: str = field(default_factory=lambda: str(uuid4()))
    status: GameStatus = GameStatus.READY
    balance: float = STARTING_BALANCE
    index: int = 0
    position: OpenPosition | None = None
    pending_open_order: PendingOpenOrder | None = None
    trades: list[PaperTrade] = field(default_factory=list)
    message: str | None = None

    def open_position(
        self,
        side: PositionSide,
        notional: float,
        leverage: int,
        notional_unit: NotionalUnit = NotionalUnit.USDT,
    ) -> PaperSessionSnapshot:
        if self.status in (GameStatus.COMPLETED, GameStatus.LIQUIDATED):
            raise ValueError("本轮游戏已经结束, 请重新开始")
        if self.position is not None:
            raise ValueError("当前已有持仓, 请先平仓")
        if self.pending_open_order is not None:
            raise ValueError("当前已有开仓限价委托, 请先撤单")
        if leverage < 1 or leverage > 100:
            raise ValueError("杠杆倍数必须在 1 到 100 之间")
        if notional <= 0:
            raise ValueError("名义下单价值必须大于 0")
        entry_price = self.current_candle.close_price
        return self._open_position_at_price(
            side,
            notional,
            leverage,
            notional_unit,
            entry_price,
        )

    def place_limit_open_order(
        self,
        side: PositionSide,
        notional: float,
        leverage: int,
        price: float,
        notional_unit: NotionalUnit = NotionalUnit.USDT,
    ) -> PaperSessionSnapshot:
        if self.status in (GameStatus.COMPLETED, GameStatus.LIQUIDATED):
            raise ValueError("本轮游戏已经结束, 请重新开始")
        if self.position is not None:
            raise ValueError("当前已有持仓, 请先平仓")
        if self.pending_open_order is not None:
            raise ValueError("当前已有开仓限价委托, 请先撤单")
        if leverage < 1 or leverage > 100:
            raise ValueError("杠杆倍数必须在 1 到 100 之间")
        if notional <= 0:
            raise ValueError("名义下单价值必须大于 0")
        mark_price = self.current_candle.close_price
        if side is PositionSide.LONG and price >= mark_price:
            raise ValueError("开多限价必须低于当前价格")
        if side is PositionSide.SHORT and price <= mark_price:
            raise ValueError("开空限价必须高于当前价格")
        quantity = notional / price if notional_unit is NotionalUnit.USDT else notional
        margin = quantity * price / leverage
        if margin > self.balance:
            raise ValueError("名义下单价值所需保证金不能超过可用余额")
        self.pending_open_order = PendingOpenOrder(
            order_id=str(uuid4()),
            side=side,
            leverage=leverage,
            margin=margin,
            quantity=quantity,
            price=price,
            created_at=self.current_candle.close_time,
        )
        self.status = GameStatus.RUNNING
        self.message = f"已提交开{side.value}限价委托 {price:.2f}"
        return self.snapshot()

    def _open_position_at_price(
        self,
        side: PositionSide,
        notional: float,
        leverage: int,
        notional_unit: NotionalUnit,
        entry_price: float,
    ) -> PaperSessionSnapshot:
        quantity = notional / entry_price if notional_unit is NotionalUnit.USDT else notional
        notional_usdt = quantity * entry_price
        margin = notional_usdt / leverage
        if margin > self.balance:
            raise ValueError("名义下单价值所需保证金不能超过可用余额")
        self.position = OpenPosition(
            side=side,
            leverage=leverage,
            margin=margin,
            quantity=quantity,
            entry_price=entry_price,
            liquidation_price=liquidation_price(
                side,
                entry_price,
                quantity,
                self.balance,
            ),
            opened_at=self.current_candle.close_time,
        )
        self.status = GameStatus.RUNNING
        self.message = (
            f"已按 {entry_price:.2f} 收盘价开{side.value}仓, "
            f"名义价值 {notional_usdt:.2f} USDT"
        )
        return self.snapshot()

    def cancel_order(self, order_id: str) -> PaperSessionSnapshot:
        if self.pending_open_order is not None and self.pending_open_order.order_id == order_id:
            self.pending_open_order = None
            self.message = "开仓限价委托已取消"
            return self.snapshot()
        position = self.position
        if position is not None and position.take_profit_order_id == order_id:
            position.take_profit_price = None
            position.take_profit_quantity = None
            position.take_profit_order_id = None
            position.take_profit_created_at = None
            self.message = "止盈限价委托已取消"
            return self.snapshot()
        if position is not None and position.stop_loss_order_id == order_id:
            position.stop_loss_price = None
            position.stop_loss_order_id = None
            position.stop_loss_created_at = None
            self.message = "止损委托已取消"
            return self.snapshot()
        raise ValueError("当前委托不存在或已成交")

    def close_position(
        self,
        reason: str = "MANUAL",
        quantity: float | None = None,
    ) -> PaperSessionSnapshot:
        if self.position is None:
            raise ValueError("当前没有可平持仓")
        close_quantity = self.position.quantity if quantity is None else quantity
        self._validate_close_quantity(close_quantity)
        fully_closed = self._settle_position(
            self.current_candle.close_price,
            reason,
            close_quantity,
        )
        self.message = "持仓已平仓" if fully_closed else "部分持仓已按市价平仓"
        return self.snapshot()

    def place_limit_close_order(
        self,
        price: float,
        quantity: float | None = None,
    ) -> PaperSessionSnapshot:
        position = self.position
        if position is None:
            raise ValueError("当前没有可平持仓")
        close_quantity = position.quantity if quantity is None else quantity
        self._validate_close_quantity(close_quantity)
        mark_price = self.current_candle.close_price
        is_marketable = (
            position.side is PositionSide.LONG and price <= mark_price
        ) or (
            position.side is PositionSide.SHORT and price >= mark_price
        )
        if is_marketable:
            fully_closed = self._settle_position(
                mark_price,
                "TAKE_PROFIT",
                close_quantity,
            )
            self.message = (
                "平仓限价已按当前收盘价成交"
                if fully_closed
                else "部分持仓已按当前收盘价成交"
            )
            return self.snapshot()
        return self.set_risk_orders(
            take_profit_price=price,
            stop_loss_price=position.stop_loss_price,
            take_profit_quantity=close_quantity,
        )

    def set_risk_orders(
        self,
        take_profit_price: float | None,
        stop_loss_price: float | None,
        take_profit_quantity: float | None = None,
    ) -> PaperSessionSnapshot:
        position = self.position
        if position is None:
            raise ValueError("当前没有可设置止盈止损的持仓")
        mark_price = self.current_candle.close_price
        if position.side is PositionSide.LONG:
            if take_profit_price is not None and take_profit_price <= mark_price:
                raise ValueError("多仓止盈价必须高于当前价格")
            if stop_loss_price is not None and stop_loss_price >= mark_price:
                raise ValueError("多仓止损价必须低于当前价格")
        else:
            if take_profit_price is not None and take_profit_price >= mark_price:
                raise ValueError("空仓止盈价必须低于当前价格")
            if stop_loss_price is not None and stop_loss_price <= mark_price:
                raise ValueError("空仓止损价必须高于当前价格")
        if take_profit_price is not None:
            take_profit_quantity = (
                position.quantity
                if take_profit_quantity is None
                else take_profit_quantity
            )
            self._validate_close_quantity(take_profit_quantity)
        else:
            take_profit_quantity = None
        replacing_take_profit = position.take_profit_price is not None
        position.take_profit_price = take_profit_price
        position.take_profit_quantity = take_profit_quantity
        position.take_profit_order_id = str(uuid4()) if take_profit_price is not None else None
        position.take_profit_created_at = (
            self.current_candle.close_time if take_profit_price is not None else None
        )
        position.stop_loss_price = stop_loss_price
        position.stop_loss_order_id = str(uuid4()) if stop_loss_price is not None else None
        position.stop_loss_created_at = (
            self.current_candle.close_time if stop_loss_price is not None else None
        )
        self.message = (
            "已取消原止盈委托, 并创建最新止盈委托"
            if replacing_take_profit and take_profit_price is not None
            else "止盈止损已更新"
        )
        return self.snapshot()

    def advance(self) -> PaperSessionSnapshot:
        if self.status in (GameStatus.COMPLETED, GameStatus.LIQUIDATED):
            return self.snapshot()
        if self.index >= len(self.candles) - 1:
            self._complete()
            return self.snapshot()

        self.index += 1
        self.status = GameStatus.RUNNING
        candle = self.current_candle
        pending_open_order = self.pending_open_order
        if pending_open_order is not None:
            order_touched = (
                candle.low_price <= pending_open_order.price
                if pending_open_order.side is PositionSide.LONG
                else candle.high_price >= pending_open_order.price
            )
            if order_touched:
                self.pending_open_order = None
                self._open_position_at_price(
                    pending_open_order.side,
                    pending_open_order.quantity,
                    pending_open_order.leverage,
                    NotionalUnit.BASE,
                    pending_open_order.price,
                )
                self.message = f"开仓限价委托已按 {pending_open_order.price:.2f} 成交"
                return self.snapshot()
        position = self.position
        if position is not None:
            stop_price = position.stop_loss_price
            stop_touched = (
                stop_price is not None
                and (
                    candle.low_price <= stop_price
                    if position.side is PositionSide.LONG
                    else candle.high_price >= stop_price
                )
            )
            if stop_touched and stop_price is not None:
                self._settle_position(stop_price, "STOP_LOSS")
                self.message = "价格触及止损价, 持仓已平仓, 可继续交易"
                return self.snapshot()
            touched = (
                position.liquidation_price > 0
                and candle.low_price <= position.liquidation_price
                if position.side is PositionSide.LONG
                else candle.high_price >= position.liquidation_price
            )
            if touched:
                self._settle_position(position.liquidation_price, "LIQUIDATION")
                self.status = GameStatus.LIQUIDATED
                self.message = "价格触及强平价, 本轮游戏结束"
                return self.snapshot()
            take_profit_price = position.take_profit_price
            take_profit_touched = (
                take_profit_price is not None
                and (
                    candle.high_price >= take_profit_price
                    if position.side is PositionSide.LONG
                    else candle.low_price <= take_profit_price
                )
            )
            if take_profit_touched and take_profit_price is not None:
                take_profit_quantity = position.take_profit_quantity or position.quantity
                fully_closed = self._settle_position(
                    take_profit_price,
                    "TAKE_PROFIT",
                    take_profit_quantity,
                )
                self.message = (
                    "价格触及止盈价, 持仓已平仓"
                    if fully_closed
                    else "价格触及止盈价, 止盈委托已成交"
                )
                return self.snapshot()

        if self.index >= len(self.candles) - 1:
            self._complete()
        else:
            self.message = None
        return self.snapshot()

    @property
    def current_candle(self) -> PaperCandle:
        return self.candles[self.index]

    def snapshot(self) -> PaperSessionSnapshot:
        mark_price = self.current_candle.close_price
        anchored_change, anchored_change_percent = self._anchored_price_change()
        ema20, ema240 = (
            self.ema_values[self.index]
            if self.index < len(self.ema_values)
            else (None, None)
        )
        position = None
        unrealized_pnl = 0.0
        if self.position is not None:
            unrealized_pnl = position_pnl(self.position, mark_price)
            position = PaperPosition(
                side=self.position.side,
                leverage=self.position.leverage,
                margin=self.position.margin,
                quantity=self.position.quantity,
                entry_price=self.position.entry_price,
                mark_price=mark_price,
                liquidation_price=self.position.liquidation_price,
                take_profit_price=self.position.take_profit_price,
                take_profit_quantity=self.position.take_profit_quantity,
                stop_loss_price=self.position.stop_loss_price,
                unrealized_pnl=unrealized_pnl,
                return_on_margin_percent=unrealized_pnl / self.position.margin * 100,
            )
        locked_margin = self.position.margin if self.position is not None else 0.0
        reserved_margin = (
            self.pending_open_order.margin
            if self.pending_open_order is not None
            else 0.0
        )
        pending_orders: list[PaperPendingOrder] = []
        if self.pending_open_order is not None:
            pending_orders.append(
                PaperPendingOrder(
                    order_id=self.pending_open_order.order_id,
                    order_kind=PaperOrderKind.OPEN,
                    order_type=PaperOrderType.LIMIT,
                    position_side=self.pending_open_order.side,
                    price=self.pending_open_order.price,
                    quantity=self.pending_open_order.quantity,
                    leverage=self.pending_open_order.leverage,
                    created_at=self.pending_open_order.created_at,
                )
            )
        if self.position is not None and self.position.take_profit_price is not None:
            pending_orders.append(
                PaperPendingOrder(
                    order_id=self.position.take_profit_order_id or "take-profit",
                    order_kind=PaperOrderKind.CLOSE,
                    order_type=PaperOrderType.LIMIT,
                    position_side=self.position.side,
                    price=self.position.take_profit_price,
                    quantity=self.position.take_profit_quantity or self.position.quantity,
                    leverage=self.position.leverage,
                    created_at=self.position.take_profit_created_at or self.position.opened_at,
                )
            )
        if self.position is not None and self.position.stop_loss_price is not None:
            pending_orders.append(
                PaperPendingOrder(
                    order_id=self.position.stop_loss_order_id or "stop-loss",
                    order_kind=PaperOrderKind.CLOSE,
                    order_type=PaperOrderType.STOP_MARKET,
                    position_side=self.position.side,
                    price=self.position.stop_loss_price,
                    quantity=self.position.quantity,
                    leverage=self.position.leverage,
                    created_at=self.position.stop_loss_created_at or self.position.opened_at,
                )
            )
        return PaperSessionSnapshot(
            session_id=self.session_id,
            symbol=self.symbol,
            interval_seconds=self.interval_seconds,
            range_start=self.range_start,
            range_end=self.range_end,
            status=self.status,
            starting_balance=STARTING_BALANCE,
            balance=self.balance,
            available_balance=max(0.0, self.balance - locked_margin - reserved_margin),
            equity=max(0.0, self.balance + unrealized_pnl),
            realized_pnl=self.balance - STARTING_BALANCE,
            revealed_count=self.index + 1,
            total_candles=len(self.candles),
            current_candle=self.current_candle,
            ema20=ema20,
            ema240=ema240,
            anchored_price_change=anchored_change,
            anchored_price_change_percent=anchored_change_percent,
            position=position,
            pending_orders=tuple(pending_orders),
            trades=tuple(self.trades),
            message=self.message,
        )

    def _anchored_price_change(self) -> tuple[float | None, float | None]:
        anchor_time = utc8_price_anchor(self.current_candle.open_time)
        history = self.lookback_candles + self.candles[: self.index + 1]
        reference = next(
            (
                candle
                for candle in reversed(history)
                if candle.open_time == anchor_time
            ),
            None,
        )
        reference_price = reference.open_price if reference is not None else None
        if reference_price is None:
            previous = next(
                (
                    candle
                    for candle in reversed(history)
                    if candle.close_time == anchor_time
                ),
                None,
            )
            reference_price = previous.close_price if previous is not None else None
        if reference_price is None or reference_price <= 0:
            return None, None
        change = self.current_candle.close_price - reference_price
        return change, change / reference_price * 100

    def _complete(self) -> None:
        self.pending_open_order = None
        if self.position is not None:
            self._settle_position(self.current_candle.close_price, "RANGE_END")
        self.status = GameStatus.COMPLETED
        self.message = "已回放到所选行情末尾, 本轮游戏结束"

    def _validate_close_quantity(self, quantity: float) -> None:
        position = self.position
        if position is None:
            raise ValueError("当前没有可平持仓")
        if quantity <= 0:
            raise ValueError("平仓数量必须大于 0")
        if quantity > position.quantity + 1e-12:
            raise ValueError("平仓数量不能超过当前持仓数量")

    def _settle_position(
        self,
        exit_price: float,
        reason: str,
        quantity: float | None = None,
    ) -> bool:
        position = self.position
        if position is None:
            return True
        close_quantity = position.quantity if quantity is None else min(quantity, position.quantity)
        original_quantity = position.quantity
        closed_margin = position.margin * close_quantity / original_quantity
        direction = 1.0 if position.side is PositionSide.LONG else -1.0
        pnl = direction * close_quantity * (exit_price - position.entry_price)
        self.balance = max(0.0, self.balance + pnl)
        self.trades.append(
            PaperTrade(
                side=position.side,
                leverage=position.leverage,
                margin=closed_margin,
                quantity=close_quantity,
                entry_price=position.entry_price,
                exit_price=exit_price,
                realized_pnl=pnl,
                opened_at=position.opened_at,
                closed_at=self.current_candle.close_time,
                exit_reason=reason,
            )
        )
        if close_quantity >= original_quantity - 1e-12:
            self.position = None
            return True
        position.quantity = original_quantity - close_quantity
        position.margin -= closed_margin
        position.take_profit_price = None
        position.take_profit_quantity = None
        position.take_profit_order_id = None
        position.take_profit_created_at = None
        position.liquidation_price = liquidation_price(
            position.side,
            position.entry_price,
            position.quantity,
            self.balance,
        )
        return False


def position_pnl(position: OpenPosition, mark_price: float) -> float:
    direction = 1.0 if position.side is PositionSide.LONG else -1.0
    return direction * position.quantity * (mark_price - position.entry_price)


def liquidation_price(
    side: PositionSide,
    entry_price: float,
    quantity: float,
    account_balance: float,
    maintenance_margin_rate: float = MAINTENANCE_MARGIN_RATE,
) -> float:
    """Return the single-position cross-margin liquidation price."""
    if quantity <= 0:
        raise ValueError("quantity must be positive")
    if side is PositionSide.LONG:
        price = (entry_price - account_balance / quantity) / (
            1 - maintenance_margin_rate
        )
        return max(0.0, price)
    return (entry_price + account_balance / quantity) / (
        1 + maintenance_margin_rate
    )
