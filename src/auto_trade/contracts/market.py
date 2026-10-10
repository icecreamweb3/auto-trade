from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Literal
from uuid import NAMESPACE_URL, UUID, uuid5

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    SerializeAsAny,
    field_validator,
    model_validator,
)

PositiveDecimal = Annotated[Decimal, Field(gt=0)]
NonNegativeDecimal = Annotated[Decimal, Field(ge=0)]


class MarketSource(StrEnum):
    WEBSOCKET = "WEBSOCKET"
    REST = "REST"
    ARCHIVE = "ARCHIVE"
    BACKFILL = "BACKFILL"
    DERIVED = "DERIVED"


class PriceType(StrEnum):
    TRADE = "TRADE"
    MARK = "MARK"
    INDEX = "INDEX"
    PREMIUM_INDEX = "PREMIUM_INDEX"


class QualityStatus(StrEnum):
    VALID = "VALID"
    PARTIAL = "PARTIAL"
    DEGRADED = "DEGRADED"
    INVALID = "INVALID"
    QUARANTINED = "QUARANTINED"


def _require_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(UTC)


def _require_usdt_symbol(value: str) -> str:
    if not value.endswith("USDT"):
        raise ValueError("symbol must be a USDT contract")
    return value


def deterministic_event_id(*parts: object) -> UUID:
    """Build a stable idempotency ID from an event's canonical business key."""

    canonical = "|".join(str(part) for part in parts)
    return uuid5(NAMESPACE_URL, f"auto-trade:v1:{canonical}")


class EventEnvelope[PayloadT: BaseModel](BaseModel):
    model_config = ConfigDict(frozen=True)

    event_id: UUID
    event_type: str = Field(min_length=1, max_length=80)
    schema_version: int = Field(default=1, ge=1)
    source: MarketSource
    exchange_event_time: datetime | None = None
    collected_at: datetime
    node_id: str = Field(min_length=1, max_length=80)
    shard_id: str = Field(default="0", min_length=1, max_length=80)
    payload: SerializeAsAny[PayloadT]

    _validate_collected_at = field_validator("collected_at")(_require_utc)
    _validate_exchange_time = field_validator("exchange_event_time")(
        lambda value: None if value is None else _require_utc(value)
    )


class KlinePayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    exchange: Literal["BINANCE"] = "BINANCE"
    market: Literal["USD_M_FUTURES"] = "USD_M_FUTURES"
    symbol: str = Field(min_length=5, max_length=32)
    price_type: PriceType
    interval_seconds: int = Field(ge=60, le=604800)
    open_time: datetime
    close_time: datetime
    open_price: PositiveDecimal
    high_price: PositiveDecimal
    low_price: PositiveDecimal
    close_price: PositiveDecimal
    base_volume: NonNegativeDecimal | None = None
    quote_volume: NonNegativeDecimal | None = None
    trade_count: int | None = Field(default=None, ge=0)
    is_closed: bool
    quality_status: QualityStatus

    _validate_open_time = field_validator("open_time")(_require_utc)
    _validate_close_time = field_validator("close_time")(_require_utc)
    _validate_symbol = field_validator("symbol")(_require_usdt_symbol)

    @model_validator(mode="after")
    def validate_kline(self) -> KlinePayload:
        if self.close_time <= self.open_time:
            raise ValueError("close_time must be after open_time")
        if self.high_price < max(self.open_price, self.close_price, self.low_price):
            raise ValueError("high_price is inconsistent with OHLC")
        if self.low_price > min(self.open_price, self.close_price, self.high_price):
            raise ValueError("low_price is inconsistent with OHLC")
        if self.price_type is PriceType.TRADE and (
            self.base_volume is None or self.quote_volume is None
        ):
            raise ValueError("trade klines require base_volume and quote_volume")
        return self


class TickerMinutePayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    exchange: Literal["BINANCE"] = "BINANCE"
    market: Literal["USD_M_FUTURES"] = "USD_M_FUTURES"
    symbol: str = Field(min_length=5, max_length=32)
    minute_time: datetime
    last_price: PositiveDecimal
    mark_price: PositiveDecimal | None = None
    index_price: PositiveDecimal | None = None
    price_change_24h: Decimal | None = None
    rolling_window_start: datetime | None = None
    rolling_window_end: datetime | None = None
    rolling_open_price: PositiveDecimal | None = None
    quote_volume_24h: NonNegativeDecimal | None = None
    high_price_24h: PositiveDecimal | None = None
    low_price_24h: PositiveDecimal | None = None
    current_funding_rate: Decimal | None = None
    next_funding_time: datetime | None = None
    quality_status: QualityStatus

    _validate_minute_time = field_validator("minute_time")(_require_utc)
    _validate_symbol = field_validator("symbol")(_require_usdt_symbol)
    _validate_window_start = field_validator("rolling_window_start")(
        lambda value: None if value is None else _require_utc(value)
    )
    _validate_window_end = field_validator("rolling_window_end")(
        lambda value: None if value is None else _require_utc(value)
    )
    _validate_next_funding_time = field_validator("next_funding_time")(
        lambda value: None if value is None else _require_utc(value)
    )

    @model_validator(mode="after")
    def validate_window(self) -> TickerMinutePayload:
        if (self.rolling_window_start is None) != (self.rolling_window_end is None):
            raise ValueError("rolling window start and end must be supplied together")
        if (
            self.rolling_window_start is not None
            and self.rolling_window_end is not None
            and self.rolling_window_end <= self.rolling_window_start
        ):
            raise ValueError("rolling_window_end must be after rolling_window_start")
        return self


class OpenInterestPayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    exchange: Literal["BINANCE"] = "BINANCE"
    market: Literal["USD_M_FUTURES"] = "USD_M_FUTURES"
    symbol: str = Field(min_length=5, max_length=32)
    observed_at: datetime
    open_interest_qty: NonNegativeDecimal
    mark_price: PositiveDecimal | None = None
    open_interest_value: NonNegativeDecimal | None = None
    quality_status: QualityStatus

    _validate_observed_at = field_validator("observed_at")(_require_utc)
    _validate_symbol = field_validator("symbol")(_require_usdt_symbol)

    @model_validator(mode="after")
    def validate_value_inputs(self) -> OpenInterestPayload:
        if self.open_interest_value is not None and self.mark_price is None:
            raise ValueError("open_interest_value requires mark_price")
        return self


class RankingEntryPayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    rank_no: int = Field(ge=1, le=50)
    symbol: str = Field(min_length=5, max_length=32)
    price_change: Decimal
    reference_open_price: PositiveDecimal | None = None
    snapshot_price: PositiveDecimal
    base_volume: NonNegativeDecimal | None = None
    quote_volume: NonNegativeDecimal | None = None
    amplitude: NonNegativeDecimal | None = None
    period_high_price: PositiveDecimal | None = None
    period_low_price: PositiveDecimal | None = None
    metrics: dict[str, object] = Field(default_factory=dict)

    _validate_symbol = field_validator("symbol")(_require_usdt_symbol)


class RankingSnapshotPayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    ranking_type: Literal["ROLLING_24H_5M", "UTC_DAILY_2355"]
    snapshot_at: datetime
    scheduled_at: datetime
    generated_at: datetime
    generation_mode: Literal["REALTIME", "BACKFILLED", "DERIVED"] = "REALTIME"
    window_start: datetime
    window_end: datetime
    entries: tuple[RankingEntryPayload, ...]
    quality_status: QualityStatus

    _validate_snapshot_at = field_validator("snapshot_at")(_require_utc)
    _validate_scheduled_at = field_validator("scheduled_at")(_require_utc)
    _validate_generated_at = field_validator("generated_at")(_require_utc)
    _validate_window_start = field_validator("window_start")(_require_utc)
    _validate_window_end = field_validator("window_end")(_require_utc)

    @model_validator(mode="after")
    def validate_snapshot(self) -> RankingSnapshotPayload:
        if self.window_end <= self.window_start:
            raise ValueError("window_end must be after window_start")
        if len(self.entries) > 50:
            raise ValueError("ranking snapshot cannot exceed 50 entries")
        ranks = [entry.rank_no for entry in self.entries]
        symbols = [entry.symbol for entry in self.entries]
        if ranks != list(range(1, len(self.entries) + 1)):
            raise ValueError("ranking entries must have contiguous ranks from 1")
        if len(symbols) != len(set(symbols)):
            raise ValueError("ranking entry symbols must be unique")
        return self


class InstrumentRulePayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    exchange: Literal["BINANCE"] = "BINANCE"
    market: Literal["USD_M_FUTURES"] = "USD_M_FUTURES"
    symbol: str = Field(min_length=5, max_length=32)
    base_asset: str = Field(min_length=1, max_length=24)
    quote_asset: Literal["USDT"] = "USDT"
    contract_type: Literal["PERPETUAL"] = "PERPETUAL"
    trading_status: str = Field(min_length=1, max_length=24)
    onboard_at: datetime | None = None
    price_precision: int = Field(ge=0)
    quantity_precision: int = Field(ge=0)
    tick_size: PositiveDecimal
    step_size: PositiveDecimal
    min_quantity: NonNegativeDecimal | None = None
    max_quantity: NonNegativeDecimal | None = None
    min_notional: NonNegativeDecimal | None = None
    market_step_size: PositiveDecimal | None = None
    market_min_quantity: NonNegativeDecimal | None = None
    market_max_quantity: NonNegativeDecimal | None = None
    max_open_orders: int | None = Field(default=None, ge=0)
    max_algo_orders: int | None = Field(default=None, ge=0)
    percent_price_rules: dict[str, object] = Field(default_factory=dict)
    complete_rule_payload: dict[str, object]

    _validate_onboard_at = field_validator("onboard_at")(
        lambda value: None if value is None else _require_utc(value)
    )
    _validate_symbol = field_validator("symbol")(_require_usdt_symbol)


class InstrumentCatalogPayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    exchange: Literal["BINANCE"] = "BINANCE"
    market: Literal["USD_M_FUTURES"] = "USD_M_FUTURES"
    snapshot_time: datetime
    symbols: tuple[str, ...]
    is_full_snapshot: bool = True

    _validate_snapshot_time = field_validator("snapshot_time")(_require_utc)

    @field_validator("symbols")
    @classmethod
    def validate_symbols(cls, values: tuple[str, ...]) -> tuple[str, ...]:
        if not values:
            raise ValueError("catalog snapshot must contain at least one symbol")
        if len(values) != len(set(values)):
            raise ValueError("catalog snapshot symbols must be unique")
        return tuple(_require_usdt_symbol(value) for value in values)
