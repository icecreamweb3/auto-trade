from __future__ import annotations

import argparse
import asyncio
import csv
import json
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass, field, replace
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import IO, Literal, cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from auto_trade.config import get_settings
from auto_trade.infrastructure.database import create_database_engine

FactorName = str
FactorParameterValue = Decimal | int


@dataclass(frozen=True, slots=True)
class FactorParameterDefinition:
    key: str
    label: str
    value_type: Literal["decimal", "integer"]
    default: FactorParameterValue
    minimum: FactorParameterValue
    maximum: FactorParameterValue
    step: FactorParameterValue


@dataclass(frozen=True, slots=True)
class FactorDefinition:
    name: FactorName
    label: str
    group: str
    default_weight: Decimal
    parameters: tuple[FactorParameterDefinition, ...]
    value_format: Literal["percent", "multiple", "bars", "number"] = "number"
    default_enabled: bool = True


def _decimal_parameter(
    key: str,
    label: str,
    default: str,
    minimum: str = "0",
    maximum: str = "1000",
    step: str = "0.01",
) -> FactorParameterDefinition:
    return FactorParameterDefinition(
        key, label, "decimal", Decimal(default), Decimal(minimum), Decimal(maximum), Decimal(step)
    )


def _integer_parameter(
    key: str,
    label: str,
    default: int,
    minimum: int = 1,
    maximum: int = 2016,
) -> FactorParameterDefinition:
    return FactorParameterDefinition(key, label, "integer", default, minimum, maximum, 1)


FACTOR_DEFINITIONS: tuple[FactorDefinition, ...] = (
    FactorDefinition(
        "bullish_candle_sequence",
        "连续强势阳线",
        "price_action",
        Decimal("12"),
        (
            _integer_parameter("bullish_sequence_bars", "连续阳线数量", 2, 2, 10),
            _decimal_parameter(
                "bullish_min_close_position_percent", "前序收盘位置 60 分 %", "50", maximum="100"
            ),
            _decimal_parameter(
                "bullish_last_close_position_percent", "最后收盘位置 60 分 %", "85", maximum="100"
            ),
            _decimal_parameter(
                "bullish_last_max_upper_shadow_percent", "最后上影线 60 分 %", "15", maximum="100"
            ),
        ),
        value_format="percent",
    ),
    FactorDefinition(
        "single_bar_price_rise",
        "单根 K 线快速拉升",
        "price_action",
        Decimal("8"),
        (
            _decimal_parameter(
                "single_bar_price_rise_percent",
                "60 分参考涨幅 %",
                "0.8",
                minimum="0.01",
            ),
            _decimal_parameter(
                "single_bar_price_rise_saturation_percent", "100 分饱和涨幅 %", "2.5"
            ),
        ),
        value_format="percent",
    ),
    FactorDefinition(
        "volume_acceleration",
        "短周期成交量加速",
        "volume",
        Decimal("15"),
        (
            _integer_parameter("volume_acceleration_average_bars", "均值窗口 K 根", 20, 2, 2016),
            _decimal_parameter(
                "volume_acceleration_average_multiple",
                "均值倍数 60 分",
                "1.8",
                minimum="1.01",
            ),
            _decimal_parameter(
                "volume_acceleration_average_saturation_multiple", "均值倍数 100 分", "3"
            ),
            _decimal_parameter(
                "volume_acceleration_previous_multiple",
                "上一根倍数 60 分",
                "1.2",
                minimum="0.81",
            ),
            _decimal_parameter(
                "volume_acceleration_previous_saturation_multiple", "上一根倍数 100 分", "2"
            ),
        ),
        value_format="multiple",
    ),
    FactorDefinition(
        "ema_bullish_setup",
        "EMA 金叉/临近金叉",
        "trend",
        Decimal("12"),
        (
            _decimal_parameter(
                "ema_near_cross_gap_percent", "临近差距 60 分 %", "1", maximum="100"
            ),
            _decimal_parameter(
                "ema_gap_shrink_min_percent", "差距收缩 60 分 %", "30", maximum="100"
            ),
        ),
        value_format="percent",
    ),
    FactorDefinition(
        "ema_bullish_cross",
        "EMA20 上穿 EMA240",
        "trend",
        Decimal("8"),
        (_integer_parameter("ema_cross_lookback_bars", "最近上穿窗口 K 根", 4, 1, 96),),
        value_format="bars",
    ),
    FactorDefinition(
        "rapid_price_rise",
        "价格快速拉升",
        "price_action",
        Decimal("10"),
        (
            _integer_parameter("rapid_price_window_bars", "价格窗口 K 根", 4, 1, 96),
            _decimal_parameter(
                "rapid_price_rise_percent",
                "60 分参考涨幅 %",
                "1.5",
                minimum="0.01",
            ),
            _decimal_parameter("rapid_price_rise_saturation_percent", "100 分饱和涨幅 %", "4"),
        ),
        value_format="percent",
    ),
    FactorDefinition(
        "open_interest_rise",
        "OI 价值快速提升",
        "participation",
        Decimal("10"),
        (
            _integer_parameter("open_interest_window_bars", "OI 窗口 K 根", 4, 1, 96),
            _decimal_parameter(
                "open_interest_rise_percent",
                "60 分参考涨幅 %",
                "2",
                minimum="0.01",
            ),
            _decimal_parameter("open_interest_rise_saturation_percent", "100 分饱和涨幅 %", "8"),
        ),
        value_format="percent",
    ),
    FactorDefinition(
        "volume_surge",
        "成交量暴涨",
        "volume",
        Decimal("10"),
        (
            _decimal_parameter(
                "volume_surge_multiple",
                "60 分参考均值倍数",
                "2",
                minimum="1.01",
            ),
            _decimal_parameter("volume_surge_saturation_multiple", "100 分饱和均值倍数", "5"),
        ),
        value_format="multiple",
    ),
    FactorDefinition(
        "amplitude_spike_streak",
        "连续振幅异常",
        "volatility",
        Decimal("7"),
        (
            _decimal_parameter(
                "amplitude_spike_multiple",
                "60 分参考均值倍数",
                "2",
                minimum="1.01",
            ),
            _decimal_parameter("amplitude_spike_saturation_multiple", "100 分饱和均值倍数", "5"),
            _integer_parameter("amplitude_consecutive_bars", "连续 K 线数量", 2, 1, 96),
        ),
        value_format="multiple",
    ),
    FactorDefinition(
        "low_average_amplitude",
        "低平均振幅背景",
        "volatility",
        Decimal("8"),
        (
            _decimal_parameter(
                "average_amplitude_excellent_percent", "100 分优秀振幅 %", "0.6", maximum="100"
            ),
            _decimal_parameter(
                "average_amplitude_max_percent", "60 分参考振幅 %", "0.8", maximum="100"
            ),
            _decimal_parameter(
                "average_amplitude_bad_percent", "0 分失效振幅 %", "2", maximum="100"
            ),
        ),
        value_format="percent",
    ),
)
FACTOR_DEFINITION_BY_NAME: Mapping[FactorName, FactorDefinition] = {
    definition.name: definition for definition in FACTOR_DEFINITIONS
}
DEFAULT_FACTOR_WEIGHTS: Mapping[FactorName, Decimal] = {
    definition.name: definition.default_weight for definition in FACTOR_DEFINITIONS
}
ALL_FACTORS: tuple[FactorName, ...] = tuple(definition.name for definition in FACTOR_DEFINITIONS)
DEFAULT_ENABLED_FACTORS: tuple[FactorName, ...] = tuple(
    definition.name for definition in FACTOR_DEFINITIONS if definition.default_enabled
)
DEFAULT_FACTOR_PARAMETERS: Mapping[FactorName, Mapping[str, FactorParameterValue]] = {
    definition.name: {parameter.key: parameter.default for parameter in definition.parameters}
    for definition in FACTOR_DEFINITIONS
}
EARLY_BREAKOUT_FACTORS: tuple[FactorName, ...] = (
    "bullish_candle_sequence",
    "single_bar_price_rise",
    "volume_acceleration",
    "ema_bullish_setup",
    "low_average_amplitude",
)
SUPPORTED_INTERVALS = (300, 900)
PERCENT_QUANTUM = Decimal("0.01")


