"""Time-safe, configuration-driven random-baseline strata."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from itertools import pairwise
from typing import cast
from uuid import UUID

from auto_trade.strategies.feature_scan import FeatureBar
from auto_trade.training.model_a_candidate_scan_repository import BenchmarkBar
from auto_trade.training.model_a_pipeline import ModelAPipelineError


@dataclass(frozen=True, slots=True)
class StrataConfig:
    config_version_id: UUID
    benchmark_symbol: str
    volatility_window_bars: int
    liquidity_window_bars: int
    btc_regime_window_bars: int
    volatility_boundaries: tuple[Decimal, ...]
    liquidity_boundaries: tuple[Decimal, ...]
    btc_return_boundaries: tuple[Decimal, ...]
    maximum_frame_candidates: int


@dataclass(frozen=True, slots=True)
class ComputedStratum:
    volatility_bucket: str
    liquidity_bucket: str
    btc_regime: str
    volatility_window_start_at: datetime
    liquidity_window_start_at: datetime
    btc_regime_window_start_at: datetime
    evidence: Mapping[str, object]

    def evidence_json(self) -> str:
        return json.dumps(
            self.evidence,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
        )


def _positive_integer(value: object, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ModelAPipelineError(f"RANDOM_BASELINE {name} must be a positive integer")
    return value


def _boundaries(value: object, name: str) -> tuple[Decimal, ...]:
    if not isinstance(value, list) or not value:
        raise ModelAPipelineError(f"RANDOM_BASELINE {name} must be a non-empty array")
    try:
        result = tuple(Decimal(str(item)) for item in cast(list[object], value))
    except Exception as error:
        raise ModelAPipelineError(f"RANDOM_BASELINE {name} must be numeric") from error
    if any(not item.is_finite() for item in result) or tuple(sorted(set(result))) != result:
        raise ModelAPipelineError(
            f"RANDOM_BASELINE {name} must be finite, unique and ascending"
        )
    return result


def parse_strata_config(config_version_id: UUID, config: Mapping[str, object]) -> StrataConfig:
    raw = config.get("stratification")
    if not isinstance(raw, Mapping):
        raise ModelAPipelineError("RANDOM_BASELINE stratification is required")
    values = cast(Mapping[str, object], raw)
    expected = {
        "benchmark_symbol",
        "volatility_measure",
        "volatility_window_bars",
        "volatility_boundaries_percent",
        "liquidity_measure",
        "liquidity_window_bars",
        "liquidity_boundaries_quote_volume",
        "btc_regime_measure",
        "btc_regime_window_bars",
        "btc_return_boundaries_percent",
    }
    if set(values) != expected:
        raise ModelAPipelineError("RANDOM_BASELINE stratification fields are not exact")
    if values["volatility_measure"] != "CLOSE_RETURN_STDDEV_PERCENT":
        raise ModelAPipelineError("unsupported RANDOM_BASELINE volatility_measure")
    if values["liquidity_measure"] != "MEAN_QUOTE_VOLUME":
        raise ModelAPipelineError("unsupported RANDOM_BASELINE liquidity_measure")
    if values["btc_regime_measure"] != "CLOSE_RETURN_PERCENT":
        raise ModelAPipelineError("unsupported RANDOM_BASELINE btc_regime_measure")
    symbol = values["benchmark_symbol"]
    if not isinstance(symbol, str) or not symbol.strip() or symbol != symbol.upper():
        raise ModelAPipelineError("RANDOM_BASELINE benchmark_symbol must be uppercase")
    return StrataConfig(
        config_version_id,
        symbol,
        _positive_integer(values["volatility_window_bars"], "volatility_window_bars"),
        _positive_integer(values["liquidity_window_bars"], "liquidity_window_bars"),
        _positive_integer(values["btc_regime_window_bars"], "btc_regime_window_bars"),
        _boundaries(values["volatility_boundaries_percent"], "volatility boundaries"),
        _boundaries(
            values["liquidity_boundaries_quote_volume"], "liquidity boundaries"
        ),
        _boundaries(values["btc_return_boundaries_percent"], "BTC boundaries"),
        _positive_integer(
            config.get("maximum_frame_candidates"), "maximum_frame_candidates"
        ),
    )


def _bucket(prefix: str, value: Decimal, boundaries: tuple[Decimal, ...]) -> str:
    for index, boundary in enumerate(boundaries):
        if value < boundary:
            return f"{prefix}-{index}"
    return f"{prefix}-{len(boundaries)}"


def _contiguous_before[BarT: (FeatureBar, BenchmarkBar)](
    bars: Sequence[BarT],
    observed_at: datetime,
    count: int,
    interval_seconds: int,
) -> tuple[BarT, ...]:
    prior = tuple(bar for bar in bars if bar.open_time < observed_at)
    selected = prior[-count:]
    if len(selected) != count:
        raise ModelAPipelineError("random-baseline stratum lacks pre-observation history")
    expected_step = interval_seconds
    if any(
        int((right.open_time - left.open_time).total_seconds()) != expected_step
        for left, right in pairwise(selected)
    ) or int((observed_at - selected[-1].open_time).total_seconds()) != expected_step:
        raise ModelAPipelineError("random-baseline stratum history is not contiguous")
    return selected


def compute_stratum(
    *,
    observed_at: datetime,
    instrument_bars: tuple[FeatureBar, ...],
    benchmark_bars: tuple[BenchmarkBar, ...],
    interval_seconds: int,
    config: StrataConfig,
) -> ComputedStratum:
    volatility_bars = cast(
        tuple[FeatureBar, ...],
        _contiguous_before(
            instrument_bars,
            observed_at,
            config.volatility_window_bars + 1,
            interval_seconds,
        ),
    )
    returns = tuple(
        (right.close_price / left.close_price - 1) * 100
        for left, right in pairwise(volatility_bars)
    )
    mean_return = sum(returns, Decimal(0)) / Decimal(len(returns))
    variance = sum(
        ((value - mean_return) ** 2 for value in returns), Decimal(0)
    ) / Decimal(len(returns))
    volatility = variance.sqrt()
    liquidity_bars = cast(
        tuple[FeatureBar, ...],
        _contiguous_before(
            instrument_bars,
            observed_at,
            config.liquidity_window_bars,
            interval_seconds,
        ),
    )
    liquidity = sum(
        (bar.quote_volume for bar in liquidity_bars), Decimal(0)
    ) / Decimal(len(liquidity_bars))
    benchmark_window = cast(
        tuple[BenchmarkBar, ...],
        _contiguous_before(
            benchmark_bars,
            observed_at,
            config.btc_regime_window_bars + 1,
            interval_seconds,
        ),
    )
    btc_return = (
        benchmark_window[-1].close_price / benchmark_window[0].close_price - 1
    ) * 100
    evidence: dict[str, object] = {
        "benchmark_symbol": config.benchmark_symbol,
        "btc_regime_measure": "CLOSE_RETURN_PERCENT",
        "btc_return_percent": str(btc_return),
        "config_version_id": str(config.config_version_id),
        "liquidity_measure": "MEAN_QUOTE_VOLUME",
        "mean_quote_volume": str(liquidity),
        "observed_at": observed_at.isoformat(),
        "volatility_measure": "CLOSE_RETURN_STDDEV_PERCENT",
        "volatility_percent": str(volatility),
    }
    evidence["evidence_fingerprint"] = hashlib.sha256(
        json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return ComputedStratum(
        _bucket("VOL", volatility, config.volatility_boundaries),
        _bucket("LIQ", liquidity, config.liquidity_boundaries),
        _bucket("BTC", btc_return, config.btc_return_boundaries),
        volatility_bars[0].open_time,
        liquidity_bars[0].open_time,
        benchmark_window[0].open_time,
        evidence,
    )
