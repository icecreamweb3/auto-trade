from datetime import date

from auto_trade.training.evaluator import FoldMetric, GateDecision, evaluate_cross_fit_gate


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