@dataclass(frozen=True, slots=True)
class StrategyParameters:
    interval_seconds: int = 900
    lookback_days: int = 90
    average_days: int = 7
    bullish_sequence_bars: int = 2
    bullish_min_close_position_percent: Decimal = Decimal("50")
    bullish_last_close_position_percent: Decimal = Decimal("85")
    bullish_last_max_upper_shadow_percent: Decimal = Decimal("15")
    single_bar_price_rise_percent: Decimal = Decimal("0.8")
    single_bar_price_rise_saturation_percent: Decimal = Decimal("2.5")
    volume_acceleration_average_bars: int = 20
    volume_acceleration_average_multiple: Decimal = Decimal("1.8")
    volume_acceleration_average_saturation_multiple: Decimal = Decimal("3")
    volume_acceleration_previous_multiple: Decimal = Decimal("1.2")
    volume_acceleration_previous_saturation_multiple: Decimal = Decimal("2")
    ema_near_cross_gap_percent: Decimal = Decimal("1")
    ema_gap_shrink_min_percent: Decimal = Decimal("30")
    ema_cross_lookback_bars: int = 4
    rapid_price_window_bars: int = 4
    rapid_price_rise_percent: Decimal = Decimal("1.5")
    rapid_price_rise_saturation_percent: Decimal = Decimal("4")
    open_interest_window_bars: int = 4
    open_interest_rise_percent: Decimal = Decimal("2")
    open_interest_rise_saturation_percent: Decimal = Decimal("8")
    volume_surge_multiple: Decimal = Decimal("2")
    volume_surge_saturation_multiple: Decimal = Decimal("5")
    amplitude_spike_multiple: Decimal = Decimal("2")
    amplitude_spike_saturation_multiple: Decimal = Decimal("5")
    amplitude_consecutive_bars: int = 2
    average_amplitude_max_percent: Decimal = Decimal("0.8")
    average_amplitude_excellent_percent: Decimal = Decimal("0.6")
    average_amplitude_bad_percent: Decimal = Decimal("2")
    trigger_single_bar_rise_percent: Decimal = Decimal("0.6")
    trigger_rapid_price_rise_percent: Decimal = Decimal("1.2")
    trigger_volume_average_multiple: Decimal = Decimal("1.5")
    trigger_close_position_percent: Decimal = Decimal("70")
    signal_score_threshold: Decimal = Decimal("70")
    minimum_data_coverage_percent: Decimal = Decimal("85")
    rearm_score_threshold: Decimal = Decimal("60")
    cooldown_bars: int = 4
    score_improvement_for_repeat: Decimal = Decimal("5")
    factor_weights: Mapping[FactorName, Decimal] = field(
        default_factory=lambda: dict(DEFAULT_FACTOR_WEIGHTS)
    )
    factor_parameters: Mapping[FactorName, Mapping[str, FactorParameterValue]] = field(
        default_factory=dict
    )
    required_factors: tuple[FactorName, ...] = DEFAULT_ENABLED_FACTORS

    def __post_init__(self) -> None:
        unknown_factors = set(self.required_factors) - set(FACTOR_DEFINITION_BY_NAME)
        if unknown_factors:
            raise ValueError(f"unknown factors: {', '.join(sorted(unknown_factors))}")
        for factor_name, values in self.factor_parameters.items():
            definition = FACTOR_DEFINITION_BY_NAME.get(factor_name)
            if definition is None:
                raise ValueError(f"unknown factor parameters: {factor_name}")
            definitions = {parameter.key: parameter for parameter in definition.parameters}
            for key, raw_value in values.items():
                parameter = definitions.get(key)
                if parameter is None:
                    raise ValueError(f"unknown parameter {factor_name}.{key}")
                value: FactorParameterValue = (
                    int(raw_value) if parameter.value_type == "integer" else Decimal(raw_value)
                )
                if value < parameter.minimum or value > parameter.maximum:
                    raise ValueError(f"factor parameter out of range: {factor_name}.{key}")
                if hasattr(self, key):
                    object.__setattr__(self, key, value)
        if self.interval_seconds not in SUPPORTED_INTERVALS:
            raise ValueError("interval_seconds must be 300 or 900")
        positive_integers = (
            self.lookback_days,
            self.average_days,
            self.bullish_sequence_bars,
            self.volume_acceleration_average_bars,
            self.ema_cross_lookback_bars,
            self.rapid_price_window_bars,
            self.open_interest_window_bars,
            self.amplitude_consecutive_bars,
            self.cooldown_bars,
        )
        if any(value <= 0 for value in positive_integers):
            raise ValueError("day and bar parameters must be positive")
        nonnegative_decimals = (
            self.bullish_min_close_position_percent,
            self.bullish_last_close_position_percent,
            self.bullish_last_max_upper_shadow_percent,
            self.single_bar_price_rise_percent,
            self.single_bar_price_rise_saturation_percent,
            self.volume_acceleration_average_multiple,
            self.volume_acceleration_average_saturation_multiple,
            self.volume_acceleration_previous_multiple,
            self.volume_acceleration_previous_saturation_multiple,
            self.ema_near_cross_gap_percent,
            self.ema_gap_shrink_min_percent,
            self.rapid_price_rise_percent,
            self.rapid_price_rise_saturation_percent,
            self.open_interest_rise_percent,
            self.open_interest_rise_saturation_percent,
            self.volume_surge_multiple,
            self.volume_surge_saturation_multiple,
            self.amplitude_spike_multiple,
            self.amplitude_spike_saturation_multiple,
            self.average_amplitude_max_percent,
            self.average_amplitude_excellent_percent,
            self.average_amplitude_bad_percent,
            self.trigger_single_bar_rise_percent,
            self.trigger_rapid_price_rise_percent,
            self.trigger_volume_average_multiple,
            self.trigger_close_position_percent,
            self.signal_score_threshold,
            self.minimum_data_coverage_percent,
            self.rearm_score_threshold,
            self.score_improvement_for_repeat,
        )
        if any(value < 0 for value in nonnegative_decimals):
            raise ValueError("factor thresholds must be nonnegative")
        bounded_percentages = (
            self.bullish_min_close_position_percent,
            self.bullish_last_close_position_percent,
            self.bullish_last_max_upper_shadow_percent,
            self.ema_gap_shrink_min_percent,
        )
        if any(value > 100 for value in bounded_percentages):
            raise ValueError("bounded percentage thresholds must not exceed 100")
        if not self.required_factors:
            raise ValueError("at least one required factor is needed")
        if len(set(self.required_factors)) != len(self.required_factors):
            raise ValueError("required factors must not contain duplicates")
        missing_weights = set(self.required_factors) - set(self.factor_weights)
        if missing_weights:
            raise ValueError("every selected factor must have a weight")
        if any(self.factor_weights[name] <= 0 for name in self.required_factors):
            raise ValueError("selected factor weights must be positive")
        ordered_score_ranges = (
            (
                self.single_bar_price_rise_percent,
                self.single_bar_price_rise_saturation_percent,
            ),
            (
                self.volume_acceleration_average_multiple,
                self.volume_acceleration_average_saturation_multiple,
            ),
            (
                self.volume_acceleration_previous_multiple,
                self.volume_acceleration_previous_saturation_multiple,
            ),
            (
                self.rapid_price_rise_percent,
                self.rapid_price_rise_saturation_percent,
            ),
            (
                self.open_interest_rise_percent,
                self.open_interest_rise_saturation_percent,
            ),
            (self.volume_surge_multiple, self.volume_surge_saturation_multiple),
            (
                self.amplitude_spike_multiple,
                self.amplitude_spike_saturation_multiple,
            ),
        )
        if any(reference >= saturation for reference, saturation in ordered_score_ranges):
            raise ValueError("factor saturation must be greater than its reference")
        score_lowers = (
            (self.single_bar_price_rise_percent, Decimal(0)),
            (self.volume_acceleration_average_multiple, Decimal(1)),
            (self.volume_acceleration_previous_multiple, Decimal("0.8")),
            (self.rapid_price_rise_percent, Decimal(0)),
            (self.open_interest_rise_percent, Decimal(0)),
            (self.volume_surge_multiple, Decimal(1)),
            (self.amplitude_spike_multiple, Decimal(1)),
        )
        if any(reference <= lower for reference, lower in score_lowers):
            raise ValueError("factor references must be greater than scoring lower bounds")
        if not (
            self.average_amplitude_excellent_percent
            < self.average_amplitude_max_percent
            < self.average_amplitude_bad_percent
        ):
            raise ValueError("average amplitude anchors must be excellent < reference < bad")
        if self.rearm_score_threshold >= self.signal_score_threshold:
            raise ValueError("rearm score must be lower than signal score")
        if self.signal_score_threshold > 100 or self.minimum_data_coverage_percent > 100:
            raise ValueError("score and coverage thresholds must not exceed 100")

    def factor_parameter(self, factor_name: FactorName, key: str) -> FactorParameterValue:
        configured = self.factor_parameters.get(factor_name, {})
        if key in configured:
            return configured[key]
        definition = FACTOR_DEFINITION_BY_NAME[factor_name]
        return next(
            parameter.default for parameter in definition.parameters if parameter.key == key
        )

    @property
    def average_bars(self) -> int:
        return self.average_days * 24 * 60 * 60 // self.interval_seconds

    @property
    def warmup_bars(self) -> int:
        return self.average_bars + max(
            self.ema_cross_lookback_bars,
            self.bullish_sequence_bars,
            self.volume_acceleration_average_bars,
            self.rapid_price_window_bars,
            self.open_interest_window_bars,
            self.amplitude_consecutive_bars,
        )


