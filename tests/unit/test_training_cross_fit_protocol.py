from copy import deepcopy
from decimal import Decimal

import pytest

from auto_trade.training.cross_fit_execution import CrossFitExecutionError
from auto_trade.training.cross_fit_protocol import parse_cross_fit_runtime_protocol


def _config() -> dict[str, object]:
    return {
        "protocol": "CROSS_FIT_PROTOCOL_V1",
        "question_readiness": {
            question: "READY"
            for question in ("Q-019", "Q-029", "Q-030", "Q-036", "Q-039")
        },
        "q030_cross_fit": {
            "random_seed": 42,
            "tpe_trials_per_fold": 20,
            "random_trials_per_fold": 20,
            "equal_tpe_random_budget": True,
            "maximum_wall_clock_seconds_per_optimizer_per_fold": 14_400,
            "repeat_count_per_fold": 1,
            "prediction_signal_window_days": 2,
            "label_settlement_embargo_hours": 24,
            "minimum_training_window_effective_days": 30,
            "minimum_fitting_samples_per_fold": 100_000,
        },
        "q036_go_no_go": {
            "readiness": "READY",
            "gate_combination": "INTERSECTION_UNION_BOTH_MUST_PASS",
            "minimum_eligible_outer_folds": 15,
            "minimum_effective_independent_utc_days": 30,
            "minimum_complete_event_count": 1_500,
            "minimum_complete_events_per_fold": 100,
            "bootstrap_replicates": 5_000,
            "alpha_per_gate": 0.05,
            "model_a": {
                "final_thresholds_locked": True,
                "minimum_point_estimate_percentage_points": 0.25,
                "minimum_ci_lower_bound_percentage_points": 0.10,
            },
            "model_b": {
                "minimum_point_estimate_percentage_points": 0.15,
                "required_stress_multiplier": 2.0,
            },
        },
    }


def test_ready_011_protocol_parses_runtime_limits_and_locked_gates() -> None:
    protocol = parse_cross_fit_runtime_protocol(_config())

    assert protocol.wall_clock_seconds_per_optimizer_per_fold == 14_400
    assert protocol.repeat_count_per_fold == 1
    assert protocol.tpe_trials_per_fold == protocol.random_trials_per_fold == 20
    assert protocol.model_a_point_threshold_pp == Decimal("0.25")
    assert protocol.model_a_ci_lower_threshold_pp == Decimal("0.1")
    assert protocol.model_b_required_stress_multiplier == Decimal("2.0")


@pytest.mark.parametrize(
    ("path", "message"),
    [
        (
            ("q030_cross_fit", "maximum_wall_clock_seconds_per_optimizer_per_fold"),
            "maximum_wall_clock",
        ),
        (("q030_cross_fit", "repeat_count_per_fold"), "repeat_count"),
    ],
)
def test_old_protocol_without_runtime_limits_fails_closed(path, message) -> None:
    config = deepcopy(_config())
    section = config[path[0]]
    assert isinstance(section, dict)
    section.pop(path[1])

    with pytest.raises(CrossFitExecutionError, match=message):
        parse_cross_fit_runtime_protocol(config)


def test_unlocked_threshold_or_unequal_budget_fails_closed() -> None:
    unlocked = deepcopy(_config())
    q036 = unlocked["q036_go_no_go"]
    assert isinstance(q036, dict)
    model_a = q036["model_a"]
    assert isinstance(model_a, dict)
    model_a["final_thresholds_locked"] = False
    with pytest.raises(CrossFitExecutionError, match="not locked"):
        parse_cross_fit_runtime_protocol(unlocked)

    unequal = deepcopy(_config())
    q030 = unequal["q030_cross_fit"]
    assert isinstance(q030, dict)
    q030["random_trials_per_fold"] = 19
    with pytest.raises(CrossFitExecutionError, match="budgets differ"):
        parse_cross_fit_runtime_protocol(unequal)
