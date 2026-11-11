"""Compile governed Model-B optimizer parameters into one replayable exit policy."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from uuid import UUID

from auto_trade.training.optimizer import (
    CandidateStatus,
    CandidateValidation,
    ParameterRule,
    validate_candidate,
)
from auto_trade.training.simulator import FixedExitPolicy, fixed_exit_policy_from_config


class ModelBCandidatePolicyError(ValueError):
    """A candidate cannot be compiled under its frozen governed template."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class CompiledModelBCandidate:
    candidate_parameters: Mapping[str, object]
    candidate_content_hash: str
    effective_exit_rule_config: Mapping[str, object]
    effective_exit_rule_content_hash: str
    remaining_position_fraction: Decimal
    policy: FixedExitPolicy


def _canonical_hash(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
            allow_nan=False,
        ).encode()
    ).hexdigest()


def _decimal(value: object, field: str) -> Decimal:
    if isinstance(value, bool) or value is None:
        raise ModelBCandidatePolicyError(
            "PARAMETER_TYPE_INVALID", f"{field} must be numeric"
        )
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise ModelBCandidatePolicyError(
            "PARAMETER_TYPE_INVALID", f"{field} must be numeric"
        ) from error
    if not parsed.is_finite():
        raise ModelBCandidatePolicyError(
            "PARAMETER_NON_FINITE", f"{field} must be finite"
        )
    return parsed


def _decimal_list(template: Mapping[str, object], field: str) -> tuple[Decimal, ...]:
    raw = template.get(field)
    if not isinstance(raw, list) or len(raw) != 4:
        raise ModelBCandidatePolicyError(
            "POLICY_TEMPLATE_INVALID", f"{field} must contain four values"
        )
    values = tuple(_decimal(value, field) for value in raw)
    if any(value <= 0 for value in values) or tuple(sorted(set(values))) != values:
        raise ModelBCandidatePolicyError(
            "POLICY_TEMPLATE_INVALID", f"{field} must strictly increase"
        )
    return values


def compile_model_b_exit_rule_config(
    search_space_config: Mapping[str, object],
    candidate: Mapping[str, object],
) -> tuple[dict[str, object], Decimal]:
    """Materialize the candidate without consulting outcomes or future data."""

    if search_space_config.get("model_family") != "RULE_BASED_EXIT_V2":
        raise ModelBCandidatePolicyError(
            "SEARCH_SPACE_CONTRACT_INVALID", "Model-B search space must use V2"
        )
    expected = {
        "exit_policy_template",
        "initial_stop_loss_percent",
        "max_holding_seconds",
        "shared_close_fraction",
        "trigger_scale",
    }
    if set(candidate) != expected:
        raise ModelBCandidatePolicyError(
            "CANDIDATE_PARAMETER_SET_INVALID", "candidate parameter set is not governed"
        )
    template_name = candidate.get("exit_policy_template")
    templates = search_space_config.get("policy_templates")
    if not isinstance(template_name, str) or not isinstance(templates, Mapping):
        raise ModelBCandidatePolicyError(
            "POLICY_TEMPLATE_INVALID", "candidate template is unavailable"
        )
    raw_template = templates.get(template_name)
    if not isinstance(raw_template, Mapping):
        raise ModelBCandidatePolicyError(
            "POLICY_TEMPLATE_INVALID", "candidate template is not frozen"
        )

    scale = _decimal(candidate.get("trigger_scale"), "trigger_scale")
    close_fraction = _decimal(
        candidate.get("shared_close_fraction"), "shared_close_fraction"
    )
    initial_stop = _decimal(
        candidate.get("initial_stop_loss_percent"), "initial_stop_loss_percent"
    )
    raw_holding = candidate.get("max_holding_seconds")
    if isinstance(raw_holding, bool) or not isinstance(raw_holding, int):
        raise ModelBCandidatePolicyError(
            "PARAMETER_TYPE_INVALID", "max_holding_seconds must be integral"
        )
    partial_base = _decimal_list(
        raw_template, "base_partial_trigger_profit_percents"
    )
    locked_base = _decimal_list(
        raw_template, "base_stop_locked_profit_percents"
    )
    activation_base = _decimal(
        raw_template.get("base_high_water_trailing_activation_percent"),
        "base_high_water_trailing_activation_percent",
    )
    drawdown_base = _decimal(
        raw_template.get("base_high_water_max_drawdown_percent"),
        "base_high_water_max_drawdown_percent",
    )
    minimum_remaining = _decimal(
        raw_template.get("minimum_remaining_fraction"),
        "minimum_remaining_fraction",
    )
    if scale <= 0 or not 0 < close_fraction < 1 or initial_stop <= 0:
        raise ModelBCandidatePolicyError(
            "PARAMETER_OUT_OF_RANGE", "candidate values must be positive and bounded"
        )
    remaining = (Decimal(1) - close_fraction) ** len(partial_base)
    if remaining < minimum_remaining:
        raise ModelBCandidatePolicyError(
            "MINIMUM_REMAINING_FRACTION_VIOLATED",
            "partial exits leave less than the governed remaining position",
        )
    partial_triggers = tuple(value * scale for value in partial_base)
    locked_profits = tuple(value * scale for value in locked_base)
    if any(
        locked >= trigger
        for locked, trigger in zip(locked_profits, partial_triggers, strict=True)
    ):
        raise ModelBCandidatePolicyError(
            "POLICY_TEMPLATE_INVALID", "scaled stop locks must remain below triggers"
        )
    effective: dict[str, object] = {
        "model_family": "RULE_BASED_EXIT_V2",
        "return_basis": "ENTRY_FILL_PRICE_PERCENT",
        "initial_stop_loss_percent": initial_stop,
        "partial_take_profit": {
            "fraction_basis": "REMAINING_POSITION",
            "levels": [
                {
                    "trigger_profit_percent": trigger,
                    "close_fraction": close_fraction,
                }
                for trigger in partial_triggers
            ],
        },
        "stop_schedule": {
            "levels": [
                {
                    "trigger_profit_percent": trigger,
                    "locked_profit_percent": locked,
                }
                for trigger, locked in zip(partial_triggers, locked_profits, strict=True)
            ],
            "high_water_trailing_activation_percent": activation_base * scale,
            "high_water_max_drawdown_percent": drawdown_base * scale,
        },
        "max_holding_seconds": raw_holding,
        "intrabar_conflict_policy": "WORST_CASE",
        "rule_activation_timing": "NEXT_BAR",
    }
    return effective, remaining


def validate_model_b_policy_candidate(
    candidate: Mapping[str, object],
    search_space: Mapping[str, ParameterRule],
    search_space_config: Mapping[str, object],
) -> CandidateValidation:
    generic = validate_candidate(candidate, search_space)
    if generic.status is CandidateStatus.REJECTED:
        return generic
    try:
        compile_model_b_exit_rule_config(search_space_config, candidate)
    except ModelBCandidatePolicyError as error:
        return CandidateValidation(CandidateStatus.REJECTED, (error.code,))
    return generic


def compile_model_b_candidate_policy(
    *,
    exit_rule_version_id: UUID,
    search_space_config: Mapping[str, object],
    candidate: Mapping[str, object],
) -> CompiledModelBCandidate:
    effective, remaining = compile_model_b_exit_rule_config(search_space_config, candidate)
    return CompiledModelBCandidate(
        dict(candidate),
        _canonical_hash(candidate),
        effective,
        _canonical_hash(effective),
        remaining,
        fixed_exit_policy_from_config(exit_rule_version_id, effective),
    )
