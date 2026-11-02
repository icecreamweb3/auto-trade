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


def test_gate_stops_for_insufficient_power_before_interpreting_result() -> None:
    result = evaluate_cross_fit_gate(
        [FoldMetric(1, date(2026, 1, 1), "BTCUSDT", 100.0, 1.0)],
        alpha=0.05, minimum_effective_days=2, minimum_effective_folds=2,
        bootstrap_replicates=50, seed=1,
    )
    assert result.decision is GateDecision.INSUFFICIENT_POWER
    assert result.p_value == 1.0
