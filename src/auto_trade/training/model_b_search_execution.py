"""Fail-closed planning and execution for a fresh formal Model-B TRAIN search."""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from typing import Any
from uuid import UUID

from auto_trade.training.contracts import EntrySource
from auto_trade.training.evaluator import (
    GateDecision,
    GoNoGoResult,
    ModelBSearchResult,
    run_model_b_search,
)
from auto_trade.training.model_b_candidate_policy import (
    CompiledModelBCandidate,
    compile_model_b_candidate_policy,
    validate_model_b_policy_candidate,
)
from auto_trade.training.optimizer import CandidateValidation, ParameterRule, TrialSink

REQUIRED_DECISIONS = frozenset({"Q-019", "Q-029", "Q-030", "Q-036", "Q-039"})
_FORBIDDEN_SAFE_INPUT_FIELDS = frozenset(
    {"source", "future", "label", "labels", "outcome", "outcomes"}
)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ModelBFormalSearchError(RuntimeError):
    """Formal Model-B search prerequisites are not satisfied."""


class SafeInputKind(StrEnum):
    NATURAL_ENTRY = "NATURAL_ENTRY"
    ADVERSE_OR_RANGE_CONTROL = "ADVERSE_OR_RANGE_CONTROL"


@dataclass(frozen=True, slots=True)
class OptimizerRunSpec:
    run_id: UUID
    kind: str
    trial_budget: int
    search_space_version_id: UUID
    proposals: tuple[Mapping[str, object], ...]


@dataclass(frozen=True, slots=True)
class SafeModelBInput:
    """Optimizer-visible input. Raw source and post-entry truth are intentionally absent."""

    entry_event_id: str
    kind: SafeInputKind
    features: Mapping[str, object]

    def __post_init__(self) -> None:
        if not _SHA256_RE.fullmatch(self.entry_event_id):
            raise ModelBFormalSearchError("safe input requires a SHA-256 entry identity")
        _assert_safe_mapping(self.features)


@dataclass(frozen=True, slots=True)
class FormalSearchPrerequisites:
    gate: GoNoGoResult
    ready_decisions: frozenset[str]
    coverage_state: str
    backfill_accepted: bool
    coverage_report_hash: str
    tpe: OptimizerRunSpec
    random: OptimizerRunSpec
    temporary_optimizer_run_ids: frozenset[UUID] = frozenset()


@dataclass(frozen=True, slots=True)
class FormalSearchPlan:
    tpe: OptimizerRunSpec
    random: OptimizerRunSpec
    natural_entry_count: int
    control_entry_count: int
    coverage_report_hash: str


@dataclass(frozen=True, slots=True)
class FormalSearchExecution:
    plan: FormalSearchPlan
    tpe_result: ModelBSearchResult
    random_result: ModelBSearchResult


def _assert_safe_mapping(value: Mapping[str, object]) -> None:
    for raw_key, child in value.items():
        key = str(raw_key).strip().lower()
        tokens = {token for token in key.replace("-", "_").split("_") if token}
        if tokens & _FORBIDDEN_SAFE_INPUT_FIELDS:
            raise ModelBFormalSearchError(f"safe input exposes forbidden field: {raw_key}")
        if isinstance(child, Mapping):
            _assert_safe_mapping(child)
        elif isinstance(child, (list, tuple)):
            for item in child:
                if isinstance(item, Mapping):
                    _assert_safe_mapping(item)


