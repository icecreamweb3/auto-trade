from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest

from auto_trade.strategies.feature_scan import FeatureBar
from auto_trade.training.model_a_candidate_scan_repository import BenchmarkBar
from auto_trade.training.model_a_pipeline import ModelAPipelineError
from auto_trade.training.random_baseline_strata import (
    compute_stratum,
    parse_strata_config,
)


def _config() -> dict[str, object]:
    return {
        "random_seed": 42,
        "maximum_frame_candidates": 100,
        "stratification": {
            "benchmark_symbol": "BTCUSDT",
            "volatility_measure": "CLOSE_RETURN_STDDEV_PERCENT",
            "volatility_window_bars": 2,
            "volatility_boundaries_percent": [1, 2],
            "liquidity_measure": "MEAN_QUOTE_VOLUME",
            "liquidity_window_bars": 2,
            "liquidity_boundaries_quote_volume": [100, 1000],
            "btc_regime_measure": "CLOSE_RETURN_PERCENT",
            "btc_regime_window_bars": 2,
            "btc_return_boundaries_percent": [-1, 1],
        },
    }


def _bar(at: datetime, close: str, volume: str = "200") -> FeatureBar:
    price = Decimal(close)
    return FeatureBar(
        open_time=at,
        open_price=price,
        high_price=price,
        low_price=price,
        close_price=price,
        price_precision=2,
        ema20=price,
        ema240=price,
        base_volume=Decimal("1"),
        quote_volume=Decimal(volume),
        amplitude_percent=Decimal("0"),
        open_interest_value=None,
    )


def test_strata_are_computed_only_from_contiguous_pre_observation_bars() -> None:
    start = datetime(2026, 8, 1, tzinfo=UTC)
    observed = start + timedelta(minutes=15)
    config = parse_strata_config(uuid4(), _config())
    bars = tuple(
        _bar(start + timedelta(minutes=5 * index), str(100 + index))
        for index in range(4)
    )
    benchmark = tuple(
        BenchmarkBar(start + timedelta(minutes=5 * index), Decimal(100 + index))
        for index in range(4)
    )

    result = compute_stratum(
        observed_at=observed,
        instrument_bars=bars,
        benchmark_bars=benchmark,
        interval_seconds=300,
        config=config,
    )

    assert result.volatility_bucket.startswith("VOL-")
    assert result.liquidity_bucket == "LIQ-1"
    assert result.btc_regime == "BTC-2"
    assert result.volatility_window_start_at < observed
    assert result.evidence["observed_at"] == observed.isoformat()


def test_strata_config_and_gapped_history_fail_closed() -> None:
    invalid = _config()
    invalid["maximum_frame_candidates"] = 0
    with pytest.raises(ModelAPipelineError, match="maximum_frame_candidates"):
        parse_strata_config(uuid4(), invalid)

    start = datetime(2026, 8, 1, tzinfo=UTC)
    observed = start + timedelta(minutes=20)
    bars = (_bar(start, "100"), _bar(start + timedelta(minutes=10), "101"))
    benchmark = (
        BenchmarkBar(start, Decimal("100")),
        BenchmarkBar(start + timedelta(minutes=5), Decimal("101")),
        BenchmarkBar(start + timedelta(minutes=10), Decimal("102")),
        BenchmarkBar(start + timedelta(minutes=15), Decimal("103")),
    )
    with pytest.raises(ModelAPipelineError, match="history"):
        compute_stratum(
            observed_at=observed,
            instrument_bars=bars,
            benchmark_bars=benchmark,
            interval_seconds=300,
            config=parse_strata_config(uuid4(), _config()),
        )
