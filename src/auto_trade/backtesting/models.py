from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from auto_trade.monitoring.models import KlinePoint
from auto_trade.strategies.feature_scan import (
    DEFAULT_ENABLED_FACTORS,
    DEFAULT_FACTOR_PARAMETERS,
    DEFAULT_FACTOR_WEIGHTS,
    FACTOR_DEFINITION_BY_NAME,
    FactorName,
)

BacktestStatus = Literal["QUEUED", "RUNNING", "COMPLETED", "FAILED"]


class BacktestParameters(BaseModel):
    model_config = ConfigDict(frozen=True)

    @model_validator(mode="before")
    @classmethod
    def add_scoring_anchors_to_legacy_strategy(cls, value: object) -> object:
        if not isinstance(value, dict):
            return value
        result = dict(value)
        upper_defaults = {
            "single_bar_price_rise_percent": (
                "single_bar_price_rise_saturation_percent",
                Decimal("2.5"),
            ),
            "volume_acceleration_average_multiple": (
                "volume_acceleration_average_saturation_multiple",
                Decimal("3"),
            ),
            "volume_acceleration_previous_multiple": (
                "volume_acceleration_previous_saturation_multiple",
                Decimal("2"),
            ),
            "rapid_price_rise_percent": (
                "rapid_price_rise_saturation_percent",
                Decimal("4"),
            ),
            "open_interest_rise_percent": (
                "open_interest_rise_saturation_percent",
                Decimal("8"),
            ),
            "volume_surge_multiple": (
                "volume_surge_saturation_multiple",
                Decimal("5"),
            ),
            "amplitude_spike_multiple": (
                "amplitude_spike_saturation_multiple",
                Decimal("5"),
            ),
        }
        for reference_key, (upper_key, default_upper) in upper_defaults.items():
            if reference_key in result and upper_key not in result:
                reference = Decimal(str(result[reference_key]))
                result[upper_key] = max(default_upper, reference * Decimal("1.5"))
        if (
            "average_amplitude_max_percent" in result
            and "average_amplitude_bad_percent" not in result
        ):
            reference = Decimal(str(result["average_amplitude_max_percent"]))
            result["average_amplitude_bad_percent"] = max(Decimal("2"), reference * Decimal(2))
        if (
            "average_amplitude_max_percent" in result
            and "average_amplitude_excellent_percent" not in result
        ):
            reference = Decimal(str(result["average_amplitude_max_percent"]))
            result["average_amplitude_excellent_percent"] = min(
                Decimal("0.6"), reference / Decimal(2)
            )
        configured_parameters = {
            name: dict(parameters)
            for name, parameters in result.get("factor_parameters", {}).items()
        }
        for factor_name, defaults in DEFAULT_FACTOR_PARAMETERS.items():
            factor_values = configured_parameters.setdefault(factor_name, {})
            for key, default in defaults.items():
                factor_values.setdefault(key, result.get(key, default))
        result["factor_parameters"] = configured_parameters
        return result

    average_days: int = Field(default=7, ge=1, le=30)
    bullish_sequence_bars: int = Field(default=2, ge=2, le=10)
    bullish_min_close_position_percent: Decimal = Field(default=Decimal("50"), ge=0, le=100)
    bullish_last_close_position_percent: Decimal = Field(default=Decimal("85"), ge=0, le=100)
    bullish_last_max_upper_shadow_percent: Decimal = Field(default=Decimal("15"), ge=0, le=100)
    single_bar_price_rise_percent: Decimal = Field(default=Decimal("0.8"), gt=0, le=1000)
    single_bar_price_rise_saturation_percent: Decimal = Field(default=Decimal("2.5"), gt=0, le=1000)
    volume_acceleration_average_bars: int = Field(default=20, ge=2, le=2016)
    volume_acceleration_average_multiple: Decimal = Field(default=Decimal("1.8"), gt=1, le=1000)
    volume_acceleration_average_saturation_multiple: Decimal = Field(
        default=Decimal("3"), gt=1, le=1000
    )
    volume_acceleration_previous_multiple: Decimal = Field(
        default=Decimal("1.2"), gt=Decimal("0.8"), le=1000
    )
    volume_acceleration_previous_saturation_multiple: Decimal = Field(
        default=Decimal("2"), gt=Decimal("0.8"), le=1000
    )
    ema_near_cross_gap_percent: Decimal = Field(default=Decimal("1"), ge=0, le=100)
    ema_gap_shrink_min_percent: Decimal = Field(default=Decimal("30"), ge=0, le=100)
    ema_cross_lookback_bars: int = Field(default=4, ge=1, le=96)
    rapid_price_window_bars: int = Field(default=4, ge=1, le=96)
    rapid_price_rise_percent: Decimal = Field(default=Decimal("1.5"), gt=0, le=1000)
    rapid_price_rise_saturation_percent: Decimal = Field(default=Decimal("4"), gt=0, le=1000)
    open_interest_window_bars: int = Field(default=4, ge=1, le=96)
    open_interest_rise_percent: Decimal = Field(default=Decimal("2"), gt=0, le=1000)
    open_interest_rise_saturation_percent: Decimal = Field(default=Decimal("8"), gt=0, le=1000)
    volume_surge_multiple: Decimal = Field(default=Decimal("2"), gt=1, le=1000)
    volume_surge_saturation_multiple: Decimal = Field(default=Decimal("5"), gt=1, le=1000)
    amplitude_spike_multiple: Decimal = Field(default=Decimal("2"), gt=1, le=1000)
    amplitude_spike_saturation_multiple: Decimal = Field(default=Decimal("5"), gt=1, le=1000)
    amplitude_consecutive_bars: int = Field(default=2, ge=1, le=96)
    average_amplitude_max_percent: Decimal = Field(default=Decimal("0.8"), gt=0, le=100)
    average_amplitude_excellent_percent: Decimal = Field(default=Decimal("0.6"), ge=0, le=100)
    average_amplitude_bad_percent: Decimal = Field(default=Decimal("2"), gt=0, le=100)
    trigger_single_bar_rise_percent: Decimal = Field(default=Decimal("0.6"), ge=0)
    trigger_rapid_price_rise_percent: Decimal = Field(default=Decimal("1.2"), ge=0)
    trigger_volume_average_multiple: Decimal = Field(default=Decimal("1.5"), ge=0)
    trigger_close_position_percent: Decimal = Field(default=Decimal("70"), ge=0, le=100)
    signal_score_threshold: Decimal = Field(default=Decimal("70"), ge=0, le=100)
    minimum_data_coverage_percent: Decimal = Field(default=Decimal("85"), ge=0, le=100)
    rearm_score_threshold: Decimal = Field(default=Decimal("60"), ge=0, le=100)
    cooldown_bars: int = Field(default=4, ge=1, le=96)
    score_improvement_for_repeat: Decimal = Field(default=Decimal("5"), ge=0, le=100)
    factor_weights: dict[FactorName, Decimal] = Field(
        default_factory=lambda: dict(DEFAULT_FACTOR_WEIGHTS)
    )
    factor_parameters: dict[FactorName, dict[str, Decimal]] = Field(
        default_factory=lambda: {
            name: {key: Decimal(value) for key, value in values.items()}
            for name, values in DEFAULT_FACTOR_PARAMETERS.items()
        }
    )
    required_factors: tuple[FactorName, ...] = DEFAULT_ENABLED_FACTORS

    @field_validator("required_factors")
    @classmethod
    def validate_required_factors(cls, value: tuple[FactorName, ...]) -> tuple[FactorName, ...]:
        if not value:
            raise ValueError("at least one factor must be selected")
        if len(set(value)) != len(value):
            raise ValueError("factors must not contain duplicates")
        return value

    @model_validator(mode="after")
    def validate_scoring_model(self) -> BacktestParameters:
        configured_values = {
            key: value
            for values in self.factor_parameters.values()
            for key, value in values.items()
        }

        def configured(key: str, fallback: Decimal) -> Decimal:
            return configured_values.get(key, fallback)

        pairs = (
            (
                configured(
                    "single_bar_price_rise_percent",
                    self.single_bar_price_rise_percent,
                ),
                configured(
                    "single_bar_price_rise_saturation_percent",
                    self.single_bar_price_rise_saturation_percent,
                ),
            ),
            (
                configured(
                    "volume_acceleration_average_multiple",
                    self.volume_acceleration_average_multiple,
                ),
                configured(
                    "volume_acceleration_average_saturation_multiple",
                    self.volume_acceleration_average_saturation_multiple,
                ),
            ),
            (
                configured(
                    "volume_acceleration_previous_multiple",
                    self.volume_acceleration_previous_multiple,
                ),
                configured(
                    "volume_acceleration_previous_saturation_multiple",
                    self.volume_acceleration_previous_saturation_multiple,
                ),
            ),
            (
                configured("rapid_price_rise_percent", self.rapid_price_rise_percent),
                configured(
                    "rapid_price_rise_saturation_percent",
                    self.rapid_price_rise_saturation_percent,
                ),
            ),
            (
                configured("open_interest_rise_percent", self.open_interest_rise_percent),
                configured(
                    "open_interest_rise_saturation_percent",
                    self.open_interest_rise_saturation_percent,
                ),
            ),
            (
                configured("volume_surge_multiple", self.volume_surge_multiple),
                configured(
                    "volume_surge_saturation_multiple",
                    self.volume_surge_saturation_multiple,
                ),
            ),
            (
                configured("amplitude_spike_multiple", self.amplitude_spike_multiple),
                configured(
                    "amplitude_spike_saturation_multiple",
                    self.amplitude_spike_saturation_multiple,
                ),
            ),
        )
        if any(reference >= saturation for reference, saturation in pairs):
            raise ValueError("factor saturation must be greater than its reference")
        if not (
            configured(
                "average_amplitude_excellent_percent",
                self.average_amplitude_excellent_percent,
            )
            < configured(
                "average_amplitude_max_percent",
                self.average_amplitude_max_percent,
            )
            < configured(
                "average_amplitude_bad_percent",
                self.average_amplitude_bad_percent,
            )
        ):
            raise ValueError("average amplitude anchors must be excellent < reference < bad")
        if self.rearm_score_threshold >= self.signal_score_threshold:
            raise ValueError("rearm score must be lower than signal score")
        unknown = set(self.required_factors) - set(FACTOR_DEFINITION_BY_NAME)
        if unknown:
            raise ValueError(f"unknown factors: {', '.join(sorted(unknown))}")
        missing = set(self.required_factors) - set(self.factor_weights)
        if missing or any(self.factor_weights[name] <= 0 for name in self.required_factors):
            raise ValueError("every selected factor must have a positive weight")
        for factor_name, values in self.factor_parameters.items():
            definition = FACTOR_DEFINITION_BY_NAME.get(factor_name)
            if definition is None:
                raise ValueError(f"unknown factor parameters: {factor_name}")
            known_keys = {parameter.key for parameter in definition.parameters}
            unknown_keys = set(values) - known_keys
            if unknown_keys:
                raise ValueError(
                    f"unknown parameters for {factor_name}: {', '.join(sorted(unknown_keys))}"
                )
            definitions = {parameter.key: parameter for parameter in definition.parameters}
            for key, value in values.items():
                parameter = definitions[key]
                if value < parameter.minimum or value > parameter.maximum:
                    raise ValueError(f"factor parameter out of range: {factor_name}.{key}")
                if parameter.value_type == "integer" and value != value.to_integral_value():
                    raise ValueError(f"factor parameter must be integer: {factor_name}.{key}")
        return self


