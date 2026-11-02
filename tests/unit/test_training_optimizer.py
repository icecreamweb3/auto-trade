from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from auto_trade.training.optimizer import (
    CategoricalParameter,
    GovernedOptimizerAdapter,
    NumericParameter,
    TrialState,
    validate_candidate,
)
from auto_trade.training.search_space import parse_versioned_search_space


@dataclass
class _Sink:
    calls: list[tuple[int, float | None, TrialState]] = field(default_factory=list)

    def tell(self, trial_number: int, objective: float | None, state: TrialState) -> None:
        self.calls.append((trial_number, objective, state))


def _space() -> dict[str, NumericParameter | CategoricalParameter]:
    return {
        "threshold": NumericParameter(0.0, 1.0),
        "lookback": NumericParameter(1, 20, integer=True),
        "direction": CategoricalParameter(("LONG", "SHORT")),
    }


def test_candidate_validator_rejects_result_fields_and_invalid_values() -> None:
    result = validate_candidate(
        {
            "threshold": 2.0,
            "lookback": 2.5,
            "direction": "LONG",
            "validation_score": 99,
        },
        _space(),
    )
    assert result.rejection_codes == (
        "FORBIDDEN_RESULT_FIELD",
        "UNKNOWN_PARAMETER",
        "PARAMETER_OUT_OF_RANGE",
        "PARAMETER_TYPE_INVALID",
    )


def test_candidate_validator_does_not_treat_latest_as_test_data() -> None:
    result = validate_candidate(
        {"latest_window": 5},
        {"latest_window": NumericParameter(1, 10, integer=True)},
    )
    assert result.rejection_codes == ()


def test_invalid_candidate_is_told_fail_without_evaluation() -> None:
    sink = _Sink()
    evaluated = False

    def evaluate(_: Mapping[str, object]) -> float:
        nonlocal evaluated
        evaluated = True
        return 1.0

    outcome = GovernedOptimizerAdapter(sink).run_trial(
        trial_number=3,
        candidate={"threshold": 9.0, "lookback": 5, "direction": "LONG"},
        search_space=_space(),
        evaluate_train=evaluate,
    )
    assert not evaluated
    assert outcome.state is TrialState.FAIL
    assert sink.calls == [(3, None, TrialState.FAIL)]


def test_valid_candidate_exposes_only_train_objective_to_tell() -> None:
    sink = _Sink()
    outcome = GovernedOptimizerAdapter(sink).run_trial(
        trial_number=4,
        candidate={"threshold": 0.7, "lookback": 5, "direction": "SHORT"},
        search_space=_space(),
        evaluate_train=lambda _: 12.5,
    )
    assert outcome.train_objective == 12.5
    assert sink.calls == [(4, 12.5, TrialState.COMPLETE)]


def test_train_evaluation_failure_is_told_fail() -> None:
    sink = _Sink()

    def fail(_: Mapping[str, object]) -> float:
        raise RuntimeError("worker failed")

    outcome = GovernedOptimizerAdapter(sink).run_trial(
        trial_number=5,
        candidate={"threshold": 0.7, "lookback": 5, "direction": "SHORT"},
        search_space=_space(),
        evaluate_train=fail,
    )
    assert outcome.rejection_codes == ("TRAIN_EVALUATION_FAILED",)
    assert sink.calls == [(5, None, TrialState.FAIL)]


def test_versioned_search_space_parser_supports_explicit_rules() -> None:
    space = parse_versioned_search_space(
        "1.0.0",
        {
            "parameters": {
                "direction": {"kind": "categorical", "choices": ["LONG", "SHORT"]},
                "lookback": {
                    "kind": "numeric",
                    "minimum": 1,
                    "maximum": 20,
                    "integer": True,
                },
                "threshold": [0, 1],
            }
        },
    )
    assert tuple(space.parameters) == ("direction", "lookback", "threshold")
    assert len(space.content_hash) == 64
