from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class PositionSide(StrEnum):
    LONG = "LONG"
    SHORT = "SHORT"


class GameStatus(StrEnum):
    READY = "READY"
    RUNNING = "RUNNING"
    COMPLETED = "COMPLETED"
    LIQUIDATED = "LIQUIDATED"


class PaperCandle(BaseModel):
    model_config = ConfigDict(frozen=True, from_attributes=True)

    open_time: datetime
    close_time: datetime
    open_price: float
    high_price: float
    low_price: float
    close_price: float
    base_volume: float
    quote_volume: float


class PaperPosition(BaseModel):
    model_config = ConfigDict(frozen=True)

    side: PositionSide
    leverage: int
    margin: float
    quantity: float
    entry_price: float
    mark_price: float
    liquidation_price: float
    unrealized_pnl: float
    return_on_margin_percent: float


class PaperTrade(BaseModel):
    model_config = ConfigDict(frozen=True)

    side: PositionSide
    leverage: int
    margin: float
    quantity: float
    entry_price: float
    exit_price: float
    realized_pnl: float
    opened_at: datetime
    closed_at: datetime
    exit_reason: str


class PaperSessionCreate(BaseModel):
    symbol: str = Field(min_length=1, max_length=32)
    interval_seconds: int
    range_start: datetime
    range_end: datetime


class PaperOrderCreate(BaseModel):
    side: PositionSide
    margin: float = Field(gt=0)
    leverage: int = Field(ge=1, le=100)


class PaperSessionSnapshot(BaseModel):
    model_config = ConfigDict(frozen=True)

    session_id: str
    symbol: str
    interval_seconds: int
    range_start: datetime
    range_end: datetime
    status: GameStatus
    starting_balance: float
    balance: float
    available_balance: float
    equity: float
    realized_pnl: float
    revealed_count: int
    total_candles: int
    current_candle: PaperCandle
    position: PaperPosition | None = None
    trades: tuple[PaperTrade, ...] = ()
    message: str | None = None


class PaperMarketRange(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str
    available_from: datetime | None = None
    available_to: datetime | None = None


class PaperMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbols: tuple[str, ...] = ("BTCUSDT", "ETHUSDT")
    intervals: tuple[int, ...] = (300, 900, 3600)
    starting_balance: float = 1000
    maximum_leverage: int = 100
    maintenance_margin_rate: float = 0.005
    ranges: tuple[PaperMarketRange, ...] = ()