class BacktestCreateRequest(BaseModel):
    model_config = ConfigDict(frozen=True)

    start_at: datetime
    end_at: datetime
    interval_seconds: Literal[300, 900] = 900
    generate_log: bool = False
    preserve_log_history: bool = False
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


class BacktestStrategyWrite(BaseModel):
    model_config = ConfigDict(frozen=True)

    name: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=2000)
    interval_seconds: Literal[300, 900] = 900
    parameters: BacktestParameters = Field(default_factory=BacktestParameters)

    @field_validator("name")
    @classmethod
    def normalize_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("strategy name must not be blank")
        return normalized

    @field_validator("description")
    @classmethod
    def normalize_description(cls, value: str) -> str:
        return value.strip()


class BacktestStrategy(BacktestStrategyWrite):
    strategy_id: UUID
    created_at: datetime
    updated_at: datetime


class BacktestFactorResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    passed: bool
    value: float | int | None = None
    threshold: str
    reason: str | None = None
    metrics: dict[str, float | int | bool] = Field(default_factory=dict)
    score: float = 0
    weight: float = 0
    contribution: float = 0
    available: bool = True


class BacktestSignal(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str
    open_time: datetime
    close_price: float
    factors: dict[FactorName, BacktestFactorResult]
    score: float = 0
    grade: str = "弱"
    coverage_percent: float = 0
    trigger_reason: str | None = None
    group_scores: dict[str, float] = Field(default_factory=dict)
    risk_flags: tuple[str, ...] = ()


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
    log_line_count: int = 0
    log_truncated: bool = False
    log_available: bool = False
    log_url: str | None = None
    max_log_lines: int
    error: str | None = None
    request: BacktestCreateRequest
    signals: tuple[BacktestSignal, ...] = ()


class BacktestCreated(BaseModel):
    model_config = ConfigDict(frozen=True)

    job_id: str
    status: BacktestStatus


class BacktestIntervalMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    available_from: datetime | None = None
    available_to: datetime | None = None
    symbols: tuple[str, ...] = ()


class BacktestFactorParameterMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    key: str
    label: str
    value_type: Literal["decimal", "integer"]
    default: float
    minimum: float
    maximum: float
    step: float


class BacktestFactorMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    name: str
    label: str
    group: str
    value_format: Literal["percent", "multiple", "bars", "number"]
    default_weight: float
    default_enabled: bool = True
    parameters: tuple[BacktestFactorParameterMetadata, ...] = ()


class BacktestMetadata(BaseModel):
    model_config = ConfigDict(frozen=True)

    intervals: dict[str, BacktestIntervalMetadata]
    factors: tuple[BacktestFactorMetadata, ...] = ()


class BacktestKlineResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str
    signal_time: datetime
    interval_seconds: Literal[300, 900]
    items: tuple[KlinePoint, ...] = ()
