from datetime import UTC, datetime, timedelta
from decimal import Decimal

from auto_trade.strategies.feature_scan import (
    EARLY_BREAKOUT_FACTORS,
    FeatureBar,
    StrategyParameters,
    evaluate_series,
)

LEGACY_FACTORS = (
    "ema_bullish_cross",
    "rapid_price_rise",
    "open_interest_rise",
    "volume_surge",
    "amplitude_spike_streak",
    "low_average_amplitude",
)


def _bar(
    index: int,
    *,
    open_price: Decimal | None = None,
    high: Decimal | None = None,
    low: Decimal | None = None,
    close: Decimal = Decimal("100"),
    ema20: Decimal = Decimal("99"),
    ema240: Decimal = Decimal("100"),
    volume: Decimal = Decimal("100"),
    amplitude: Decimal = Decimal("1"),
    oi: Decimal | None = Decimal("1000"),
) -> FeatureBar:
    candle_open = open_price if open_price is not None else close
    return FeatureBar(
        open_time=datetime(2026, 1, 1, tzinfo=UTC) + timedelta(minutes=15 * index),
        open_price=candle_open,
        high_price=high if high is not None else max(candle_open, close),
        low_price=low if low is not None else min(candle_open, close),
        close_price=close,
        price_precision=2,
        ema20=ema20,
        ema240=ema240,
        base_volume=volume,
        quote_volume=volume,
        amplitude_percent=amplitude,
        open_interest_value=oi,
    )


def test_legacy_factor_subset_is_scored_and_can_produce_signal() -> None:
    parameters = StrategyParameters(
        average_days=1,
        required_factors=LEGACY_FACTORS,
        signal_score_threshold=Decimal("1"),
        rearm_score_threshold=Decimal("0"),
    )
    bars = [_bar(index) for index in range(101)]
    bars[96] = _bar(96, close=Decimal("100"), oi=Decimal("1000"))
    bars[99] = _bar(
        99,
        close=Decimal("102"),
        ema20=Decimal("101"),
        ema240=Decimal("100"),
        volume=Decimal("600"),
        amplitude=Decimal("6"),
        oi=Decimal("1040"),
    )
    bars[100] = _bar(
        100,
        open_price=Decimal("102"),
        close=Decimal("104"),
        ema20=Decimal("102"),
        ema240=Decimal("100"),
        volume=Decimal("600"),
        amplitude=Decimal("6"),
        oi=Decimal("1060"),
    )

    signals = evaluate_series("BRUSDT", bars, parameters, bars[100].open_time)

    assert len(signals) == 1
    assert all(signals[0].factors[name].weight > 0 for name in LEGACY_FACTORS)
    assert signals[0].factors["ema_bullish_cross"].value == 1
    assert signals[0].factors["rapid_price_rise"].value == Decimal("4")
    assert signals[0].factors["rapid_price_rise"].threshold == ">= 1.50% over 4 bars"
    assert signals[0].factors["open_interest_rise"].value == Decimal("6.00")
    assert signals[0].factors["open_interest_rise"].threshold == ">= 2.00% over 4 bars"
    assert signals[0].factors["volume_surge"].value > Decimal("2")
    assert signals[0].factors["low_average_amplitude"].threshold == "< 0.80% over prior 1d"


def test_early_breakout_factors_hit_second_strong_bullish_bar() -> None:
    parameters = StrategyParameters(
        average_days=1,
        required_factors=EARLY_BREAKOUT_FACTORS,
    )
    bars = [_bar(index) for index in range(98)]
    bars[96] = _bar(
        96,
        open_price=Decimal("100"),
        high=Decimal("103"),
        low=Decimal("99"),
        close=Decimal("102.5"),
        ema20=Decimal("99"),
        ema240=Decimal("100"),
        volume=Decimal("180"),
        amplitude=Decimal("4"),
    )
    bars[97] = _bar(
        97,
        open_price=Decimal("102.5"),
        high=Decimal("106"),
        low=Decimal("102"),
        close=Decimal("105.8"),
        ema20=Decimal("99.6"),
        ema240=Decimal("100"),
        volume=Decimal("400"),
        amplitude=Decimal("3.9"),
    )

    signals = evaluate_series("BRUSDT", bars, parameters, bars[96].open_time)

    assert [signal.open_time for signal in signals] == [bars[97].open_time]
    factors = signals[0].factors
    assert factors["bullish_candle_sequence"].value == Decimal("95.00")
    assert factors["single_bar_price_rise"].value == Decimal("3.22")
    assert factors["volume_acceleration"].value > Decimal("3.8")
    assert factors["ema_bullish_setup"].value == Decimal("0.40")
    assert signals[0].score == Decimal("86.66")
    assert signals[0].grade == "S"
    assert signals[0].coverage_percent == Decimal("100.00")
    assert signals[0].trigger_reason == "单根涨幅+窗口涨幅+量价加速"
    assert signals[0].group_scores["price_action"] > Decimal("90")
    assert signals[0].group_scores["volume"] == Decimal("100.00")
    assert signals[0].risk_flags == ()
    assert factors["bullish_candle_sequence"].score == Decimal("89.17")
    assert factors["volume_acceleration"].metrics["previous_ratio"] > Decimal("2")
    assert factors["low_average_amplitude"].score > 0


def test_ema_bullish_setup_rejects_stale_cross() -> None:
    parameters = StrategyParameters(
        ema_cross_lookback_bars=4,
        required_factors=("ema_bullish_setup",),
    )
    bars = [_bar(0, ema20=Decimal("99"), ema240=Decimal("100"))]
    bars.extend(_bar(index, ema20=Decimal("101"), ema240=Decimal("100")) for index in range(1, 8))

    signals = evaluate_series("BRUSDT", bars, parameters, bars[-1].open_time)

    assert signals == ()


