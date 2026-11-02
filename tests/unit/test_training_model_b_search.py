import pytest

from auto_trade.training.contracts import EntrySource
from auto_trade.training.evaluator import (
    FoldMetric,
    GateDecision,
    evaluate_cross_fit_gate,
    run_model_b_search,
)
from auto_trade.training.optimizer import NumericParameter


class _Sink:
    def __init__(self) -> None:
        self.calls: list[tuple[int, float | None, object]] = []

    def tell(self, trial_number: int, objective: float | None, state: object) -> None:
        self.calls.append((trial_number, objective, state))


def _gate() -> object:
    return evaluate_cross_fit_gate(
        [FoldMetric(fold, __import__("datetime").date(2026, 1, fold), "BTCUSDT", 2, 1)
         for fold in (1, 2, 3)],
        alpha=0.05, minimum_effective_days=3, minimum_effective_folds=3,
        bootstrap_replicates=20, seed=1,
    )


def test_nested_model_b_search_is_not_promotable() -> None:
    sink = _Sink()
    result = run_model_b_search(
        candidates=({"stop": 0.02},),
        search_space={"stop": NumericParameter(0.01, 0.05)},
        evaluate_train=lambda _: 1.0,
        sink=sink,
        source=EntrySource.CROSS_FIT_MODEL_A,
        gate=_gate(),
        temporary_only=True,
    )
    assert result.temporary_only and not result.promotable


def test_formal_model_b_search_requires_gate_pass() -> None:
    sink = _Sink()
    insufficient = evaluate_cross_fit_gate(
        [FoldMetric(1, __import__("datetime").date(2026, 1, 1), "BTCUSDT", 2, 1)],
        alpha=0.05, minimum_effective_days=3, minimum_effective_folds=2,
        bootstrap_replicates=20, seed=1,
    )
    assert insufficient.decision is GateDecision.INSUFFICIENT_POWER
    with pytest.raises(ValueError, match="passing"):
        run_model_b_search(
            candidates=({"stop": 0.02},),
            search_space={"stop": NumericParameter(0.01, 0.05)},
            evaluate_train=lambda _: 1.0,
            sink=sink,
            source=EntrySource.CROSS_FIT_MODEL_A,
            gate=insufficient,
            temporary_only=False,
        )