def build_formal_search_plan(
    prerequisites: FormalSearchPrerequisites,
    inputs: Sequence[SafeModelBInput],
) -> FormalSearchPlan:
    """Validate governed prerequisites without reading VALIDATION or future outcomes."""
    if prerequisites.gate.decision is not GateDecision.PASS:
        raise ModelBFormalSearchError("formal search requires Cross-fit PASS")
    missing = REQUIRED_DECISIONS - prerequisites.ready_decisions
    if missing:
        raise ModelBFormalSearchError(
            f"formal search decisions are not READY: {','.join(sorted(missing))}"
        )
    if prerequisites.ready_decisions != REQUIRED_DECISIONS:
        raise ModelBFormalSearchError("formal search received unknown decision bindings")
    if prerequisites.coverage_state != "PASS" or not prerequisites.backfill_accepted:
        raise ModelBFormalSearchError("coverage and backfill qualification must PASS")
    if not _SHA256_RE.fullmatch(prerequisites.coverage_report_hash):
        raise ModelBFormalSearchError("coverage report hash must be SHA-256")

    tpe, random = prerequisites.tpe, prerequisites.random
    if tpe.kind != "TPE" or random.kind != "RANDOM":
        raise ModelBFormalSearchError("formal search requires TPE and RANDOM runs")
    if tpe.run_id == random.run_id or {tpe.run_id, random.run_id} & set(
        prerequisites.temporary_optimizer_run_ids
    ):
        raise ModelBFormalSearchError("formal search must use fresh optimizer runs")
    if tpe.trial_budget <= 0 or tpe.trial_budget != random.trial_budget:
        raise ModelBFormalSearchError("TPE and RANDOM require the same positive budget")
    if tpe.search_space_version_id != random.search_space_version_id:
        raise ModelBFormalSearchError("TPE and RANDOM require one frozen search space")
    if len(tpe.proposals) != tpe.trial_budget or len(random.proposals) != random.trial_budget:
        raise ModelBFormalSearchError("proposal count must equal each frozen trial budget")

    natural = sum(item.kind is SafeInputKind.NATURAL_ENTRY for item in inputs)
    controls = sum(item.kind is SafeInputKind.ADVERSE_OR_RANGE_CONTROL for item in inputs)
    if natural == 0:
        raise ModelBFormalSearchError("formal search requires natural-frequency Cross-fit inputs")
    return FormalSearchPlan(tpe, random, natural, controls, prerequisites.coverage_report_hash)


def execute_formal_search(
    *,
    plan: FormalSearchPlan,
    gate: GoNoGoResult,
    search_space: Mapping[str, ParameterRule],
    search_space_config: Mapping[str, object],
    exit_rule_version_id: UUID,
    evaluate_tpe_train: Callable[[CompiledModelBCandidate], float],
    evaluate_random_train: Callable[[CompiledModelBCandidate], float],
    tpe_sink: TrialSink,
    random_sink: TrialSink,
) -> FormalSearchExecution:
    """Execute both fresh, same-budget TRAIN-only searches.

    The evaluator callbacks are deliberately TRAIN-only. Neither gate metrics nor
    outcome/label payloads are passed to candidate evaluation.
    """
    if gate.decision is not GateDecision.PASS:
        raise ModelBFormalSearchError("formal execution requires Cross-fit PASS")

    def validator(
        candidate: Mapping[str, object], rules: Mapping[str, ParameterRule]
    ) -> CandidateValidation:
        return validate_model_b_policy_candidate(candidate, rules, search_space_config)

    def compile_and_evaluate(
        evaluate: Callable[[CompiledModelBCandidate], float],
    ) -> Callable[[Mapping[str, object]], float]:
        def compiled(candidate: Mapping[str, object]) -> float:
            return evaluate(
                compile_model_b_candidate_policy(
                    exit_rule_version_id=exit_rule_version_id,
                    search_space_config=search_space_config,
                    candidate=candidate,
                )
            )

        return compiled

    tpe_result = run_model_b_search(
        candidates=plan.tpe.proposals,
        search_space=search_space,
        evaluate_train=compile_and_evaluate(evaluate_tpe_train),
        sink=tpe_sink,
        source=EntrySource.CROSS_FIT_MODEL_A,
        gate=gate,
        temporary_only=False,
        candidate_validator=validator,
    )
    raw_random_result = run_model_b_search(
        candidates=plan.random.proposals,
        search_space=search_space,
        evaluate_train=compile_and_evaluate(evaluate_random_train),
        sink=random_sink,
        source=EntrySource.CROSS_FIT_MODEL_A,
        gate=gate,
        temporary_only=False,
        candidate_validator=validator,
    )
    # RANDOM is a governed same-budget comparator, never a registration candidate.
    random_result = ModelBSearchResult(
        raw_random_result.outcomes,
        raw_random_result.best_trial_number,
        raw_random_result.best_train_objective,
        False,
        raw_random_result.temporary_only,
    )
    return FormalSearchExecution(plan, tpe_result, random_result)


def assert_model_b_search_source(*, source: EntrySource, temporary_only: bool) -> None:
    """Keep go/no-go candidate material and fresh formal TRAIN material disjoint."""
    expected = (
        EntrySource.CROSS_FIT_MODEL_A_CANDIDATE
        if temporary_only
        else EntrySource.CROSS_FIT_MODEL_A
    )
    if source is not expected:
        phase = "temporary go/no-go" if temporary_only else "formal"
        raise ModelBFormalSearchError(f"{phase} Model-B search received the wrong source")


def safe_input_payload(item: SafeModelBInput) -> dict[str, Any]:
    """Serialize the optimizer-safe contract without source/category or future truth."""
    return {
        "entry_event_id": item.entry_event_id,
        "features": dict(item.features),
    }
