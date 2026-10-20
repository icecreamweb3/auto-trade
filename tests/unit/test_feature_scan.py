from datetime import UTC, datetime, timedelta
from decimal import Decimal

from auto_trade.strategies.feature_scan import (
    ALL_FACTORS,
    FeatureBar,
    StrategyParameters,
    evaluate_series,
)


def _bar(
    index: int,
    *,
    close: Decimal = Decimal("100"),
    ema20: Decimal = Decimal("99"),
    ema240: Decimal = Decimal("100"),
    volume: Decimal = Decimal("100"),
    amplitude: Decimal = Decimal("1"),
    oi: Decimal | None = Decimal("1000"),
) -> FeatureBar:
    return FeatureBar(
        open_time=datetime(2026, 1, 1, tzinfo=UTC) + timedelta(minutes=15 * index),
        close_price=close,
        ema20=ema20,
        ema240=ema240,
        quote_volume=volume,
        amplitude_percent=amplitude,
        open_interest_value=oi,
    )


def test_all_six_factors_produce_one_signal() -> None:
    parameters = StrategyParameters(average_days=1)
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
        close=Decimal("104"),
        ema20=Decimal("102"),
        ema240=Decimal("100"),
        volume=Decimal("600"),
        amplitude=Decimal("6"),
        oi=Decimal("1060"),
    )

    signals = evaluate_series("BRUSDT", bars, parameters, bars[100].open_time)

    assert len(signals) == 1
    assert all(signals[0].factors[name].passed for name in ALL_FACTORS)
    assert signals[0].factors["ema_bullish_cross"].value == 1
    assert signals[0].factors["rapid_price_rise"].value == Decimal("4")
    assert signals[0].factors["open_interest_rise"].value == Decimal("6.00")
    assert signals[0].factors["volume_surge"].value > Decimal("5")


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
    bars = [_bar(0, close=Decimal("100")), _bar(1, close=Decimal("104"))]

    signals = evaluate_series("BRUSDT", bars, parameters, bars[1].open_time)

    assert len(signals) == 1
    assert signals[0].factors["rapid_price_rise"].passed
    assert not signals[0].factors["volume_surge"].passed


def test_average_window_uses_selected_kline_interval() -> None:
    assert StrategyParameters(interval_seconds=300, average_days=7).average_bars == 2016
    assert StrategyParameters(interval_seconds=900, average_days=7).average_bars == 672