@dataclass(frozen=True, slots=True)
class FeatureBar:
    open_time: datetime
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal
    price_precision: int | None
    ema20: Decimal
    ema240: Decimal
    base_volume: Decimal
    quote_volume: Decimal
    amplitude_percent: Decimal
    open_interest_value: Decimal | None


@dataclass(frozen=True, slots=True)
class FactorResult:
    passed: bool
    value: Decimal | int | None
    threshold: str
    reason: str | None = None
    metrics: Mapping[str, Decimal | int | bool] = field(default_factory=dict)
    score: Decimal = Decimal(0)
    weight: Decimal = Decimal(0)
    contribution: Decimal = Decimal(0)
    available: bool = True


@dataclass(frozen=True, slots=True)
class StrategySignal:
    symbol: str
    open_time: datetime
    close_price: Decimal
    factors: Mapping[FactorName, FactorResult]
    score: Decimal = Decimal(0)
    grade: str = "弱"
    coverage_percent: Decimal = Decimal(0)
    trigger_reason: str | None = None
    group_scores: Mapping[str, Decimal] = field(default_factory=dict)
    risk_flags: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class StrategyEvaluation:
    symbol: str
    bar_number: int
    open_time: datetime
    close_price: Decimal
    price_precision: int | None
    ema20: Decimal
    ema240: Decimal
    base_volume: Decimal
    quote_volume: Decimal
    factors: Mapping[FactorName, FactorResult]
    matched: bool
    candidate_triggered: bool = False
    trigger_reason: str | None = None
    score: Decimal = Decimal(0)
    grade: str = "弱"
    coverage_percent: Decimal = Decimal(0)
    group_scores: Mapping[str, Decimal] = field(default_factory=dict)
    risk_flags: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class DatabaseScanResult:
    signals: tuple[StrategySignal, ...]
    scanned_instruments: int
    total_instruments: int
    truncated: bool = False


class SeriesContext:
    def __init__(self, bars: Sequence[FeatureBar], interval_seconds: int) -> None:
        self.bars = bars
        self.volume_prefix = self._prefix("quote_volume")
        self.amplitude_prefix = self._prefix("amplitude_percent")
        self.contiguous_count: list[int] = []
        expected_delta = timedelta(seconds=interval_seconds)
        for index, bar in enumerate(bars):
            if index and bar.open_time - bars[index - 1].open_time == expected_delta:
                self.contiguous_count.append(self.contiguous_count[-1] + 1)
            else:
                self.contiguous_count.append(1)

    def _prefix(self, attribute: str) -> list[Decimal]:
        result = [Decimal(0)]
        for bar in self.bars:
            result.append(result[-1] + cast(Decimal, getattr(bar, attribute)))
        return result

    def average_before(self, index: int, count: int, attribute: str) -> Decimal | None:
        if index < count or self.contiguous_count[index] < count + 1:
            return None
        prefix = self.volume_prefix if attribute == "quote_volume" else self.amplitude_prefix
        return (prefix[index] - prefix[index - count]) / Decimal(count)

    def is_contiguous(self, index: int, required_count: int) -> bool:
        return index >= 0 and self.contiguous_count[index] >= required_count


def _candle_percent(numerator: Decimal, bar: FeatureBar) -> Decimal | None:
    candle_range = bar.high_price - bar.low_price
    if candle_range <= 0:
        return None
    return _percent_2(numerator / candle_range * Decimal(100))


