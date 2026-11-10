"""Strict parser for the READY Cross-fit runtime protocol."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal

from auto_trade.training.cross_fit_execution import (
    REQUIRED_M6_DECISIONS,
    CrossFitExecutionError,
)


def _mapping(value: object, name: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise CrossFitExecutionError(f"{name} must be an object")
    return value


def _integer(value: object, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise CrossFitExecutionError(f"{name} must be a positive integer")
    return value


def _decimal(value: object, name: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
    except Exception as error:
        raise CrossFitExecutionError(f"{name} must be numeric") from error
    if not parsed.is_finite() or parsed <= 0:
        raise CrossFitExecutionError(f"{name} must be positive and finite")
    return parsed


@dataclass(frozen=True, slots=True)
class CrossFitRuntimeProtocol:
    base_random_seed: int
    tpe_trials_per_fold: int
    random_trials_per_fold: int
    wall_clock_seconds_per_optimizer_per_fold: int
    repeat_count_per_fold: int
    prediction_window_days: int
    settlement_embargo_hours: int
    minimum_training_effective_days: int
    minimum_fitting_samples_per_fold: int
    minimum_eligible_folds: int
    minimum_effective_days: int
    minimum_complete_events: int
    minimum_complete_events_per_fold: int
    bootstrap_replicates: int
    alpha_per_gate: Decimal
    model_a_point_threshold_pp: Decimal
    model_a_ci_lower_threshold_pp: Decimal
    model_b_point_threshold_pp: Decimal
    model_b_required_stress_multiplier: Decimal


def parse_cross_fit_runtime_protocol(
    config: Mapping[str, object],
) -> CrossFitRuntimeProtocol:
    """Parse only a fully locked runtime protocol; incomplete drafts fail closed."""

    if config.get("protocol") != "CROSS_FIT_PROTOCOL_V1":
        raise CrossFitExecutionError("unsupported Cross-fit protocol")
    readiness = _mapping(config.get("question_readiness"), "question_readiness")
    missing = sorted(
        question
        for question in REQUIRED_M6_DECISIONS
        if readiness.get(question) != "READY"
    )
    if missing:
        raise CrossFitExecutionError(
            "M6 decisions are not READY: " + ", ".join(missing)
        )

    q030 = _mapping(config.get("q030_cross_fit"), "q030_cross_fit")
    q036 = _mapping(config.get("q036_go_no_go"), "q036_go_no_go")
    model_a = _mapping(q036.get("model_a"), "q036_go_no_go.model_a")
    model_b = _mapping(q036.get("model_b"), "q036_go_no_go.model_b")
    if q036.get("readiness") != "READY":
        raise CrossFitExecutionError("Q-036 runtime gate is not READY")
    if model_a.get("final_thresholds_locked") is not True:
        raise CrossFitExecutionError("Q-036 Model-A thresholds are not locked")
    if q036.get("gate_combination") != "INTERSECTION_UNION_BOTH_MUST_PASS":
        raise CrossFitExecutionError("Q-036 must require both gates to pass")
    if q030.get("equal_tpe_random_budget") is not True:
        raise CrossFitExecutionError("TPE and RANDOM fold budgets must be equal")

    tpe_budget = _integer(q030.get("tpe_trials_per_fold"), "tpe_trials_per_fold")
    random_budget = _integer(
        q030.get("random_trials_per_fold"), "random_trials_per_fold"
    )
    if tpe_budget != random_budget:
        raise CrossFitExecutionError("TPE and RANDOM fold budgets differ")

    return CrossFitRuntimeProtocol(
        base_random_seed=_integer(q030.get("random_seed"), "random_seed"),
        tpe_trials_per_fold=tpe_budget,
        random_trials_per_fold=random_budget,
        wall_clock_seconds_per_optimizer_per_fold=_integer(
            q030.get("maximum_wall_clock_seconds_per_optimizer_per_fold"),
            "maximum_wall_clock_seconds_per_optimizer_per_fold",
        ),
        repeat_count_per_fold=_integer(
            q030.get("repeat_count_per_fold"), "repeat_count_per_fold"
        ),
        prediction_window_days=_integer(
            q030.get("prediction_signal_window_days"),
            "prediction_signal_window_days",
        ),
        settlement_embargo_hours=_integer(
            q030.get("label_settlement_embargo_hours"),
            "label_settlement_embargo_hours",
        ),
        minimum_training_effective_days=_integer(
            q030.get("minimum_training_window_effective_days"),
            "minimum_training_window_effective_days",
        ),
        minimum_fitting_samples_per_fold=_integer(
            q030.get("minimum_fitting_samples_per_fold"),
            "minimum_fitting_samples_per_fold",
        ),
        minimum_eligible_folds=_integer(
            q036.get("minimum_eligible_outer_folds"),
            "minimum_eligible_outer_folds",
        ),
        minimum_effective_days=_integer(
            q036.get("minimum_effective_independent_utc_days"),
            "minimum_effective_independent_utc_days",
        ),
        minimum_complete_events=_integer(
            q036.get("minimum_complete_event_count"),
            "minimum_complete_event_count",
        ),
        minimum_complete_events_per_fold=_integer(
            q036.get("minimum_complete_events_per_fold"),
            "minimum_complete_events_per_fold",
        ),
        bootstrap_replicates=_integer(
            q036.get("bootstrap_replicates"), "bootstrap_replicates"
        ),
        alpha_per_gate=_decimal(q036.get("alpha_per_gate"), "alpha_per_gate"),
        model_a_point_threshold_pp=_decimal(
            model_a.get("minimum_point_estimate_percentage_points"),
            "model_a.minimum_point_estimate_percentage_points",
        ),
        model_a_ci_lower_threshold_pp=_decimal(
            model_a.get("minimum_ci_lower_bound_percentage_points"),
            "model_a.minimum_ci_lower_bound_percentage_points",
        ),
        model_b_point_threshold_pp=_decimal(
            model_b.get("minimum_point_estimate_percentage_points"),
            "model_b.minimum_point_estimate_percentage_points",
        ),
        model_b_required_stress_multiplier=_decimal(
            model_b.get("required_stress_multiplier"),
            "model_b.required_stress_multiplier",
        ),
    )
