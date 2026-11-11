"""Lease-bound Q-036 intersection-union gate task."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.cross_fit_gate_repository import (
    CrossFitGateContext,
    CrossFitGateRecord,
    DatabaseCrossFitGateStore,
)
from auto_trade.training.evaluator import GateDecision, evaluate_q036_gate
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class CrossFitGateError(RuntimeError):
    """Frozen Q-036 evidence is absent, inconsistent, or cannot be persisted."""


@dataclass(frozen=True, slots=True)
class CrossFitGateTaskPayload:
    execution_id: UUID


def parse_cross_fit_gate_payload(
    payload: Mapping[str, object],
) -> CrossFitGateTaskPayload:
    allowed = {"task_type", "payload_version", "execution_id"}
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise CrossFitGateError(
            "unexpected CROSS_FIT_EVALUATE_GATE fields: " + ", ".join(unexpected)
        )
    if payload.get("task_type") != "CROSS_FIT_EVALUATE_GATE" or payload.get(
        "payload_version"
    ) != 1:
        raise CrossFitGateError("CROSS_FIT_EVALUATE_GATE requires payload_version 1")
    try:
        execution_id = UUID(str(payload["execution_id"]))
    except (KeyError, ValueError) as error:
        raise CrossFitGateError("CROSS_FIT_EVALUATE_GATE requires execution_id") from error
    return CrossFitGateTaskPayload(execution_id)


def _result_hash(context: CrossFitGateContext, decision: str, evaluation_id: UUID) -> str:
    value = {
        "corpus_hash": context.corpus_hash,
        "decision": decision,
        "evaluation_id": str(evaluation_id),
        "execution_id": str(context.execution_id),
        "model_b_evidence_hash": context.model_b_evidence_hash,
        "protocol_config_version_id": str(context.protocol_config_version_id),
    }
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


class CrossFitGateTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseCrossFitGateStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise CrossFitGateError("CROSS_FIT_EVALUATE_GATE requires EVALUATOR executor")
        payload = parse_cross_fit_gate_payload(lease.payload)
        context = await self._store.load_context(lease.task_id, lease.lease_token)
        if context.execution_id != payload.execution_id:
            raise CrossFitGateError("payload execution_id differs from leased gate context")
        if not context.model_b_metrics or not context.model_b_evidence_hash:
            raise CrossFitGateError("Q-036 requires completed temporary Model-B replay evidence")
        try:
            result = evaluate_q036_gate(
                context.model_a_metrics,
                context.model_b_metrics,
                alpha=float(context.alpha),
                minimum_effective_days=context.minimum_effective_days,
                minimum_effective_folds=context.minimum_effective_folds,
                model_a_point_threshold=float(context.model_a_point_threshold),
                model_a_ci_lower_threshold=float(context.model_a_ci_lower_threshold),
                model_b_point_threshold=float(context.model_b_point_threshold),
                bootstrap_replicates=context.bootstrap_replicates,
                seed=context.random_seed,
                confidence_level=float(context.confidence_level),
            )
        except ValueError as error:
            raise CrossFitGateError(f"Q-036 evidence is invalid: {error}") from error
        evaluation_id = await self._store.record_gate(
            CrossFitGateRecord(
                execution_id=context.execution_id,
                execution_lease_token=context.execution_lease_token,
                tpe_optimizer_run_id=context.tpe_optimizer_run_id,
                random_optimizer_run_id=context.random_optimizer_run_id,
                tpe_mean=Decimal(str(result.model_a.tpe_mean)),
                random_mean=Decimal(str(result.model_a.random_mean)),
                excess_mean=Decimal(str(result.model_a.excess_mean)),
                p_value=Decimal(str(result.model_a.p_value)),
                model_a_ci_lower_bound=Decimal(str(result.model_a.ci_lower_bound)),
                model_a_ci_upper_bound=Decimal(str(result.model_a.ci_upper_bound)),
                model_b_net_expectancy=Decimal(str(result.model_b_net_expectancy)),
                model_b_stressed_ci_lower_bound=Decimal(
                    str(result.model_b_stressed_ci_lower_bound)
                ),
                model_b_stress_multiplier=context.model_b_stress_multiplier,
                effective_day_count=result.effective_days,
                effective_fold_count=result.effective_folds,
            )
        )
        applied = await self._store.apply_gate(
            context.execution_id,
            context.execution_lease_token,
            evaluation_id,
        )
        if applied != result.decision.value:
            raise CrossFitGateError("database Q-036 decision diverges from evaluator")
        if result.decision is GateDecision.PASS:
            await self._store.promote_corpus(
                context.execution_id, context.execution_lease_token
            )
        return _result_hash(context, applied, evaluation_id)
