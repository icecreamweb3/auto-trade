from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from auto_trade.monitoring.models import KlinePoint
from auto_trade.strategies.feature_scan import ALL_FACTORS, FactorName

BacktestStatus = Literal["QUEUED", "RUNNING", "COMPLETED", "FAILED"]


class BacktestParameters(BaseModel):
    model_config = ConfigDict(frozen=True)

    average_days: int = Field(default=7, ge=1, le=30)
    ema_cross_lookback_bars: int = Field(default=4, ge=1, le=96)
    rapid_price_window_bars: int = Field(default=4, ge=1, le=96)
    rapid_price_rise_percent: Decimal = Field(default=Decimal("3"), ge=0, le=1000)
    open_interest_window_bars: int = Field(default=4, ge=1, le=96)
    open_interest_rise_percent: Decimal = Field(default=Decimal("5"), ge=0, le=1000)
    volume_surge_multiple: Decimal = Field(default=Decimal("5"), ge=0, le=1000)
    amplitude_spike_multiple: Decimal = Field(default=Decimal("5"), ge=0, le=1000)
    amplitude_consecutive_bars: int = Field(default=2, ge=1, le=96)
    average_amplitude_max_percent: Decimal = Field(default=Decimal("2"), ge=0, le=100)
    required_factors: tuple[FactorName, ...] = ALL_FACTORS

    @field_validator("required_factors")
    @classmethod
    def validate_required_factors(
        cls, value: tuple[FactorName, ...]
    ) -> tuple[FactorName, ...]:
        if not value:
            raise ValueError("at least one factor must be selected")
        if len(set(value)) != len(value):
            raise ValueError("factors must not contain duplicates")
        return value


class BacktestCreateRequest(BaseModel):
    model_config = ConfigDict(frozen=True)

    start_at: datetime
    end_at: datetime
    symbols: tuple[str, ...] = ()
    parameters: BacktestParameters = Field(default_factory=BacktestParameters)

    @field_validator("start_at", "end_at")
    @classmethod
    def require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("time must include a timezone")
        return value

    @field_validator("symbols")
    @classmethod
    def normalize_symbols(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        normalized = tuple(
            dict.fromkeys(symbol.strip().upper() for symbol in value if symbol.strip())
        )
        if len(normalized) > 1000:
            raise ValueError("too many symbols")
        return normalized

    @model_validator(mode="after")
    def validate_range(self) -> BacktestCreateRequest:
        if self.start_at >= self.end_at:
            raise ValueError("start_at must be earlier than end_at")
        if self.end_at - self.start_at > timedelta(days=366):
            raise ValueError("backtest range must not exceed 366 days")
        return self


class BacktestFactorResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    passed: bool
    value: float | int | None = None
    threshold: str
    reason: str | None = None


class BacktestSignal(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str
    open_time: datetime
    close_price: float
    factors: dict[FactorName, BacktestFactorResult]


class BacktestJobResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    job_id: str
    status: BacktestStatus
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None
    scanned_instruments: int = 0
    total_instruments: int = 0
    signal_count: int = 0
    truncated: bool = False
    max_signals: int
    error: str | None = None
    request: BacktestCreateRequest
    signals: tuple[BacktestSignal, ...] = ()


class BacktestCreated(BaseModel):
    model_config = ConfigDict(frozen=True)

    job_id: str
    status: BacktestStatus


class BacktestMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    available_from: datetime | None = None
    available_to: datetime | None = None
    symbols: tuple[str, ...] = ()


class BacktestKlineResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str
    signal_time: datetime
    interval_seconds: int = 900
    items: tuple[KlinePoint, ...] = ()
