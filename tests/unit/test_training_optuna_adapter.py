from __future__ import annotations

from decimal import Decimal

import pytest

from auto_trade.training.optuna_adapter import (
    OptunaAdapterError,
    PriorTrial,
    ask_optuna_candidate,
    trial_sampler_seed,
)
from auto_trade.training.search_space import parse_versioned_search_space


def search_space():
    return parse_versioned_search_space(
        "1.0.0",
        {
            "parameters": {
                "lookback": {
                    "kind": "numeric",
                    "minimum": 2,
                    "maximum": 10,
                    "integer": True,
                },
                "mode": {"kind": "categorical", "choices": ["FAST", "SLOW"]},
                "threshold": [0.1, 0.9],
            }
        },
    )


def test_trial_sampler_seed_is_stable_and_trial_specific() -> None:
    assert trial_sampler_seed(42, 3) == trial_sampler_seed(42, 3)
    assert trial_sampler_seed(42, 3) != trial_sampler_seed(42, 4)


def test_ask_rejects_a_gap_before_loading_optuna() -> None:
    with pytest.raises(OptunaAdapterError, match="gap-free"):
        ask_optuna_candidate(
            optimizer_kind="TPE",
            run_random_seed=42,
            trial_number=2,
            search_space=search_space(),
            prior_trials=(
                PriorTrial(
                    0, {"lookback": 3, "mode": "FAST", "threshold": 0.2}, "COMPLETE", Decimal("1")
                ),
            ),
        )


def test_integer_parameter_rejects_fractional_bounds() -> None:
    pytest.importorskip("optuna")
    invalid = parse_versioned_search_space(
        "1.0.0",
        {
            "parameters": {
                "lookback": {
                    "kind": "numeric",
                    "minimum": 1.5,
                    "maximum": 10,
                    "integer": True,
                }
            }
        },
    )
    with pytest.raises(OptunaAdapterError, match="must be integral"):
        ask_optuna_candidate(
            optimizer_kind="TPE",
            run_random_seed=42,
            trial_number=0,
            search_space=invalid,
            prior_trials=(),
        )


def test_real_optuna_ask_is_replay_deterministic() -> None:
    pytest.importorskip("optuna")
    kwargs = {
        "optimizer_kind": "TPE",
        "run_random_seed": 42,
        "trial_number": 1,
        "search_space": search_space(),
        "prior_trials": (
            PriorTrial(
                0,
                {"lookback": 3, "mode": "FAST", "threshold": 0.2},
                "COMPLETE",
                Decimal("1.25"),
            ),
        ),
    }

    first = ask_optuna_candidate(**kwargs)
    second = ask_optuna_candidate(**kwargs)

    assert first == second
    assert first.validation.rejection_codes == ()
