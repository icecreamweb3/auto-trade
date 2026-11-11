from datetime import date

import pytest

from auto_trade.training.evaluator import (
    FoldMetric,
    GateDecision,
    ModelBGateMetric,
    evaluate_cross_fit_gate,
    evaluate_q036_gate,
)


def test_gate_uses_outer_fold_clustered_results_and_passes() -> None:
    rows = tuple(
        FoldMetric(fold, date(2026, 1, day), "BTCUSDT", 2.0, 1.0)
        for fold in (1, 2, 3)
        for day in (1, 2, 3, 4)
    )
    result = evaluate_cross_fit_gate(
        rows, alpha=0.05, minimum_effective_days=3,
        minimum_effective_folds=3, bootstrap_replicates=200, seed=7,
    )
    assert result.decision is GateDecision.PASS
    assert result.effective_days == 4
    assert result.effective_folds == 3
    assert result.ci_lower_bound == 1.0
    assert result.ci_upper_bound == 1.0
    assert result.bootstrap_method == "BCA_UTC_DAY_CLUSTER"


def test_gate_stops_for_insufficient_power_before_interpreting_result() -> None:
    result = evaluate_cross_fit_gate(
        [FoldMetric(1, date(2026, 1, 1), "BTCUSDT", 100.0, 1.0)],
        alpha=0.05, minimum_effective_days=2, minimum_effective_folds=2,
        bootstrap_replicates=50, seed=1,
    )
    assert result.decision is GateDecision.INSUFFICIENT_POWER
    assert result.p_value == 1.0


def test_gate_weights_utc_days_equally_instead_of_symbol_rows() -> None:
    crowded_day = [
        FoldMetric(1, date(2026, 1, 1), f"S{index}", 1.0, 0.0)
        for index in range(100)
    ]
    result = evaluate_cross_fit_gate(
        [*crowded_day, FoldMetric(1, date(2026, 1, 2), "BTCUSDT", 0.0, 0.5)],
        alpha=0.05,
        minimum_effective_days=2,
        minimum_effective_folds=1,
        bootstrap_replicates=200,
        seed=7,
    )

    assert result.excess_mean == 0.25
    assert result.effective_days == 2


def test_bca_day_cluster_result_is_reproducible() -> None:
    rows = [
        FoldMetric(1, date(2026, 1, day), "BTCUSDT", float(day), 0.0)
        for day in range(1, 7)
    ]
    first = evaluate_cross_fit_gate(
        rows,
        alpha=0.05,
        minimum_effective_days=3,
        minimum_effective_folds=1,
        bootstrap_replicates=500,
        seed=42,
    )
    second = evaluate_cross_fit_gate(
        rows,
        alpha=0.05,
        minimum_effective_days=3,
        minimum_effective_folds=1,
        bootstrap_replicates=500,
        seed=42,
    )

    assert first == second
    assert first.ci_lower_bound > 0


def _q036_model_a_rows() -> tuple[FoldMetric, ...]:
    return tuple(
        FoldMetric(fold, date(2026, 1, day), "BTCUSDT", 1.5, 1.0)
        for fold, day in enumerate(range(1, 5), start=1)
    )


def _q036_model_b_rows(*, stressed_value: float = 0.2) -> tuple[ModelBGateMetric, ...]:
    return tuple(
        ModelBGateMetric(date(2026, 1, day), "BTCUSDT", 0.3, stressed_value)
        for day in range(1, 5)
    )


def test_q036_requires_both_model_a_and_stressed_model_b_to_pass() -> None:
    result = evaluate_q036_gate(
        _q036_model_a_rows(),
        _q036_model_b_rows(),
        alpha=0.05,
        minimum_effective_days=4,
        minimum_effective_folds=4,
        model_a_point_threshold=0.25,
        model_a_ci_lower_threshold=0.10,
        model_b_point_threshold=0.15,
        bootstrap_replicates=200,
        seed=7,
    )

    assert result.decision is GateDecision.PASS
    assert result.model_a.excess_mean == 0.5
    assert result.model_b_net_expectancy == 0.3
    assert result.model_b_stressed_ci_lower_bound == 0.2

    stressed_failure = evaluate_q036_gate(
        _q036_model_a_rows(),
        _q036_model_b_rows(stressed_value=0.0),
        alpha=0.05,
        minimum_effective_days=4,
        minimum_effective_folds=4,
        model_a_point_threshold=0.25,
        model_a_ci_lower_threshold=0.10,
        model_b_point_threshold=0.15,
        bootstrap_replicates=200,
        seed=7,
    )
    assert stressed_failure.decision is GateDecision.FAIL


def test_q036_does_not_interpret_results_when_power_is_insufficient() -> None:
    result = evaluate_q036_gate(
        _q036_model_a_rows(),
        _q036_model_b_rows(),
        alpha=0.05,
        minimum_effective_days=5,
        minimum_effective_folds=5,
        model_a_point_threshold=0.25,
        model_a_ci_lower_threshold=0.10,
        model_b_point_threshold=0.15,
        bootstrap_replicates=200,
        seed=7,
    )

    assert result.decision is GateDecision.INSUFFICIENT_POWER


def test_q036_rejects_model_b_results_on_a_different_reference_day_set() -> None:
    rows = (*_q036_model_b_rows()[:-1], ModelBGateMetric(date(2026, 1, 5), "BTCUSDT", 0.3, 0.2))
    with pytest.raises(ValueError, match="reference UTC-day set"):
        evaluate_q036_gate(
            _q036_model_a_rows(),
            rows,
            alpha=0.05,
            minimum_effective_days=4,
            minimum_effective_folds=4,
            model_a_point_threshold=0.25,
            model_a_ci_lower_threshold=0.10,
            model_b_point_threshold=0.15,
            bootstrap_replicates=200,
            seed=7,
        )
