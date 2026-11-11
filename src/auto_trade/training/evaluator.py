from __future__ import annotations

import math
import random
from collections import defaultdict
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from datetime import date
from enum import StrEnum
from statistics import NormalDist

from auto_trade.training.contracts import EntrySource
from auto_trade.training.optimizer import (
    CandidateValidation,
    GovernedOptimizerAdapter,
    ParameterRule,
    TrialOutcome,
    TrialSink,
    validate_candidate,
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
    ci_lower_bound: float
    ci_upper_bound: float
    confidence_level: float
    bootstrap_method: str = "BCA_UTC_DAY_CLUSTER"


@dataclass(frozen=True, slots=True)
class ModelBGateMetric:
    prediction_day: date
    symbol: str
    net_expectancy: float
    stressed_net_expectancy: float


@dataclass(frozen=True, slots=True)
class Q036GateResult:
    decision: GateDecision
    model_a: GoNoGoResult
    model_b_net_expectancy: float
    model_b_stressed_ci_lower_bound: float
    model_b_stressed_ci_upper_bound: float
    effective_days: int
    effective_folds: int
    bootstrap_replicates: int
    seed: int
    confidence_level: float
    bootstrap_method: str = "BCA_UTC_DAY_CLUSTER"


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
    candidate_validator: Callable[
        [Mapping[str, object], Mapping[str, ParameterRule]], CandidateValidation
    ] | None = None,
) -> ModelBSearchResult:
    """Run nested gate training or formal Model-B TRAIN search.

    Temporary nested results are statistics only and can never be promoted. A
    formal search is allowed only after the outer gate has passed and consumes
    natural-frequency ``CROSS_FIT_MODEL_A`` events.
    """
    if temporary_only:
        if source is not EntrySource.CROSS_FIT_MODEL_A_CANDIDATE:
            raise ValueError(
                "temporary Model-B gate search accepts only "
                "CROSS_FIT_MODEL_A_CANDIDATE events"
            )
    elif source is not EntrySource.CROSS_FIT_MODEL_A:
        raise ValueError("formal Model-B search accepts only CROSS_FIT_MODEL_A events")
    elif gate.decision is not GateDecision.PASS:
        raise ValueError("formal Model-B search requires a passing Cross-fit gate")
    adapter = GovernedOptimizerAdapter(sink)
    validator = candidate_validator or validate_candidate
    outcomes: list[TrialOutcome] = []
    for trial_number, candidate in enumerate(candidates):
        outcomes.append(
            adapter.run_trial(
                trial_number=trial_number,
                candidate=candidate,
                search_space=search_space,
                evaluate_train=evaluate_train,
                candidate_validator=validator,
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


def _quantile(values: Iterable[float], probability: float) -> float:
    ordered = sorted(values)
    if not ordered or not 0 <= probability <= 1:
        raise ValueError("invalid quantile inputs")
    position = probability * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def _bca_interval(
    values: tuple[float, ...],
    bootstrap_means: tuple[float, ...],
    *,
    confidence_level: float,
) -> tuple[float, float]:
    """Return a bias-corrected and accelerated interval over UTC-day clusters."""

    observed = _mean(values)
    normal = NormalDist()
    less_count = sum(value < observed for value in bootstrap_means)
    # A half-observation continuity correction keeps inv_cdf finite for
    # deterministic or near-deterministic bootstrap distributions.
    bias_probability = (less_count + 0.5) / (len(bootstrap_means) + 1)
    bias_correction = normal.inv_cdf(bias_probability)
    jackknife = tuple(
        _mean(values[:index] + values[index + 1 :])
        for index in range(len(values))
    )
    jackknife_mean = _mean(jackknife)
    numerator = sum((jackknife_mean - value) ** 3 for value in jackknife)
    denominator_base = sum((jackknife_mean - value) ** 2 for value in jackknife)
    acceleration = (
        numerator / (6 * denominator_base**1.5)
        if denominator_base > 0
        else 0.0
    )

    alpha = 1 - confidence_level

    def adjusted_probability(probability: float) -> float:
        z_value = normal.inv_cdf(probability)
        denominator = 1 - acceleration * (bias_correction + z_value)
        if denominator == 0:
            return 0.0 if z_value < 0 else 1.0
        adjusted = normal.cdf(
            bias_correction
            + (bias_correction + z_value) / denominator
        )
        return min(max(adjusted, 0.0), 1.0)

    return (
        _quantile(bootstrap_means, adjusted_probability(alpha / 2)),
        _quantile(bootstrap_means, adjusted_probability(1 - alpha / 2)),
    )


def evaluate_cross_fit_gate(
    metrics: Iterable[FoldMetric],
    *,
    alpha: float,
    minimum_effective_days: int,
    minimum_effective_folds: int,
    bootstrap_replicates: int = 5000,
    seed: int = 0,
    confidence_level: float = 0.95,
) -> GoNoGoResult:
    """Compare TPE and random on outer-fold predictions only.

    The primary analysis gives each UTC day one cluster. Symbol-by-day is a
    sensitivity analysis only and must not determine this gate.
    """
    rows = tuple(metrics)
    if (
        not rows
        or not 0 < alpha < 1
        or bootstrap_replicates <= 0
        or not 0 < confidence_level < 1
    ):
        raise ValueError("invalid go/no-go inputs")
    clusters: dict[date, list[FoldMetric]] = defaultdict(list)
    for row in rows:
        if not math.isfinite(row.tpe_value) or not math.isfinite(row.random_value):
            raise ValueError("gate metrics must be finite")
        clusters[row.prediction_day].append(row)
    daily_rows = tuple(clusters[day] for day in sorted(clusters))
    differences = tuple(
        _mean(row.tpe_value - row.random_value for row in day_rows)
        for day_rows in daily_rows
    )
    excess = _mean(differences)
    tpe_mean = _mean(_mean(row.tpe_value for row in day_rows) for day_rows in daily_rows)
    random_mean = _mean(
        _mean(row.random_value for row in day_rows) for day_rows in daily_rows
    )
    folds = len({row.fold_number for row in rows})
    days = len(differences)
    rng = random.Random(seed)
    bootstrap_means = tuple(
        _mean(differences[rng.randrange(days)] for _ in range(days))
        for _ in range(bootstrap_replicates)
    )
    ci_lower, ci_upper = _bca_interval(
        differences,
        bootstrap_means,
        confidence_level=confidence_level,
    )
    if days < minimum_effective_days or folds < minimum_effective_folds:
        decision = GateDecision.INSUFFICIENT_POWER
        p_value = 1.0
    else:
        at_least_zero = sum(value <= 0 for value in bootstrap_means)
        p_value = (at_least_zero + 1) / (bootstrap_replicates + 1)
        decision = (
            GateDecision.PASS
            if excess > 0 and ci_lower > 0 and p_value <= alpha
            else GateDecision.FAIL
        )
    return GoNoGoResult(
        decision, tpe_mean, random_mean, excess, p_value, days, folds,
        bootstrap_replicates, seed, ci_lower, ci_upper, confidence_level,
    )


def evaluate_q036_gate(
    model_a_metrics: Iterable[FoldMetric],
    model_b_metrics: Iterable[ModelBGateMetric],
    *,
    alpha: float,
    minimum_effective_days: int,
    minimum_effective_folds: int,
    model_a_point_threshold: float,
    model_a_ci_lower_threshold: float,
    model_b_point_threshold: float,
    bootstrap_replicates: int = 5000,
    seed: int = 0,
    confidence_level: float = 0.95,
) -> Q036GateResult:
    """Evaluate the locked Q-036 intersection-union gate.

    Model A and Model B must use the same fixed UTC-day reference set. Model B
    point estimates and stressed intervals give every UTC day equal weight, so
    signal-dense days cannot dominate the gate.
    """
    model_a_rows = tuple(model_a_metrics)
    model_b_rows = tuple(model_b_metrics)
    if not model_b_rows:
        raise ValueError("Q-036 requires temporary Model-B replay evidence")
    if any(
        not math.isfinite(row.net_expectancy)
        or not math.isfinite(row.stressed_net_expectancy)
        for row in model_b_rows
    ):
        raise ValueError("Model-B gate metrics must be finite")
    if (
        model_a_point_threshold <= 0
        or model_a_ci_lower_threshold <= 0
        or model_b_point_threshold <= 0
    ):
        raise ValueError("Q-036 thresholds must be positive")

    model_a = evaluate_cross_fit_gate(
        model_a_rows,
        alpha=alpha,
        minimum_effective_days=minimum_effective_days,
        minimum_effective_folds=minimum_effective_folds,
        bootstrap_replicates=bootstrap_replicates,
        seed=seed,
        confidence_level=confidence_level,
    )
    model_a_days = {row.prediction_day for row in model_a_rows}
    model_b_days = {row.prediction_day for row in model_b_rows}
    if model_b_days != model_a_days:
        raise ValueError("Model-B evidence must use the fixed Model-A reference UTC-day set")

    daily_rows: dict[date, list[ModelBGateMetric]] = defaultdict(list)
    for row in model_b_rows:
        daily_rows[row.prediction_day].append(row)
    ordered_days = tuple(sorted(daily_rows))
    daily_net = tuple(
        _mean(row.net_expectancy for row in daily_rows[day]) for day in ordered_days
    )
    daily_stressed = tuple(
        _mean(row.stressed_net_expectancy for row in daily_rows[day])
        for day in ordered_days
    )
    rng = random.Random(seed)
    stressed_bootstrap = tuple(
        _mean(daily_stressed[rng.randrange(len(daily_stressed))] for _ in daily_stressed)
        for _ in range(bootstrap_replicates)
    )
    stressed_ci_lower, stressed_ci_upper = _bca_interval(
        daily_stressed,
        stressed_bootstrap,
        confidence_level=confidence_level,
    )
    net_expectancy = _mean(daily_net)

    if (
        model_a.effective_days < minimum_effective_days
        or model_a.effective_folds < minimum_effective_folds
    ):
        decision = GateDecision.INSUFFICIENT_POWER
    elif (
        model_a.p_value <= alpha
        and model_a.excess_mean >= model_a_point_threshold
        and model_a.ci_lower_bound >= model_a_ci_lower_threshold
        and net_expectancy >= model_b_point_threshold
        and stressed_ci_lower > 0
    ):
        decision = GateDecision.PASS
    else:
        decision = GateDecision.FAIL
    return Q036GateResult(
        decision=decision,
        model_a=model_a,
        model_b_net_expectancy=net_expectancy,
        model_b_stressed_ci_lower_bound=stressed_ci_lower,
        model_b_stressed_ci_upper_bound=stressed_ci_upper,
        effective_days=model_a.effective_days,
        effective_folds=model_a.effective_folds,
        bootstrap_replicates=bootstrap_replicates,
        seed=seed,
        confidence_level=confidence_level,
    )
