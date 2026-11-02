from __future__ import annotations

from collections.abc import Mapping

from auto_trade.training.contracts import EntrySource, EntryUse, assert_entry_source_allowed
from auto_trade.training.optimizer import CandidateValidation, ParameterRule, validate_candidate

__all__ = [
    "CandidateValidation",
    "ParameterRule",
    "assert_entry_source_allowed",
    "assert_model_b_training_source",
    "validate_candidate",
]


def assert_model_b_training_source(source: EntrySource) -> None:
    assert_entry_source_allowed(source=source, usage=EntryUse.MODEL_B_TRAIN)


def validate_model_b_candidate(
    candidate: Mapping[str, object], search_space: Mapping[str, ParameterRule]
) -> CandidateValidation:
    return validate_candidate(candidate, search_space)
