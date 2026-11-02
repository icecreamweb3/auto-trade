from __future__ import annotations

import math
import random
from collections import defaultdict
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import date
from enum import StrEnum

from auto_trade.training.contracts import EntrySource
from auto_trade.training.optimizer import (
    GovernedOptimizerAdapter,
    ParameterRule,
    TrialOutcome,
    TrialSink,
)


class GateDecision(StrEnum):
    PASS = "PASS"
    FAIL = "FAIL"
    INSUFFICIENT_POWER = "INSUFFICIENT_POWER"


@dataclass(frozen=True, slots=True)
class FoldMetric:
    fold_number: int
    prediction_day: date
    symbol: str
    tpe_value: float
    random_value: float


@dataclass(frozen=True, slots=True)
class GoNoGoResult:
    decision: GateDecision
    tpe_mean: float
    random_mean: float
    excess_mean: float
    p_value: float
    effective_days: int
    effective_folds: int
    bootstrap_replicates: int
    seed: int


@dataclass(frozen=True, slots=True)
class ModelBSearchResult:
    outcomes: tuple[TrialOutcome, ...]
    best_trial_number: int | None
    best_train_objective: float | None
    promotable: bool
    temporary_only: bool


def run_model_b_search(
    *,
    candidates: Iterable[Mapping[str, object]],
    search_space: Mapping[str, ParameterRule],
    evaluate_train: Callable[[Mapping[str, object]], float],
    sink: TrialSink,
    source: EntrySource,
    gate: GoNoGoResult,
    temporary_only: bool,
) -> ModelBSearchResult:
    """Run nested gate training or formal Model-B TRAIN search.

    Temporary nested results are statistics only and can never be promoted. A
    formal search is allowed only after the outer gate has passed and consumes
    natural-frequency ``CROSS_FIT_MODEL_A`` events.
    """
    if source is not EntrySource.CROSS_FIT_MODEL_A:
        raise ValueError("formal Model-B search accepts only CROSS_FIT_MODEL_A events")
    if not temporary_only and gate.decision is not GateDecision.PASS:
        raise ValueError("formal Model-B search requires a passing Cross-fit gate")
    adapter = GovernedOptimizerAdapter(sink)
    outcomes: list[TrialOutcome] = []
    for trial_number, candidate in enumerate(candidates):
        outcomes.append(
            adapter.run_trial(
                trial_number=trial_number,
                candidate=candidate,
                search_space=search_space,
                evaluate_train=evaluate_train,
            )
        )
    completed = [outcome for outcome in outcomes if outcome.train_objective is not None]
    best = max(
        completed,
        key=lambda outcome: outcome.train_objective or float("-inf"),
        default=None,
    )
    return ModelBSearchResult(
        tuple(outcomes),
        best.trial_number if best else None,
        best.train_objective if best else None,
        bool(best) and not temporary_only and gate.decision is GateDecision.PASS,
        temporary_only,
    )


def _mean(values: Iterable[float]) -> float:
    values = tuple(values)
    return sum(values) / len(values) if values else 0.0


def evaluate_cross_fit_gate(
    metrics: Iterable[FoldMetric],
    *,
    alpha: float,
    minimum_effective_days: int,
    minimum_effective_folds: int,
    bootstrap_replicates: int = 2000,
    seed: int = 0,
) -> GoNoGoResult:
    """Compare TPE and random on outer-fold predictions only.

    Resampling is clustered by UTC day and symbol so overlapping signals do not
    inflate the independent sample count.
    """
    rows = tuple(metrics)
    if not rows or not 0 < alpha < 1 or bootstrap_replicates <= 0:
        raise ValueError("invalid go/no-go inputs")
    clusters: dict[tuple[date, str], list[float]] = defaultdict(list)
    for row in rows:
        if not math.isfinite(row.tpe_value) or not math.isfinite(row.random_value):
            raise ValueError("gate metrics must be finite")
        clusters[(row.prediction_day, row.symbol)].append(row.tpe_value - row.random_value)
    differences = tuple(_mean(values) for values in clusters.values())
    excess = _mean(differences)
    tpe_mean = _mean(row.tpe_value for row in rows)
    random_mean = _mean(row.random_value for row in rows)
    folds = len({row.fold_number for row in rows})
    days = len({row.prediction_day for row in rows})
    if days < minimum_effective_days or folds < minimum_effective_folds:
        decision = GateDecision.INSUFFICIENT_POWER
        p_value = 1.0
    else:
        rng = random.Random(seed)
        at_least_zero = 0
        for _ in range(bootstrap_replicates):
            sample = [differences[rng.randrange(len(differences))] for _ in differences]
            if _mean(sample) <= 0:
                at_least_zero += 1
        p_value = (at_least_zero + 1) / (bootstrap_replicates + 1)
        decision = GateDecision.PASS if excess > 0 and p_value < alpha else GateDecision.FAIL
    return GoNoGoResult(
        decision, tpe_mean, random_mean, excess, p_value, days, folds,
        bootstrap_replicates, seed,
    )