def _bullish_candle_sequence(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    count = parameters.bullish_sequence_bars
    threshold = (
        f"{count} bullish bars; prior close position >= "
        f"{parameters.bullish_min_close_position_percent:.2f}%; last >= "
        f"{parameters.bullish_last_close_position_percent:.2f}%; "
        f"last upper shadow <= {parameters.bullish_last_max_upper_shadow_percent:.2f}%"
    )
    if index < count - 1 or not context.is_contiguous(index, count):
        return FactorResult(
            False,
            None,
            threshold,
            "missing consecutive candle history",
            available=False,
        )
    bars = context.bars[index - count + 1 : index + 1]
    close_positions: list[Decimal] = []
    bullish_count = 0
    for bar in bars:
        close_position = _candle_percent(bar.close_price - bar.low_price, bar)
        if close_position is None:
            return FactorResult(
                False,
                None,
                threshold,
                "zero-range candle",
                available=False,
            )
        close_positions.append(close_position)
        bullish_count += int(bar.close_price > bar.open_price)
    prior_positions = close_positions[:-1]
    prior_minimum = _percent_2(parameters.bullish_min_close_position_percent)
    last_minimum = _percent_2(parameters.bullish_last_close_position_percent)
    last_bar = bars[-1]
    last_upper_shadow = _candle_percent(
        last_bar.high_price - max(last_bar.open_price, last_bar.close_price), last_bar
    )
    upper_maximum = _percent_2(parameters.bullish_last_max_upper_shadow_percent)
    passed = (
        bullish_count == count
        and all(value >= prior_minimum for value in prior_positions)
        and close_positions[-1] >= last_minimum
        and last_upper_shadow is not None
        and last_upper_shadow <= upper_maximum
    )
    reason = None
    if not passed:
        prior_value = min(prior_positions) if prior_positions else close_positions[-1]
        upper_value = f"{last_upper_shadow:.2f}" if last_upper_shadow is not None else "unavailable"
        reason = (
            f"bullish bars={bullish_count}/{count}, prior minimum={prior_value:.2f}%, "
            f"last close position={close_positions[-1]:.2f}%, "
            f"last upper shadow={upper_value}%"
        )
    return FactorResult(
        passed,
        close_positions[-1],
        threshold,
        reason,
        metrics={
            "bullish_count": bullish_count,
            "required_count": count,
            "prior_min_close_position": (
                min(prior_positions) if prior_positions else close_positions[-1]
            ),
            "last_close_position": close_positions[-1],
            "last_upper_shadow": last_upper_shadow or Decimal(0),
        },
    )


def _single_bar_price_rise(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    bar = context.bars[index]
    value = _percent_change(bar.close_price, bar.open_price)
    threshold_value = _percent_2(parameters.single_bar_price_rise_percent)
    return FactorResult(
        value is not None and value >= threshold_value,
        value,
        _percent_threshold(">=", parameters.single_bar_price_rise_percent),
        None if value is not None else "open price is unavailable or nonpositive",
    )


def _volume_acceleration(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    count = parameters.volume_acceleration_average_bars
    average = context.average_before(index, count, "quote_volume")
    threshold = (
        f">= {parameters.volume_acceleration_average_multiple}x prior {count}-bar average "
        f"and >= {parameters.volume_acceleration_previous_multiple}x previous bar"
    )
    if index < 1 or average is None or average <= 0:
        return FactorResult(False, None, threshold, "missing prior volume history", available=False)
    previous = context.bars[index - 1].quote_volume
    if previous <= 0:
        return FactorResult(
            False, None, threshold, "previous volume is nonpositive", available=False
        )
    average_ratio = context.bars[index].quote_volume / average
    previous_ratio = context.bars[index].quote_volume / previous
    passed = (
        average_ratio >= parameters.volume_acceleration_average_multiple
        and previous_ratio >= parameters.volume_acceleration_previous_multiple
    )
    reason = (
        None
        if passed
        else f"average ratio={average_ratio:.2f}x, previous ratio={previous_ratio:.2f}x"
    )
    return FactorResult(
        passed,
        average_ratio,
        threshold,
        reason,
        metrics={
            "average_ratio": average_ratio,
            "previous_ratio": previous_ratio,
        },
    )


def _ema_bullish_setup(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    threshold = (
        f"cross in prior {parameters.ema_cross_lookback_bars} bars or pre-cross gap <= "
        f"{parameters.ema_near_cross_gap_percent:.2f}% with gap shrink >= "
        f"{parameters.ema_gap_shrink_min_percent:.2f}%"
    )
    current = context.bars[index]
    if current.ema240 <= 0:
        return FactorResult(False, None, threshold, "EMA240 is nonpositive", available=False)
    gap = _percent_2((current.ema240 - current.ema20) / current.ema240 * Decimal(100))
    if current.ema20 >= current.ema240:
        cross = _ema_bullish_cross(context, index, parameters)
        return FactorResult(
            cross.passed,
            gap,
            threshold,
            None if cross.passed else "EMA cross is older than the configured window",
            metrics={
                "gap": gap,
                "gap_shrink": Decimal(100) if cross.passed else Decimal(0),
                "ema20_rising": current.ema20 > context.bars[index - 1].ema20
                if index > 0
                else False,
                "bars_since_cross": cross.value if cross.value is not None else -1,
                "crossed": cross.passed,
            },
        )
    if index < 1 or not context.is_contiguous(index, 2):
        return FactorResult(False, gap, threshold, "missing previous EMA values", available=False)
    previous = context.bars[index - 1]
    if previous.ema240 <= 0:
        return FactorResult(
            False, gap, threshold, "previous EMA240 is nonpositive", available=False
        )
    previous_gap = _percent_2((previous.ema240 - previous.ema20) / previous.ema240 * Decimal(100))
    gap_shrink = (
        _percent_2((previous_gap - gap) / previous_gap * Decimal(100))
        if previous_gap > 0
        else Decimal(0)
    )
    passed = (
        gap <= _percent_2(parameters.ema_near_cross_gap_percent)
        and current.ema20 > previous.ema20
        and previous_gap > gap
        and gap_shrink >= _percent_2(parameters.ema_gap_shrink_min_percent)
    )
    reason = None
    if not passed:
        reason = (
            f"gap={gap:.2f}%, previous gap={previous_gap:.2f}%, "
            f"gap shrink={gap_shrink:.2f}%, EMA20 rising={current.ema20 > previous.ema20}"
        )
    return FactorResult(
        passed,
        gap,
        threshold,
        reason,
        metrics={
            "gap": gap,
            "previous_gap": previous_gap,
            "gap_shrink": gap_shrink,
            "ema20_rising": current.ema20 > previous.ema20,
            "bars_since_cross": -1,
            "crossed": False,
        },
    )


def _ema_bullish_cross(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    first = max(1, index - parameters.ema_cross_lookback_bars + 1)
    for cross_index in range(index, first - 1, -1):
        current = context.bars[cross_index]
        previous = context.bars[cross_index - 1]
        bars_ago = index - cross_index
        if not context.is_contiguous(index, bars_ago + 2):
            continue
        if current.ema20 > current.ema240 and previous.ema20 <= previous.ema240:
            return FactorResult(
                True,
                bars_ago,
                f"bars_since_cross < {parameters.ema_cross_lookback_bars}",
                metrics={"bars_since_cross": bars_ago},
            )
    return FactorResult(
        False,
        None,
        f"bars_since_cross < {parameters.ema_cross_lookback_bars}",
        "no bullish EMA20/EMA240 cross in the configured window",
        metrics={"bars_since_cross": -1},
    )


def _percent_change(current: Decimal, previous: Decimal) -> Decimal | None:
    if previous <= 0:
        return None
    return _percent_2((current / previous - Decimal(1)) * Decimal(100))


def _percent_2(value: Decimal) -> Decimal:
    return value.quantize(PERCENT_QUANTUM, rounding=ROUND_HALF_UP)


def _percent_threshold(operator: str, value: Decimal) -> str:
    return f"{operator} {_percent_2(value):.2f}%"


def _rapid_price_rise(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    window = parameters.rapid_price_window_bars
    if index < window or not context.is_contiguous(index, window + 1):
        return FactorResult(
            False,
            None,
            _percent_threshold(">=", parameters.rapid_price_rise_percent),
            "missing continuous price history",
            available=False,
        )
    value = _percent_change(
        context.bars[index].close_price, context.bars[index - window].close_price
    )
    threshold = _percent_2(parameters.rapid_price_rise_percent)
    return FactorResult(
        value is not None and value >= threshold,
        value,
        f"{_percent_threshold('>=', parameters.rapid_price_rise_percent)} over {window} bars",
    )


def _open_interest_rise(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    window = parameters.open_interest_window_bars
    if index < window or not context.is_contiguous(index, window + 1):
        return FactorResult(
            False,
            None,
            _percent_threshold(">=", parameters.open_interest_rise_percent),
            "missing continuous OI history",
            available=False,
        )
    current = context.bars[index].open_interest_value
    previous = context.bars[index - window].open_interest_value
    if current is None or previous is None:
        return FactorResult(
            False,
            None,
            _percent_threshold(">=", parameters.open_interest_rise_percent),
            "OI value is unavailable",
            available=False,
        )
    value = _percent_change(current, previous)
    threshold = _percent_2(parameters.open_interest_rise_percent)
    return FactorResult(
        value is not None and value >= threshold,
        value,
        f"{_percent_threshold('>=', parameters.open_interest_rise_percent)} over {window} bars",
    )


def _volume_surge(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    average = context.average_before(index, parameters.average_bars, "quote_volume")
    if average is None or average <= 0:
        return FactorResult(
            False,
            None,
            f">= {parameters.volume_surge_multiple}x",
            "missing prior volume average",
            available=False,
        )
    value = context.bars[index].quote_volume / average
    return FactorResult(
        value >= parameters.volume_surge_multiple,
        value,
        f">= {parameters.volume_surge_multiple}x prior {parameters.average_days}d average",
    )


def _average_amplitude(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> Decimal | None:
    return context.average_before(index, parameters.average_bars, "amplitude_percent")


def _amplitude_spike_streak(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    start = index - parameters.amplitude_consecutive_bars + 1
    if start < 0 or not context.is_contiguous(index, parameters.amplitude_consecutive_bars):
        return FactorResult(
            False,
            None,
            f">= {parameters.amplitude_spike_multiple}x",
            "missing consecutive bars",
            available=False,
        )
    multiples: list[Decimal] = []
    for streak_index in range(start, index + 1):
        average = _average_amplitude(context, streak_index, parameters)
        if average is None or average <= 0:
            return FactorResult(
                False,
                None,
                f">= {parameters.amplitude_spike_multiple}x",
                "missing prior amplitude average",
                available=False,
            )
        multiples.append(context.bars[streak_index].amplitude_percent / average)
    value = min(multiples)
    return FactorResult(
        value >= parameters.amplitude_spike_multiple,
        value,
        f">= {parameters.amplitude_spike_multiple}x for "
        f"{parameters.amplitude_consecutive_bars} consecutive bars",
    )


def _low_average_amplitude(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    value = _average_amplitude(context, index, parameters)
    value = _percent_2(value) if value is not None else None
    threshold = _percent_2(parameters.average_amplitude_max_percent)
    return FactorResult(
        value is not None and value < threshold,
        value,
        f"{_percent_threshold('<', parameters.average_amplitude_max_percent)} "
        f"over prior {parameters.average_days}d",
        None if value is not None else "missing prior amplitude average",
        available=value is not None,
    )


FACTOR_EVALUATORS = {
    "bullish_candle_sequence": _bullish_candle_sequence,
    "single_bar_price_rise": _single_bar_price_rise,
    "volume_acceleration": _volume_acceleration,
    "ema_bullish_setup": _ema_bullish_setup,
    "ema_bullish_cross": _ema_bullish_cross,
    "rapid_price_rise": _rapid_price_rise,
    "open_interest_rise": _open_interest_rise,
    "volume_surge": _volume_surge,
    "amplitude_spike_streak": _amplitude_spike_streak,
    "low_average_amplitude": _low_average_amplitude,
}
if set(FACTOR_EVALUATORS) != set(FACTOR_DEFINITION_BY_NAME):
    raise RuntimeError("factor registry metadata and evaluators are inconsistent")


def _decimal_metric(result: FactorResult, name: str) -> Decimal | None:
    value = result.metrics.get(name)
    if isinstance(value, bool) or value is None:
        return None
    return Decimal(value) if isinstance(value, int) else value


def _score_up(
    value: Decimal | None,
    lower: Decimal,
    reference: Decimal,
    upper: Decimal,
) -> Decimal:
    if value is None or value <= lower:
        return Decimal(0)
    if value >= upper:
        return Decimal(100)
    if reference <= lower:
        return Decimal(60) + Decimal(40) * (value - lower) / (upper - lower)
    if value < reference:
        return Decimal(60) * (value - lower) / (reference - lower)
    return Decimal(60) + Decimal(40) * (value - reference) / (upper - reference)


def _score_down(
    value: Decimal | None,
    excellent: Decimal,
    reference: Decimal,
    bad: Decimal,
) -> Decimal:
    if value is None or value >= bad:
        return Decimal(0)
    if value <= excellent:
        return Decimal(100)
    if reference <= excellent:
        return Decimal(60) * (bad - value) / (bad - excellent)
    if value <= reference:
        return Decimal(100) - Decimal(40) * (value - excellent) / (reference - excellent)
    return Decimal(60) * (bad - value) / (bad - reference)


def _cross_recency_score(bars_ago: Decimal | None, lookback: int) -> Decimal:
    if bars_ago is None or bars_ago < 0 or bars_ago >= lookback:
        return Decimal(0)
    if lookback == 1:
        return Decimal(100)
    return Decimal(100) - Decimal(60) * bars_ago / Decimal(lookback - 1)


def _factor_score(
    name: FactorName,
    result: FactorResult,
    parameters: StrategyParameters,
) -> FactorResult:
    weight = parameters.factor_weights[name] if name in parameters.required_factors else Decimal(0)
    if not result.available:
        return replace(result, weight=weight)

    value = Decimal(result.value) if isinstance(result.value, int) else result.value
    score = Decimal(0)
    if name == "bullish_candle_sequence":
        prior = _score_up(
            _decimal_metric(result, "prior_min_close_position"),
            Decimal(0),
            parameters.bullish_min_close_position_percent,
            Decimal(100),
        )
        last = _score_up(
            _decimal_metric(result, "last_close_position"),
            Decimal(0),
            parameters.bullish_last_close_position_percent,
            Decimal(100),
        )
        shadow = _score_down(
            _decimal_metric(result, "last_upper_shadow"),
            Decimal(0),
            parameters.bullish_last_max_upper_shadow_percent,
            Decimal(100),
        )
        bullish_count = _decimal_metric(result, "bullish_count") or Decimal(0)
        required_count = _decimal_metric(result, "required_count") or Decimal(1)
        continuity = min(Decimal(100), bullish_count / required_count * Decimal(100))
        score = (
            prior * Decimal("0.35")
            + last * Decimal("0.35")
            + shadow * Decimal("0.20")
            + continuity * Decimal("0.10")
        )
    elif name == "single_bar_price_rise":
        score = _score_up(
            value,
            Decimal(0),
            parameters.single_bar_price_rise_percent,
            parameters.single_bar_price_rise_saturation_percent,
        )
    elif name == "volume_acceleration":
        average_score = _score_up(
            _decimal_metric(result, "average_ratio"),
            Decimal(1),
            parameters.volume_acceleration_average_multiple,
            parameters.volume_acceleration_average_saturation_multiple,
        )
        previous_score = _score_up(
            _decimal_metric(result, "previous_ratio"),
            Decimal("0.8"),
            parameters.volume_acceleration_previous_multiple,
            parameters.volume_acceleration_previous_saturation_multiple,
        )
        score = (average_score * previous_score).sqrt()
    elif name == "ema_bullish_setup":
        crossed = result.metrics.get("crossed") is True
        if crossed:
            score = _cross_recency_score(
                _decimal_metric(result, "bars_since_cross"),
                parameters.ema_cross_lookback_bars,
            )
        elif result.metrics.get("ema20_rising") is True:
            proximity = _score_down(
                _decimal_metric(result, "gap"),
                Decimal(0),
                parameters.ema_near_cross_gap_percent,
                max(Decimal("1.5"), parameters.ema_near_cross_gap_percent * 2),
            )
            shrink = _score_up(
                _decimal_metric(result, "gap_shrink"),
                Decimal(0),
                parameters.ema_gap_shrink_min_percent,
                max(
                    Decimal(80),
                    parameters.ema_gap_shrink_min_percent * Decimal("1.5"),
                ),
            )
            score = (proximity * shrink).sqrt()
    elif name == "ema_bullish_cross":
        score = _cross_recency_score(value, parameters.ema_cross_lookback_bars)
    elif name == "rapid_price_rise":
        score = _score_up(
            value,
            Decimal(0),
            parameters.rapid_price_rise_percent,
            parameters.rapid_price_rise_saturation_percent,
        )
    elif name == "open_interest_rise":
        score = _score_up(
            value,
            Decimal(0),
            parameters.open_interest_rise_percent,
            parameters.open_interest_rise_saturation_percent,
        )
    elif name == "volume_surge":
        score = _score_up(
            value,
            Decimal(1),
            parameters.volume_surge_multiple,
            parameters.volume_surge_saturation_multiple,
        )
    elif name == "amplitude_spike_streak":
        score = _score_up(
            value,
            Decimal(1),
            parameters.amplitude_spike_multiple,
            parameters.amplitude_spike_saturation_multiple,
        )
    elif name == "low_average_amplitude":
        score = _score_down(
            value,
            parameters.average_amplitude_excellent_percent,
            parameters.average_amplitude_max_percent,
            parameters.average_amplitude_bad_percent,
        )
    else:
        raise ValueError(f"factor scorer is not registered: {name}")

    score = min(Decimal(100), max(Decimal(0), score)).quantize(PERCENT_QUANTUM)
    return replace(
        result,
        score=score,
        weight=weight,
    )


def _signal_grade(score: Decimal) -> str:
    if score >= 90:
        return "S+"
    if score >= 80:
        return "S"
    if score >= 70:
        return "A"
    if score >= 60:
        return "观察"
    return "弱"


def _group_scores(
    factors: Mapping[FactorName, FactorResult], parameters: StrategyParameters
) -> Mapping[str, Decimal]:
    scores: dict[str, Decimal] = {}
    selected = set(parameters.required_factors)
    groups = dict.fromkeys(definition.group for definition in FACTOR_DEFINITIONS)
    for group in groups:
        enabled = tuple(
            definition.name
            for definition in FACTOR_DEFINITIONS
            if definition.group == group and definition.name in selected
        )
        weight = sum((factors[name].weight for name in enabled), Decimal(0))
        if weight <= 0:
            continue
        scores[group] = (
            sum(
                (factors[name].score * factors[name].weight for name in enabled),
                Decimal(0),
            )
            / weight
        ).quantize(PERCENT_QUANTUM)
    return scores


def _risk_flags(factors: Mapping[FactorName, FactorResult]) -> tuple[str, ...]:
    flags: list[str] = []
    single_result = factors.get("single_bar_price_rise")
    volume_result = factors.get("volume_surge")
    amplitude_result = factors.get("amplitude_spike_streak")
    single = single_result.value if single_result is not None else None
    volume = volume_result.value if volume_result is not None else None
    amplitude = amplitude_result.value if amplitude_result is not None else None
    if isinstance(single, Decimal) and single >= 5:
        flags.append("单根涨幅过热")
    if isinstance(volume, Decimal) and volume >= 10:
        flags.append("成交量极端放大")
    if isinstance(amplitude, Decimal) and amplitude >= 8:
        flags.append("振幅极端放大")
    return tuple(flags)


def _candidate_trigger(
    context: SeriesContext,
    index: int,
    parameters: StrategyParameters,
) -> tuple[bool, str | None]:
    bar = context.bars[index]
    if bar.close_price <= bar.open_price:
        return False, None
    reasons: list[str] = []
    single = _percent_change(bar.close_price, bar.open_price)
    if single is not None and single >= parameters.trigger_single_bar_rise_percent:
        reasons.append("单根涨幅")
    rapid = (
        _percent_change(
            bar.close_price,
            context.bars[index - parameters.rapid_price_window_bars].close_price,
        )
        if index >= parameters.rapid_price_window_bars
        and context.is_contiguous(index, parameters.rapid_price_window_bars + 1)
        else None
    )
    if rapid is not None and rapid >= parameters.trigger_rapid_price_rise_percent:
        reasons.append("窗口涨幅")
    average_volume = context.average_before(
        index, parameters.volume_acceleration_average_bars, "quote_volume"
    )
    volume_ratio = (
        bar.quote_volume / average_volume
        if average_volume is not None and average_volume > 0
        else None
    )
    close_position = _candle_percent(bar.close_price - bar.low_price, bar)
    if (
        volume_ratio is not None
        and close_position is not None
        and volume_ratio >= parameters.trigger_volume_average_multiple
        and close_position >= parameters.trigger_close_position_percent
    ):
        reasons.append("量价加速")
    return bool(reasons), "+".join(reasons) if reasons else None


def evaluate_series(
    symbol: str,
    bars: Sequence[FeatureBar],
    parameters: StrategyParameters,
    scan_start: datetime,
    evaluation_callback: Callable[[StrategyEvaluation], None] | None = None,
) -> tuple[StrategySignal, ...]:
    context = SeriesContext(bars, parameters.interval_seconds)
    signals: list[StrategySignal] = []
    bar_number = 0
    selected_weight = sum(
        (parameters.factor_weights[name] for name in parameters.required_factors),
        Decimal(0),
    )
    last_signal_index: int | None = None
    last_signal_score = Decimal(0)
    rearmed = True
    for index, bar in enumerate(bars):
        if bar.open_time < scan_start:
            continue
        bar_number += 1
        raw_factors = {
            name: FACTOR_EVALUATORS[name](context, index, parameters) for name in ALL_FACTORS
        }
        factors = {
            name: _factor_score(name, result, parameters) for name, result in raw_factors.items()
        }
        factors = {
            name: replace(
                result,
                contribution=(result.score * result.weight / selected_weight).quantize(
                    PERCENT_QUANTUM
                ),
            )
            for name, result in factors.items()
        }
        valid_weight = sum(
            (
                factors[name].weight
                for name in parameters.required_factors
                if factors[name].available
            ),
            Decimal(0),
        )
        coverage = (valid_weight / selected_weight * Decimal(100)).quantize(PERCENT_QUANTUM)
        score = (
            sum(
                (
                    factors[name].score * factors[name].weight
                    for name in parameters.required_factors
                ),
                Decimal(0),
            )
            / selected_weight
        ).quantize(PERCENT_QUANTUM)
        grade = _signal_grade(score)
        group_scores = _group_scores(factors, parameters)
        risk_flags = _risk_flags(factors)
        candidate, trigger_reason = _candidate_trigger(context, index, parameters)
        if score < parameters.rearm_score_threshold:
            rearmed = True
        cooldown_elapsed = (
            last_signal_index is None or index - last_signal_index >= parameters.cooldown_bars
        )
        improved = (
            last_signal_index is not None
            and score >= last_signal_score + parameters.score_improvement_for_repeat
        )
        qualified = (
            candidate
            and score >= parameters.signal_score_threshold
            and coverage >= parameters.minimum_data_coverage_percent
        )
        matched = qualified and cooldown_elapsed and (rearmed or improved)
        if matched:
            last_signal_index = index
            last_signal_score = score
            rearmed = False
        if evaluation_callback is not None:
            evaluation_callback(
                StrategyEvaluation(
                    symbol=symbol,
                    bar_number=bar_number,
                    open_time=bar.open_time,
                    close_price=bar.close_price,
                    price_precision=bar.price_precision,
                    ema20=bar.ema20,
                    ema240=bar.ema240,
                    base_volume=bar.base_volume,
                    quote_volume=bar.quote_volume,
                    factors=factors,
                    matched=matched,
                    candidate_triggered=candidate,
                    trigger_reason=trigger_reason,
                    score=score,
                    grade=grade,
                    coverage_percent=coverage,
                    group_scores=group_scores,
                    risk_flags=risk_flags,
                )
            )
        if matched:
            signals.append(
                StrategySignal(
                    symbol,
                    bar.open_time,
                    bar.close_price,
                    factors,
                    score,
                    grade,
                    coverage,
                    trigger_reason,
                    group_scores,
                    risk_flags,
                )
            )
    return tuple(signals)


async def _instrument_rows(
    connection: AsyncConnection,
    symbols: Sequence[str] | None,
    interval_seconds: int,
) -> Sequence[Mapping[str, object]]:
    source_condition = (
        """
        EXISTS (
            SELECT 1
            FROM market.klines_15m k
            WHERE k.instrument_id = i.instrument_id
              AND k.price_type = 'TRADE'
              AND k.interval_seconds = 900
        )
        """
        if interval_seconds == 900
        else """
        EXISTS (
            SELECT 1
            FROM market.klines k
            WHERE k.instrument_id = i.instrument_id
              AND k.price_type = 'TRADE'
              AND k.interval_seconds = 300
              AND k.is_current
              AND k.is_closed
              AND k.quality_status = 'VALID'
        )
        """
    )
    result = await connection.execute(
        text(
            f"""
            SELECT i.instrument_id, i.symbol
            FROM core.instruments i
            WHERE i.exchange = 'BINANCE'
              AND i.market = 'USD_M_FUTURES'
              AND i.contract_type = 'PERPETUAL'
              AND (:all_symbols OR upper(i.symbol) = ANY(CAST(:symbols AS text[])))
              AND {source_condition}
            ORDER BY i.symbol
            """
        ),
        {
            "all_symbols": not symbols,
            "symbols": [symbol.upper() for symbol in symbols] if symbols else [],
        },
    )
    return [cast(Mapping[str, object], row) for row in result.mappings().all()]


async def _load_feature_bars(
    connection: AsyncConnection,
    instrument_id: int,
    start: datetime,
    end: datetime,
    interval_seconds: int,
) -> tuple[FeatureBar, ...]:
    if interval_seconds == 900:
        source_sql = """
            SELECT e.open_time, k.open_price, k.high_price, k.low_price,
                   e.close_price, rules.price_precision,
                   e.ema20, e.ema240,
                   k.base_volume, k.quote_volume,
                   e.amplitude_percent, k.open_interest_value
            FROM market.kline_ema_indicators e
            JOIN market.klines_15m k
              ON k.instrument_id = e.instrument_id
             AND k.price_type = e.price_type
             AND k.interval_seconds = e.interval_seconds
             AND k.open_time = e.open_time
            LEFT JOIN LATERAL (
                SELECT r.price_precision
                FROM core.instrument_rule_versions r
                WHERE r.instrument_id = e.instrument_id
                ORDER BY (r.effective_from <= e.open_time) DESC,
                         CASE WHEN r.effective_from <= e.open_time
                              THEN r.effective_from END DESC,
                         CASE WHEN r.effective_from > e.open_time
                              THEN r.effective_from END ASC
                LIMIT 1
            ) rules ON true
            WHERE e.instrument_id = :instrument_id
              AND e.price_type = 'TRADE'
              AND e.interval_seconds = :interval_seconds
              AND e.open_time >= CAST(:start AS timestamptz)
              AND e.open_time < CAST(:end AS timestamptz)
              AND e.amplitude_percent IS NOT NULL
            ORDER BY e.open_time
        """
    else:
        source_sql = """
            SELECT e.open_time, k.open_price, k.high_price, k.low_price,
                   e.close_price, rules.price_precision,
                   e.ema20, e.ema240,
                   k.base_volume, k.quote_volume,
                   e.amplitude_percent, oi.open_interest_value
            FROM market.kline_ema_indicators e
            JOIN market.klines k
              ON k.instrument_id = e.instrument_id
             AND k.price_type = e.price_type
             AND k.interval_seconds = e.interval_seconds
             AND k.open_time = e.open_time
             AND k.is_current
             AND k.is_closed
             AND k.quality_status = 'VALID'
            LEFT JOIN LATERAL (
                SELECT r.price_precision
                FROM core.instrument_rule_versions r
                WHERE r.instrument_id = e.instrument_id
                ORDER BY (r.effective_from <= e.open_time) DESC,
                         CASE WHEN r.effective_from <= e.open_time
                              THEN r.effective_from END DESC,
                         CASE WHEN r.effective_from > e.open_time
                              THEN r.effective_from END ASC
                LIMIT 1
            ) rules ON true
            LEFT JOIN LATERAL (
                SELECT o.open_interest_value
                FROM market.open_interest_observations o
                WHERE o.instrument_id = e.instrument_id
                  AND o.observed_at >= e.open_time
                  AND o.observed_at < e.open_time + interval '5 minutes'
                  AND o.quality_status IN ('VALID', 'PARTIAL')
                ORDER BY o.observed_at DESC
                LIMIT 1
            ) oi ON true
            WHERE e.instrument_id = :instrument_id
              AND e.price_type = 'TRADE'
              AND e.interval_seconds = :interval_seconds
              AND e.open_time >= CAST(:start AS timestamptz)
              AND e.open_time < CAST(:end AS timestamptz)
              AND e.amplitude_percent IS NOT NULL
            ORDER BY e.open_time
        """
    result = await connection.execute(
        text(source_sql),
        {
            "instrument_id": instrument_id,
            "interval_seconds": interval_seconds,
            "start": start,
            "end": end,
        },
    )
    return tuple(
        FeatureBar(
            open_time=cast(datetime, row["open_time"]),
            open_price=Decimal(str(row["open_price"])),
            high_price=Decimal(str(row["high_price"])),
            low_price=Decimal(str(row["low_price"])),
            close_price=Decimal(str(row["close_price"])),
            price_precision=(
                int(row["price_precision"]) if row["price_precision"] is not None else None
            ),
            ema20=Decimal(str(row["ema20"])),
            ema240=Decimal(str(row["ema240"])),
            base_volume=Decimal(str(row["base_volume"])),
            quote_volume=Decimal(str(row["quote_volume"])),
            amplitude_percent=Decimal(str(row["amplitude_percent"])),
            open_interest_value=(
                Decimal(str(row["open_interest_value"]))
                if row["open_interest_value"] is not None
                else None
            ),
        )
        for row in result.mappings()
    )


async def scan_database(
    engine: AsyncEngine,
    parameters: StrategyParameters,
    *,
    symbols: Sequence[str] | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
) -> tuple[StrategySignal, ...]:
    result = await scan_database_detailed(
        engine,
        parameters,
        symbols=symbols,
        start=start,
        end=end,
    )
    return result.signals


async def scan_database_detailed(
    engine: AsyncEngine,
    parameters: StrategyParameters,
    *,
    symbols: Sequence[str] | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
    max_signals: int | None = None,
    progress_callback: Callable[[int, int], None] | None = None,
    signals_callback: Callable[[tuple[StrategySignal, ...]], None] | None = None,
    evaluation_callback: Callable[[StrategyEvaluation], None] | None = None,
) -> DatabaseScanResult:
    scan_end = end or datetime.now(UTC)
    scan_end = scan_end.replace(tzinfo=UTC) if scan_end.tzinfo is None else scan_end.astimezone(UTC)
    scan_end = datetime.fromtimestamp(
        int(scan_end.timestamp()) // parameters.interval_seconds * parameters.interval_seconds,
        tz=UTC,
    )
    scan_start = start or (scan_end - timedelta(days=parameters.lookback_days))
    scan_start = (
        scan_start.replace(tzinfo=UTC) if scan_start.tzinfo is None else scan_start.astimezone(UTC)
    )
    if scan_start >= scan_end:
        raise ValueError("scan start must be earlier than scan end")
    query_start = scan_start - timedelta(
        seconds=parameters.warmup_bars * parameters.interval_seconds
    )
    signals: list[StrategySignal] = []
    scanned_instruments = 0
    truncated = False
    async with engine.connect() as connection:
        instruments = await _instrument_rows(connection, symbols, parameters.interval_seconds)
        for instrument in instruments:
            bars = await _load_feature_bars(
                connection,
                cast(int, instrument["instrument_id"]),
                query_start,
                scan_end,
                parameters.interval_seconds,
            )
            instrument_signals = evaluate_series(
                cast(str, instrument["symbol"]),
                bars,
                parameters,
                scan_start,
                evaluation_callback,
            )
            if max_signals is not None:
                remaining = max_signals - len(signals)
                emitted_signals = instrument_signals[: max(0, remaining)]
                signals.extend(emitted_signals)
                truncated = len(instrument_signals) > remaining
            else:
                emitted_signals = instrument_signals
                signals.extend(instrument_signals)
            if signals_callback is not None and emitted_signals:
                signals_callback(emitted_signals)
            scanned_instruments += 1
            if progress_callback is not None:
                progress_callback(scanned_instruments, len(instruments))
            if truncated or (max_signals is not None and len(signals) >= max_signals):
                truncated = scanned_instruments < len(instruments) or truncated
                break
    return DatabaseScanResult(
        signals=tuple(sorted(signals, key=lambda signal: (signal.open_time, signal.symbol))),
        scanned_instruments=scanned_instruments,
        total_instruments=len(instruments),
        truncated=truncated,
    )


def _serialize_value(value: Decimal | int | bool | None) -> str | int | bool | None:
    return str(value) if isinstance(value, Decimal) else value


def signal_record(signal: StrategySignal) -> dict[str, object]:
    record: dict[str, object] = {
        "symbol": signal.symbol,
        "open_time": signal.open_time.isoformat(),
        "close_price": str(signal.close_price),
        "score": str(signal.score),
        "grade": signal.grade,
        "coverage_percent": str(signal.coverage_percent),
        "trigger_reason": signal.trigger_reason,
        "group_scores": {name: str(value) for name, value in signal.group_scores.items()},
        "risk_flags": signal.risk_flags,
    }
    for name in ALL_FACTORS:
        result = signal.factors[name]
        record[f"{name}_passed"] = result.passed
        record[f"{name}_value"] = _serialize_value(result.value)
        record[f"{name}_threshold"] = result.threshold
        record[f"{name}_reason"] = result.reason
        record[f"{name}_available"] = result.available
        record[f"{name}_score"] = str(result.score)
        record[f"{name}_weight"] = str(result.weight)
        record[f"{name}_contribution"] = str(result.contribution)
        record[f"{name}_metrics"] = {
            key: _serialize_value(value) for key, value in result.metrics.items()
        }
    return record


def write_signals(signals: Sequence[StrategySignal], output: IO[str], output_format: str) -> None:
    records = [signal_record(signal) for signal in signals]
    if output_format == "jsonl":
        for record in records:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
        return
    fieldnames = (
        list(signal_record(signals[0]).keys())
        if signals
        else [
            "symbol",
            "open_time",
            "close_price",
        ]
    )
    writer = csv.DictWriter(output, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(records)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scan configurable 5m/15m early-breakout and confirmation factors"
    )
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--interval-seconds", type=int, choices=SUPPORTED_INTERVALS, default=900)
    parser.add_argument("--symbols", nargs="*")
    parser.add_argument("--end", type=datetime.fromisoformat)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--format", choices=("jsonl", "csv"), default="jsonl")
    parser.add_argument("--average-days", type=int, default=7)
    parser.add_argument("--bullish-sequence-bars", type=int, default=2)
    parser.add_argument("--bullish-min-close-position-percent", type=Decimal, default=Decimal("50"))
    parser.add_argument(
        "--bullish-last-close-position-percent", type=Decimal, default=Decimal("85")
    )
    parser.add_argument(
        "--bullish-last-max-upper-shadow-percent", type=Decimal, default=Decimal("15")
    )
    parser.add_argument("--single-bar-price-rise-percent", type=Decimal, default=Decimal("0.8"))
    parser.add_argument("--volume-acceleration-average-bars", type=int, default=20)
    parser.add_argument(
        "--volume-acceleration-average-multiple", type=Decimal, default=Decimal("1.8")
    )
    parser.add_argument(
        "--volume-acceleration-previous-multiple",
        type=Decimal,
        default=Decimal("1.2"),
    )
    parser.add_argument("--ema-near-cross-gap-percent", type=Decimal, default=Decimal("1"))
    parser.add_argument("--ema-gap-shrink-min-percent", type=Decimal, default=Decimal("30"))
    parser.add_argument("--ema-cross-bars", type=int, default=4)
    parser.add_argument("--price-window-bars", type=int, default=4)
    parser.add_argument("--price-rise-percent", type=Decimal, default=Decimal("1.5"))
    parser.add_argument("--oi-window-bars", type=int, default=4)
    parser.add_argument("--oi-rise-percent", type=Decimal, default=Decimal("2"))
    parser.add_argument("--volume-multiple", type=Decimal, default=Decimal("2"))
    parser.add_argument("--amplitude-multiple", type=Decimal, default=Decimal("2"))
    parser.add_argument("--amplitude-consecutive-bars", type=int, default=2)
    parser.add_argument("--average-amplitude-max-percent", type=Decimal, default=Decimal("0.8"))
    parser.add_argument(
        "--require-factor",
        action="append",
        choices=ALL_FACTORS,
        dest="required_factors",
        help="Repeat to select factors; defaults to the early-breakout preset.",
    )
    return parser


async def _run(args: argparse.Namespace) -> int:
    required = tuple(args.required_factors) if args.required_factors else ALL_FACTORS
    parameters = StrategyParameters(
        interval_seconds=args.interval_seconds,
        lookback_days=args.days,
        average_days=args.average_days,
        bullish_sequence_bars=args.bullish_sequence_bars,
        bullish_min_close_position_percent=(args.bullish_min_close_position_percent),
        bullish_last_close_position_percent=(args.bullish_last_close_position_percent),
        bullish_last_max_upper_shadow_percent=(args.bullish_last_max_upper_shadow_percent),
        single_bar_price_rise_percent=args.single_bar_price_rise_percent,
        volume_acceleration_average_bars=args.volume_acceleration_average_bars,
        volume_acceleration_average_multiple=(args.volume_acceleration_average_multiple),
        volume_acceleration_previous_multiple=(args.volume_acceleration_previous_multiple),
        ema_near_cross_gap_percent=args.ema_near_cross_gap_percent,
        ema_gap_shrink_min_percent=args.ema_gap_shrink_min_percent,
        ema_cross_lookback_bars=args.ema_cross_bars,
        rapid_price_window_bars=args.price_window_bars,
        rapid_price_rise_percent=args.price_rise_percent,
        open_interest_window_bars=args.oi_window_bars,
        open_interest_rise_percent=args.oi_rise_percent,
        volume_surge_multiple=args.volume_multiple,
        amplitude_spike_multiple=args.amplitude_multiple,
        amplitude_consecutive_bars=args.amplitude_consecutive_bars,
        average_amplitude_max_percent=args.average_amplitude_max_percent,
        required_factors=cast(tuple[FactorName, ...], required),
    )
    engine = create_database_engine(get_settings())
    try:
        signals = await scan_database(engine, parameters, symbols=args.symbols, end=args.end)
    finally:
        await engine.dispose()
    if args.output:
        with args.output.open("w", encoding="utf-8", newline="") as output:
            write_signals(signals, output, args.format)
    else:
        write_signals(signals, sys.stdout, args.format)
    print(
        json.dumps(
            {
                "signal_count": len(signals),
                "parameters": asdict(parameters),
            },
            ensure_ascii=False,
            default=str,
        ),
        file=sys.stderr,
    )
    return 0


def main() -> None:
    args = build_parser().parse_args()
    raise SystemExit(asyncio.run(_run(args)))


if __name__ == "__main__":
    main()
