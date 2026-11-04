from datetime import date
from uuid import uuid4

import pytest

from auto_trade.training.contracts import EntrySource
from auto_trade.training.evaluator import FoldMetric, evaluate_cross_fit_gate
from auto_trade.training.model_b_search_execution import (
    FormalSearchPrerequisites,
    ModelBFormalSearchError,
    OptimizerRunSpec,
    SafeInputKind,
    SafeModelBInput,
    assert_model_b_search_source,
    build_formal_search_plan,
    execute_formal_search,
    safe_input_payload,
)
from auto_trade.training.optimizer import NumericParameter


class _Sink:
    def __init__(self) -> None:
        self.calls = []

    def tell(self, trial_number, objective, state) -> None:
        self.calls.append((trial_number, objective, state))


def _passing_gate():
    return evaluate_cross_fit_gate(
        [FoldMetric(fold, date(2026, 8, fold), "BTCUSDT", 2.0, 1.0) for fold in (1, 2, 3)],
        alpha=0.05,
        minimum_effective_days=3,
        minimum_effective_folds=3,
        bootstrap_replicates=20,
        seed=7,
    )


def _prerequisites(**changes):
    search_space_id = uuid4()
    values = {
        "gate": _passing_gate(),
        "ready_decisions": frozenset({"Q-019", "Q-029", "Q-030", "Q-036", "Q-039"}),
        "coverage_state": "PASS",
        "backfill_accepted": True,
        "coverage_report_hash": "a" * 64,
        "tpe": OptimizerRunSpec(uuid4(), "TPE", 1, search_space_id, ({"stop": 0.02},)),
        "random": OptimizerRunSpec(uuid4(), "RANDOM", 1, search_space_id, ({"stop": 0.03},)),
    }
    values.update(changes)
    return FormalSearchPrerequisites(**values)


def _input(**features):
    return SafeModelBInput("b" * 64, SafeInputKind.NATURAL_ENTRY, features or {"atr": 1.2})


def test_formal_plan_requires_ready_decisions_coverage_and_fresh_equal_budget_runs() -> None:
    with pytest.raises(ModelBFormalSearchError, match="Q-039"):
        build_formal_search_plan(
            _prerequisites(ready_decisions=frozenset({"Q-019", "Q-029", "Q-030", "Q-036"})),
            [_input()],
        )
    with pytest.raises(ModelBFormalSearchError, match="coverage"):
        build_formal_search_plan(_prerequisites(backfill_accepted=False), [_input()])
    temporary_id = uuid4()
    base = _prerequisites()
    reused = OptimizerRunSpec(
        temporary_id, "TPE", base.tpe.trial_budget,
        base.tpe.search_space_version_id, base.tpe.proposals,
    )
    with pytest.raises(ModelBFormalSearchError, match="fresh"):
        build_formal_search_plan(
            _prerequisites(tpe=reused, random=base.random,
                           temporary_optimizer_run_ids=frozenset({temporary_id})),
            [_input()],
        )


def test_safe_inputs_reject_source_future_labels_and_outcomes() -> None:
    for field in ("source", "future_price", "label", "trade_outcome"):
        with pytest.raises(ModelBFormalSearchError, match="forbidden"):
            _input(**{field: 1})
    with pytest.raises(ModelBFormalSearchError, match="SHA-256"):
        SafeModelBInput("Z" * 64, SafeInputKind.NATURAL_ENTRY, {"atr": 1})
    payload = safe_input_payload(_input())
    assert "source" not in payload
    assert "input_kind" not in payload


def test_temporary_and_formal_sources_are_strictly_disjoint() -> None:
    assert_model_b_search_source(
        source=EntrySource.CROSS_FIT_MODEL_A_CANDIDATE, temporary_only=True
    )
    assert_model_b_search_source(source=EntrySource.CROSS_FIT_MODEL_A, temporary_only=False)
    with pytest.raises(ModelBFormalSearchError, match="wrong source"):
        assert_model_b_search_source(source=EntrySource.CROSS_FIT_MODEL_A, temporary_only=True)
    with pytest.raises(ModelBFormalSearchError, match="wrong source"):
        assert_model_b_search_source(
            source=EntrySource.CROSS_FIT_MODEL_A_CANDIDATE, temporary_only=False
        )


def test_formal_execution_is_train_only_and_random_comparator_is_not_promotable() -> None:
    gate = _passing_gate()
    plan = build_formal_search_plan(_prerequisites(gate=gate), [_input()])
    seen = []

    def evaluate(candidate):
        seen.append(dict(candidate))
        return candidate["stop"]

    result = execute_formal_search(
        plan=plan,
        gate=gate,
        search_space={"stop": NumericParameter(0.01, 0.05)},
        evaluate_tpe_train=evaluate,
        evaluate_random_train=evaluate,
        tpe_sink=_Sink(),
        random_sink=_Sink(),
    )
    assert seen == [{"stop": 0.02}, {"stop": 0.03}]
    assert result.tpe_result.promotable
    assert not result.random_result.promotable
