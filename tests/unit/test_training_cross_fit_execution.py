from uuid import uuid4

import pytest

from auto_trade.training.contracts import EntrySource
from auto_trade.training.cross_fit_execution import (
    CoverageGateStatus,
    CrossFitExecution,
    CrossFitExecutionError,
    CrossFitExecutionState,
    FoldExecutionSpec,
    candidate_entry_source,
)


def _ready_questions() -> dict[str, str]:
    return {question: "READY" for question in ("Q-019", "Q-029", "Q-030", "Q-036", "Q-039")}


def _execution(*, coverage: CoverageGateStatus = CoverageGateStatus.ACCEPTED) -> CrossFitExecution:
    return CrossFitExecution(uuid4(), coverage, _ready_questions())


def _fold(number: int, optimizer_run_id=None) -> FoldExecutionSpec:
    return FoldExecutionSpec(
        fold_number=number,
        raw_training_sample_count=1_000,
        effective_training_sample_count=800,
        prediction_sample_count=100,
        warmup_excluded_count=100,
        purge_excluded_count=50,
        embargo_excluded_count=50,
        trial_budget=40,
        wall_clock_budget_seconds=900,
        repeat_count=2,
        random_seed=100 + number,
        optimizer_run_id=optimizer_run_id or uuid4(),
        control_optimizer_run_id=uuid4(),
        control_trial_budget=40,
        control_random_seed=200 + number,
    )


def test_backfill_and_each_required_q_fail_closed_before_start() -> None:
    pending = _execution(coverage=CoverageGateStatus.BACKFILL_PENDING)
    with pytest.raises(CrossFitExecutionError, match="accepted dependency coverage"):
        pending.start()

    missing = _execution()
    missing.question_statuses["Q-036"] = "DRAFT"
    with pytest.raises(CrossFitExecutionError, match="Q-036"):
        missing.start()


def test_fold_searches_are_sequential_from_scratch_and_never_use_validation() -> None:
    execution = _execution()
    execution.start()
    reused_run = uuid4()
    execution.add_fold(_fold(1, reused_run))
    with pytest.raises(CrossFitExecutionError, match="expected outer fold 2"):
        execution.add_fold(_fold(3))
    with pytest.raises(CrossFitExecutionError, match="cannot be reused"):
        execution.add_fold(_fold(2, reused_run))
    with pytest.raises(CrossFitExecutionError, match="cannot consume VALIDATION"):
        FoldExecutionSpec(
            **{
                field: getattr(_fold(2), field)
                for field in FoldExecutionSpec.__dataclass_fields__
                if field != "inner_validation_count"
            },
            inner_validation_count=1,
        )
    with pytest.raises(CrossFitExecutionError, match="budgets must match"):
        FoldExecutionSpec(
            **{
                field: getattr(_fold(2), field)
                for field in FoldExecutionSpec.__dataclass_fields__
                if field != "control_trial_budget"
            },
            control_trial_budget=39,
        )


def test_insufficient_power_is_terminal_and_cannot_promote() -> None:
    execution = _execution()
    execution.start()
    execution.add_fold(_fold(1))
    state = execution.assess_power(
        effective_fold_count=1,
        effective_day_count=10,
        event_count=500,
        minimum_folds=3,
        minimum_days=30,
        minimum_events=1_000,
    )
    assert state is CrossFitExecutionState.INSUFFICIENT_POWER
    assert execution.terminal_reason == "INSUFFICIENT_POWER"
    with pytest.raises(CrossFitExecutionError, match="passing Q-036"):
        execution.promote_formal_corpus()


def test_candidate_source_cannot_become_formal_until_q036_passes() -> None:
    execution = _execution()
    execution.start()
    execution.add_fold(_fold(1))
    assert candidate_entry_source() is EntrySource.CROSS_FIT_MODEL_A_CANDIDATE
    assert (
        execution.assess_power(
            effective_fold_count=1,
            effective_day_count=30,
            event_count=1_000,
            minimum_folds=1,
            minimum_days=30,
            minimum_events=1_000,
        )
        is CrossFitExecutionState.CANDIDATE_READY
    )
    with pytest.raises(CrossFitExecutionError, match="passing Q-036"):
        execution.promote_formal_corpus()
    assert execution.record_go_no_go("PASS") is CrossFitExecutionState.GO_NO_GO_PASSED
    assert execution.promote_formal_corpus() is EntrySource.CROSS_FIT_MODEL_A
    assert execution.state is CrossFitExecutionState.FORMAL_CORPUS_READY
