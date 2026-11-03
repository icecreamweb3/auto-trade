from __future__ import annotations

import hashlib
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import cast

from auto_trade.training.optimizer import (
    CandidateValidation,
    CategoricalParameter,
    NumericParameter,
    validate_candidate,
)
from auto_trade.training.search_space import VersionedSearchSpace


class OptunaAdapterError(RuntimeError):
    """A frozen study cannot produce its next deterministic proposal."""


@dataclass(frozen=True, slots=True)
class PriorTrial:
    trial_number: int
    candidate_parameters: Mapping[str, object]
    trial_state: str
    train_objective: Decimal | None


@dataclass(frozen=True, slots=True)
class OptunaProposal:
    sampler_seed: int
    candidate_parameters: Mapping[str, object]
    validation: CandidateValidation


def trial_sampler_seed(run_random_seed: int, trial_number: int) -> int:
    if trial_number < 0:
        raise OptunaAdapterError("trial_number must be non-negative")
    digest = hashlib.sha256(f"{run_random_seed}:{trial_number}".encode()).digest()
    return int.from_bytes(digest[:4], "big", signed=False)


def ask_optuna_candidate(
    *,
    optimizer_kind: str,
    run_random_seed: int,
    trial_number: int,
    search_space: VersionedSearchSpace,
    prior_trials: tuple[PriorTrial, ...],
) -> OptunaProposal:
    if tuple(trial.trial_number for trial in prior_trials) != tuple(range(trial_number)):
        raise OptunaAdapterError("prior trials must be complete, sequential, and gap-free")
    try:
        import optuna  # type: ignore[import-not-found]
    except ImportError as error:
        raise OptunaAdapterError("optimizer runtime requires training-optimizer") from error

    seed = trial_sampler_seed(run_random_seed, trial_number)
    if optimizer_kind == "TPE":
        sampler = optuna.samplers.TPESampler(seed=seed)
    elif optimizer_kind == "RANDOM":
        sampler = optuna.samplers.RandomSampler(seed=seed)
    else:
        raise OptunaAdapterError("optimizer kind must be TPE or RANDOM")
    study = optuna.create_study(direction="maximize", sampler=sampler)
    distributions: dict[str, object] = {}
    for name, rule in search_space.parameters.items():
        if isinstance(rule, NumericParameter):
            if rule.integer:
                if not rule.minimum.is_integer() or not rule.maximum.is_integer():
                    raise OptunaAdapterError(
                        f"integer parameter bounds must be integral: {name}"
                    )
                distributions[name] = optuna.distributions.IntDistribution(
                    int(rule.minimum), int(rule.maximum)
                )
            else:
                distributions[name] = optuna.distributions.FloatDistribution(
                    rule.minimum, rule.maximum
                )
        elif isinstance(rule, CategoricalParameter):
            distributions[name] = optuna.distributions.CategoricalDistribution(
                rule.choices
            )
    for prior in prior_trials:
        state = (
            optuna.trial.TrialState.COMPLETE
            if prior.trial_state == "COMPLETE"
            else optuna.trial.TrialState.FAIL
        )
        value = (
            float(prior.train_objective)
            if state is optuna.trial.TrialState.COMPLETE
            and prior.train_objective is not None
            else None
        )
        study.add_trial(
            optuna.trial.create_trial(
                params=dict(prior.candidate_parameters),
                distributions=distributions,
                value=value,
                state=state,
            )
        )
    trial = study.ask(fixed_distributions=distributions)
    candidate = cast(Mapping[str, object], dict(trial.params))
    return OptunaProposal(
        seed,
        candidate,
        validate_candidate(candidate, search_space.parameters),
    )
