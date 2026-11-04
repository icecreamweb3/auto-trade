from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum
from uuid import UUID

from auto_trade.training.contracts import EntrySource, TrainingContractError

REQUIRED_M6_DECISIONS = frozenset({"Q-019", "Q-029", "Q-030", "Q-036", "Q-039"})


class CrossFitExecutionError(TrainingContractError):
    """The M6 execution would cross a governed state or data boundary."""


class CoverageGateStatus(StrEnum):
    BACKFILL_PENDING = "BACKFILL_PENDING"
    ACCEPTED = "ACCEPTED"
    REJECTED = "REJECTED"


class CrossFitExecutionState(StrEnum):
    PLANNED = "PLANNED"
    RUNNING = "RUNNING"
    CANDIDATE_READY = "CANDIDATE_READY"
    GO_NO_GO_PASSED = "GO_NO_GO_PASSED"
    FORMAL_CORPUS_READY = "FORMAL_CORPUS_READY"
    INSUFFICIENT_POWER = "INSUFFICIENT_POWER"
    FAILED = "FAILED"


class FoldExecutionState(StrEnum):
    PLANNED = "PLANNED"
    SEARCHING = "SEARCHING"
    PREDICTING = "PREDICTING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    INSUFFICIENT_POWER = "INSUFFICIENT_POWER"


@dataclass(frozen=True, slots=True)
class FoldExecutionSpec:
    fold_number: int
    raw_training_sample_count: int
    effective_training_sample_count: int
    prediction_sample_count: int
    warmup_excluded_count: int
    purge_excluded_count: int
    embargo_excluded_count: int
    trial_budget: int
    wall_clock_budget_seconds: int
    repeat_count: int
    random_seed: int
    optimizer_run_id: UUID
    control_optimizer_run_id: UUID
    control_trial_budget: int
    control_random_seed: int
    inner_validation_count: int = 0
    from_scratch: bool = True

    def __post_init__(self) -> None:
        counts = (
            self.raw_training_sample_count,
            self.effective_training_sample_count,
            self.prediction_sample_count,
            self.warmup_excluded_count,
            self.purge_excluded_count,
            self.embargo_excluded_count,
        )
        if self.fold_number <= 0 or any(value < 0 for value in counts):
            raise CrossFitExecutionError("fold number and sample counts must be valid")
        if self.effective_training_sample_count > self.raw_training_sample_count:
            raise CrossFitExecutionError("effective training cannot exceed raw training")
        if self.trial_budget <= 0 or self.wall_clock_budget_seconds <= 0:
            raise CrossFitExecutionError("fold search budgets must be positive")
        if self.control_trial_budget != self.trial_budget:
            raise CrossFitExecutionError("TPE and RANDOM fold budgets must match")
        if self.control_optimizer_run_id == self.optimizer_run_id:
            raise CrossFitExecutionError("TPE and RANDOM fold runs must be distinct")
        if self.repeat_count <= 0:
            raise CrossFitExecutionError("repeat_count must be positive")
        if self.inner_validation_count != 0:
            raise CrossFitExecutionError("Cross-fit folds cannot consume VALIDATION")
        if not self.from_scratch:
            raise CrossFitExecutionError("each Cross-fit fold must search from scratch")


@dataclass(slots=True)
class CrossFitExecution:
    execution_id: UUID
    coverage_status: CoverageGateStatus
    question_statuses: dict[str, str]
    state: CrossFitExecutionState = CrossFitExecutionState.PLANNED
    folds: list[FoldExecutionSpec] = field(default_factory=list)
    candidate_optimizer_run_ids: set[UUID] = field(default_factory=set)
    terminal_reason: str | None = None

    def _require_all_questions_ready(self) -> None:
        missing = sorted(
            question
            for question in REQUIRED_M6_DECISIONS
            if self.question_statuses.get(question) != "READY"
        )
        if missing:
            raise CrossFitExecutionError("M6 decisions are not READY: " + ", ".join(missing))

    def start(self) -> None:
        if self.state is not CrossFitExecutionState.PLANNED:
            raise CrossFitExecutionError("only a PLANNED execution can start")
        self._require_all_questions_ready()
        if self.coverage_status is not CoverageGateStatus.ACCEPTED:
            raise CrossFitExecutionError(
                "accepted dependency coverage is required before corpus generation"
            )
        self.state = CrossFitExecutionState.RUNNING

    def add_fold(self, fold: FoldExecutionSpec) -> None:
        if self.state is not CrossFitExecutionState.RUNNING:
            raise CrossFitExecutionError("folds may only start while execution is RUNNING")
        expected = len(self.folds) + 1
        if fold.fold_number != expected:
            raise CrossFitExecutionError(f"expected outer fold {expected}")
        if fold.optimizer_run_id in self.candidate_optimizer_run_ids:
            raise CrossFitExecutionError("fold optimizer runs cannot be reused")
        if fold.control_optimizer_run_id in self.candidate_optimizer_run_ids:
            raise CrossFitExecutionError("fold optimizer runs cannot be reused")
        self.folds.append(fold)
        self.candidate_optimizer_run_ids.add(fold.optimizer_run_id)
        self.candidate_optimizer_run_ids.add(fold.control_optimizer_run_id)

    def assess_power(
        self,
        *,
        effective_fold_count: int,
        effective_day_count: int,
        event_count: int,
        minimum_folds: int,
        minimum_days: int,
        minimum_events: int,
    ) -> CrossFitExecutionState:
        if self.state is not CrossFitExecutionState.RUNNING:
            raise CrossFitExecutionError("power may only be assessed after fold execution")
        if len(self.folds) == 0:
            raise CrossFitExecutionError("power cannot be assessed without executed folds")
        values = (
            effective_fold_count,
            effective_day_count,
            event_count,
            minimum_folds,
            minimum_days,
            minimum_events,
        )
        if any(value < 0 for value in values) or any(value == 0 for value in values[3:]):
            raise CrossFitExecutionError("power counts and thresholds must be valid")
        if (
            effective_fold_count < minimum_folds
            or effective_day_count < minimum_days
            or event_count < minimum_events
        ):
            self.state = CrossFitExecutionState.INSUFFICIENT_POWER
            self.terminal_reason = "INSUFFICIENT_POWER"
        else:
            self.state = CrossFitExecutionState.CANDIDATE_READY
        return self.state

    def record_go_no_go(self, decision: str) -> CrossFitExecutionState:
        if self.state is not CrossFitExecutionState.CANDIDATE_READY:
            raise CrossFitExecutionError("go/no-go requires qualified candidate corpus")
        if decision == "PASS":
            self.state = CrossFitExecutionState.GO_NO_GO_PASSED
        elif decision == "INSUFFICIENT_POWER":
            self.state = CrossFitExecutionState.INSUFFICIENT_POWER
            self.terminal_reason = decision
        elif decision == "FAIL":
            self.state = CrossFitExecutionState.FAILED
            self.terminal_reason = "GO_NO_GO_FAILED"
        else:
            raise CrossFitExecutionError("unsupported go/no-go decision")
        return self.state

    def promote_formal_corpus(self) -> EntrySource:
        if self.state is not CrossFitExecutionState.GO_NO_GO_PASSED:
            raise CrossFitExecutionError("formal corpus requires a passing Q-036 gate")
        self.state = CrossFitExecutionState.FORMAL_CORPUS_READY
        return EntrySource.CROSS_FIT_MODEL_A


def candidate_entry_source() -> EntrySource:
    """The only source emitted before Q-036 passes."""
    return EntrySource.CROSS_FIT_MODEL_A_CANDIDATE