def test_missing_oi_does_not_become_zero_or_pass() -> None:
    parameters = StrategyParameters(average_days=1, required_factors=("open_interest_rise",))
    bars = [_bar(index) for index in range(101)]
    bars[100] = _bar(100, oi=None)

    signals = evaluate_series("BRUSDT", bars, parameters, bars[100].open_time)

    assert signals == ()


def test_gap_invalidates_trailing_average_factors() -> None:
    parameters = StrategyParameters(average_days=1, required_factors=("low_average_amplitude",))
    bars = [_bar(index) for index in range(101)]
    bars.pop(50)

    signals = evaluate_series("BRUSDT", bars, parameters, bars[-1].open_time)

    assert signals == ()


def test_required_factor_subset_can_be_used_for_factor_inspection() -> None:
    parameters = StrategyParameters(
        average_days=1,
        rapid_price_window_bars=1,
        required_factors=("rapid_price_rise",),
    )
    bars = [
        _bar(0, close=Decimal("100")),
        _bar(1, open_price=Decimal("100"), close=Decimal("104")),
    ]

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert len(signals) == 1
    assert signals[0].factors["rapid_price_rise"].passed
    assert not signals[0].factors["volume_surge"].passed


def test_percentage_comparison_uses_two_decimal_places() -> None:
    parameters = StrategyParameters(
        rapid_price_window_bars=1,
        rapid_price_rise_percent=Decimal("3.004"),
        signal_score_threshold=Decimal("50"),
        rearm_score_threshold=Decimal("40"),
        required_factors=("rapid_price_rise",),
    )
    bars = [
        _bar(0, close=Decimal("100")),
        _bar(1, open_price=Decimal("100"), close=Decimal("102.999")),
    ]

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert len(signals) == 1
    result = signals[0].factors["rapid_price_rise"]
    assert result.value == Decimal("3.00")
    assert result.threshold == ">= 3.00% over 1 bars"


def test_average_window_uses_selected_kline_interval() -> None:
    assert StrategyParameters(interval_seconds=300, average_days=7).average_bars == 2016
    assert StrategyParameters(interval_seconds=900, average_days=7).average_bars == 672


def test_registered_factor_parameters_override_legacy_internal_fields() -> None:
    parameters = StrategyParameters(
        required_factors=("rapid_price_rise",),
        signal_score_threshold=Decimal("50"),
        rearm_score_threshold=Decimal("40"),
        factor_parameters={
            "rapid_price_rise": {
                "rapid_price_window_bars": 1,
                "rapid_price_rise_percent": Decimal("1"),
                "rapid_price_rise_saturation_percent": Decimal("4"),
            }
        },
    )
    bars = [
        _bar(0, close=Decimal("100")),
        _bar(1, open_price=Decimal("100"), close=Decimal("103")),
    ]

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert parameters.rapid_price_window_bars == 1
    assert parameters.rapid_price_rise_percent == Decimal("1")
    assert len(signals) == 1
    assert signals[0].factors["rapid_price_rise"].score > Decimal("60")


def test_evaluation_callback_receives_every_scanned_bar() -> None:
    parameters = StrategyParameters(
        interval_seconds=300,
        required_factors=("rapid_price_rise",),
    )
    bars = [_bar(0), _bar(1), _bar(2)]
    evaluations = []

    evaluate_series(
        "BRUSDT",
        bars,
        parameters,
        bars[1].open_time,
        evaluations.append,
    )

    assert [evaluation.bar_number for evaluation in evaluations] == [1, 2]
    assert all(evaluation.symbol == "BRUSDT" for evaluation in evaluations)


def test_candidate_trigger_and_cooldown_emit_one_signal_in_same_wave() -> None:
    parameters = StrategyParameters(
        rapid_price_window_bars=1,
        required_factors=("rapid_price_rise",),
        signal_score_threshold=Decimal("50"),
        rearm_score_threshold=Decimal("40"),
        cooldown_bars=2,
        score_improvement_for_repeat=Decimal("20"),
    )
    bars = [_bar(0, close=Decimal("100"))]
    for index in range(1, 5):
        bars.append(
            _bar(
                index,
                open_price=Decimal(98 + index * 2),
                close=Decimal(100 + index * 2),
            )
        )

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert [signal.open_time for signal in signals] == [bars[1].open_time]


def test_missing_selected_factor_reduces_coverage_without_renormalizing() -> None:
    parameters = StrategyParameters(
        rapid_price_window_bars=1,
        required_factors=("rapid_price_rise", "open_interest_rise"),
        signal_score_threshold=Decimal("30"),
        rearm_score_threshold=Decimal("20"),
        minimum_data_coverage_percent=Decimal("40"),
    )
    bars = [
        _bar(0, close=Decimal("100"), oi=None),
        _bar(1, open_price=Decimal("100"), close=Decimal("104"), oi=None),
    ]

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert len(signals) == 1
    assert signals[0].coverage_percent == Decimal("50.00")
    assert signals[0].score == Decimal("50.00")
    assert not signals[0].factors["open_interest_rise"].available


def test_factor_contribution_uses_normalized_selected_weight() -> None:
    parameters = StrategyParameters(
        rapid_price_window_bars=1,
        required_factors=("rapid_price_rise",),
        factor_weights={"rapid_price_rise": Decimal("2")},
        signal_score_threshold=Decimal("50"),
        rearm_score_threshold=Decimal("40"),
    )
    bars = [
        _bar(0, close=Decimal("100")),
        _bar(1, open_price=Decimal("100"), close=Decimal("105")),
    ]

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert len(signals) == 1
    result = signals[0].factors["rapid_price_rise"]
    assert result.weight == Decimal("2")
    assert result.contribution == signals[0].score == Decimal("100.00")
