from __future__ import annotations

import math
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from enum import StrEnum
from itertools import pairwise
from typing import Protocol


class CandidateStatus(StrEnum):
    VALID = "VALID"
    REJECTED = "REJECTED"


class TrialState(StrEnum):
    COMPLETE = "COMPLETE"
    FAIL = "FAIL"


@dataclass(frozen=True, slots=True)
class NumericParameter:
    minimum: float
    maximum: float
    integer: bool = False

    def __post_init__(self) -> None:
        if not math.isfinite(self.minimum) or not math.isfinite(self.maximum):
            raise ValueError("search-space bounds must be finite")
        if self.minimum > self.maximum:
            raise ValueError("search-space minimum cannot exceed maximum")


@dataclass(frozen=True, slots=True)
class CategoricalParameter:
    choices: tuple[str | int | bool, ...]

    def __post_init__(self) -> None:
        if not self.choices:
            raise ValueError("categorical choices cannot be empty")


ParameterRule = NumericParameter | CategoricalParameter


@dataclass(frozen=True, slots=True)
class CandidateValidation:
    status: CandidateStatus
    rejection_codes: tuple[str, ...]


_FORBIDDEN_TOKENS = frozenset(
    (
        "validation",
        "test",
        "future",
        "label",
        "outcome",
        "rank",
        "ranking",
    )
)


def _field_tokens(key: object) -> tuple[str, ...]:
    with_word_boundaries = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", str(key))
    return tuple(token for token in re.split(r"[^a-z0-9]+", with_word_boundaries.lower()) if token)


def _contains_forbidden_field(value: object) -> bool:
    if isinstance(value, Mapping):
        for key, child in value.items():
            tokens = _field_tokens(key)
            if any(token in _FORBIDDEN_TOKENS for token in tokens) or any(
                pair == ("early", "stop") for pair in pairwise(tokens)
            ):
                return True
            if _contains_forbidden_field(child):
                return True
    elif isinstance(value, (list, tuple)):
        return any(_contains_forbidden_field(item) for item in value)
    return False


def validate_candidate(
    candidate: Mapping[str, object],
    search_space: Mapping[str, ParameterRule],
) -> CandidateValidation:
    rejection_codes: list[str] = []
    if _contains_forbidden_field(candidate):
        rejection_codes.append("FORBIDDEN_RESULT_FIELD")
    missing = sorted(set(search_space) - set(candidate))
    unknown = sorted(set(candidate) - set(search_space))
    if missing:
        rejection_codes.append("MISSING_PARAMETER")
    if unknown:
        rejection_codes.append("UNKNOWN_PARAMETER")
    for name, rule in search_space.items():
        if name not in candidate:
            continue
        value = candidate[name]
        if isinstance(rule, NumericParameter):
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                rejection_codes.append("PARAMETER_TYPE_INVALID")
                continue
            numeric_value = float(value)
            if not math.isfinite(numeric_value):
                rejection_codes.append("PARAMETER_NON_FINITE")
            elif rule.integer and not numeric_value.is_integer():
                rejection_codes.append("PARAMETER_TYPE_INVALID")
            elif not rule.minimum <= numeric_value <= rule.maximum:
                rejection_codes.append("PARAMETER_OUT_OF_RANGE")
        elif value not in rule.choices:
            rejection_codes.append("PARAMETER_NOT_ALLOWED")
    unique_codes = tuple(dict.fromkeys(rejection_codes))
    return CandidateValidation(
        CandidateStatus.VALID if not unique_codes else CandidateStatus.REJECTED,
        unique_codes,
    )


class TrialSink(Protocol):
    def tell(self, trial_number: int, objective: float | None, state: TrialState) -> None: ...


@dataclass(frozen=True, slots=True)
class TrialOutcome:
    trial_number: int
    state: TrialState
    train_objective: float | None
    rejection_codes: tuple[str, ...]


class GovernedOptimizerAdapter:
    """Validates before evaluation and exposes only the TRAIN objective to tell()."""

    def __init__(self, sink: TrialSink) -> None:
        self._sink = sink

    def run_trial(
        self,
        *,
        trial_number: int,
        candidate: Mapping[str, object],
        search_space: Mapping[str, ParameterRule],
        evaluate_train: Callable[[Mapping[str, object]], float],
        candidate_validator: Callable[
            [Mapping[str, object], Mapping[str, ParameterRule]], CandidateValidation
        ] = validate_candidate,
    ) -> TrialOutcome:
        validation = candidate_validator(candidate, search_space)
        if validation.status is CandidateStatus.REJECTED:
            self._sink.tell(trial_number, None, TrialState.FAIL)
            return TrialOutcome(
                trial_number,
                TrialState.FAIL,
                None,
                validation.rejection_codes,
            )
        try:
            objective = float(evaluate_train(candidate))
        except Exception:
            self._sink.tell(trial_number, None, TrialState.FAIL)
            return TrialOutcome(
                trial_number,
                TrialState.FAIL,
                None,
                ("TRAIN_EVALUATION_FAILED",),
            )
        if not math.isfinite(objective):
            self._sink.tell(trial_number, None, TrialState.FAIL)
            return TrialOutcome(
                trial_number,
                TrialState.FAIL,
                None,
                ("TRAIN_OBJECTIVE_NON_FINITE",),
            )
        self._sink.tell(trial_number, objective, TrialState.COMPLETE)
        return TrialOutcome(trial_number, TrialState.COMPLETE, objective, ())
