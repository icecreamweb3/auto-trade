"""Lease-bound finalization of all independent Model-B outer folds."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.cross_fit_repository import DatabaseCrossFitStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class CrossFitModelBGateFinalizationError(RuntimeError):
    """The nested Model-B gate finalization lease or payload is invalid."""


@dataclass(frozen=True, slots=True)
class CrossFitModelBGateFinalizationPayload:
    execution_id: UUID


def parse_cross_fit_model_b_gate_finalization_payload(
    payload: Mapping[str, object],
) -> CrossFitModelBGateFinalizationPayload:
    if set(payload) != {"task_type", "payload_version", "execution_id"}:
        raise CrossFitModelBGateFinalizationError(
            "CROSS_FIT_MODEL_B_FINALIZE_GATE requires an exact v1 payload"
        )
    if payload.get("task_type") != "CROSS_FIT_MODEL_B_FINALIZE_GATE" or payload.get(
        "payload_version"
    ) != 1:
        raise CrossFitModelBGateFinalizationError(
            "CROSS_FIT_MODEL_B_FINALIZE_GATE requires payload_version 1"
        )
    try:
        execution_id = UUID(str(payload["execution_id"]))
    except (TypeError, ValueError) as error:
        raise CrossFitModelBGateFinalizationError(
            "execution_id must be a UUID"
        ) from error
    return CrossFitModelBGateFinalizationPayload(execution_id)


class CrossFitModelBGateFinalizationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseCrossFitStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise CrossFitModelBGateFinalizationError(
                "CROSS_FIT_MODEL_B_FINALIZE_GATE requires EVALUATOR executor"
            )
        parse_cross_fit_model_b_gate_finalization_payload(lease.payload)
        result_hash = await self._store.finalize_model_b_gate(
            lease.task_id, lease.lease_token
        )
        if len(result_hash) != 64 or any(
            character not in "0123456789abcdef" for character in result_hash
        ):
            raise CrossFitModelBGateFinalizationError(
                "Model-B gate finalization returned an invalid evidence hash"
            )
        return result_hash
