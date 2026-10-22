from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from uuid import uuid4

from auto_trade.paper_trading.models import (
    GameStatus,
    NotionalUnit,
    PaperCandle,
    PaperPosition,
    PaperSessionSnapshot,
    PaperTrade,
    PositionSide,
)

STARTING_BALANCE = 1000.0
MAINTENANCE_MARGIN_RATE = 0.005


@dataclass(slots=True)
class OpenPosition:
    side: PositionSide
    leverage: int
    margin: float
    quantity: float
    entry_price: float
    liquidation_price: float
    opened_at: datetime


@dataclass(slots=True)
class PaperSession:
    symbol: str
    interval_seconds: int
    candles: tuple[PaperCandle, ...]
    range_start: datetime
    range_end: datetime
    session_id: str = field(default_factory=lambda: str(uuid4()))
    status: GameStatus = GameStatus.READY
    balance: float = STARTING_BALANCE
    index: int = 0
    position: OpenPosition | None = None
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
        if leverage < 1 or leverage > 100:
            raise ValueError("杠杆倍数必须在 1 到 100 之间")
        if notional <= 0:
            raise ValueError("名义下单价值必须大于 0")
        candle = self.current_candle
        entry_price = candle.close_price
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
            liquidation_price=liquidation_price(side, entry_price, leverage),
            opened_at=candle.close_time,
        )
        self.status = GameStatus.RUNNING
        self.message = (
            f"已按 {entry_price:.2f} 收盘价开{side.value}仓, "
            f"名义价值 {notional_usdt:.2f} USDT"
        )
        return self.snapshot()

    def close_position(self, reason: str = "MANUAL") -> PaperSessionSnapshot:
        if self.position is None:
            raise ValueError("当前没有可平持仓")
        self._settle_position(self.current_candle.close_price, reason)
        self.message = "持仓已平仓"
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
        position = self.position
        if position is not None:
            touched = (
                candle.low_price <= position.liquidation_price
                if position.side is PositionSide.LONG
                else candle.high_price >= position.liquidation_price
            )
            if touched:
                self._settle_position(
                    position.liquidation_price,
                    "LIQUIDATION",
                    forced_loss=position.margin,
                )
                self.status = GameStatus.LIQUIDATED
                self.message = "价格触及强平价, 本轮游戏结束"
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
                unrealized_pnl=unrealized_pnl,
                return_on_margin_percent=unrealized_pnl / self.position.margin * 100,
            )
        locked_margin = self.position.margin if self.position is not None else 0.0
        return PaperSessionSnapshot(
            session_id=self.session_id,
            symbol=self.symbol,
            interval_seconds=self.interval_seconds,
            range_start=self.range_start,
            range_end=self.range_end,
            status=self.status,
            starting_balance=STARTING_BALANCE,
            balance=self.balance,
            available_balance=max(0.0, self.balance - locked_margin),
            equity=max(0.0, self.balance + unrealized_pnl),
            realized_pnl=self.balance - STARTING_BALANCE,
            revealed_count=self.index + 1,
            total_candles=len(self.candles),
            current_candle=self.current_candle,
            position=position,
            trades=tuple(self.trades),
            message=self.message,
        )

    def _complete(self) -> None:
        if self.position is not None:
            self._settle_position(self.current_candle.close_price, "RANGE_END")
        self.status = GameStatus.COMPLETED
        self.message = "已回放到所选行情末尾, 本轮游戏结束"

    def _settle_position(
        self, exit_price: float, reason: str, *, forced_loss: float | None = None
    ) -> None:
        position = self.position
        if position is None:
            return
        pnl = -forced_loss if forced_loss is not None else position_pnl(position, exit_price)
        self.balance = max(0.0, self.balance + pnl)
        self.trades.append(
            PaperTrade(
                side=position.side,
                leverage=position.leverage,
                margin=position.margin,
                quantity=position.quantity,
                entry_price=position.entry_price,
                exit_price=exit_price,
                realized_pnl=pnl,
                opened_at=position.opened_at,
                closed_at=self.current_candle.close_time,
                exit_reason=reason,
            )
        )
        self.position = None


def position_pnl(position: OpenPosition, mark_price: float) -> float:
    direction = 1.0 if position.side is PositionSide.LONG else -1.0
    return direction * position.quantity * (mark_price - position.entry_price)


def liquidation_price(
    side: PositionSide,
    entry_price: float,
    leverage: int,
    maintenance_margin_rate: float = MAINTENANCE_MARGIN_RATE,
) -> float:
    if side is PositionSide.LONG:
        return entry_price * (1 - 1 / leverage) / (1 - maintenance_margin_rate)
    return entry_price * (1 + 1 / leverage) / (1 + maintenance_margin_rate)
