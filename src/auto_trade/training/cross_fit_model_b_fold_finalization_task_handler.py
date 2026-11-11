"""Lease-bound finalization of one independent Model-B outer-fold replay."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.cross_fit_repository import DatabaseCrossFitStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class CrossFitModelBFoldFinalizationError(RuntimeError):
    """The Model-B fold finalization lease or payload is invalid."""


@dataclass(frozen=True, slots=True)
class CrossFitModelBFoldFinalizationPayload:
    execution_id: UUID
    fold_number: int


def parse_cross_fit_model_b_fold_finalization_payload(
    payload: Mapping[str, object],
) -> CrossFitModelBFoldFinalizationPayload:
    if set(payload) != {
        "task_type",
        "payload_version",
        "execution_id",
        "fold_number",
    }:
        raise CrossFitModelBFoldFinalizationError(
            "CROSS_FIT_MODEL_B_FINALIZE_FOLD requires an exact v1 payload"
        )
    if payload.get("task_type") != "CROSS_FIT_MODEL_B_FINALIZE_FOLD" or payload.get(
        "payload_version"
    ) != 1:
        raise CrossFitModelBFoldFinalizationError(
            "CROSS_FIT_MODEL_B_FINALIZE_FOLD requires payload_version 1"
        )
    try:
        execution_id = UUID(str(payload["execution_id"]))
    except (TypeError, ValueError) as error:
        raise CrossFitModelBFoldFinalizationError(
            "execution_id must be a UUID"
        ) from error
    fold_number = payload.get("fold_number")
    if (
        isinstance(fold_number, bool)
        or not isinstance(fold_number, int)
        or fold_number <= 0
    ):
        raise CrossFitModelBFoldFinalizationError(
            "fold_number must be a positive integer"
        )
    return CrossFitModelBFoldFinalizationPayload(execution_id, fold_number)


class CrossFitModelBFoldFinalizationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseCrossFitStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise CrossFitModelBFoldFinalizationError(
                "CROSS_FIT_MODEL_B_FINALIZE_FOLD requires EVALUATOR executor"
            )
        parse_cross_fit_model_b_fold_finalization_payload(lease.payload)
        result_hash = await self._store.finalize_model_b_fold(
            lease.task_id, lease.lease_token
        )
        if len(result_hash) != 64 or any(
            character not in "0123456789abcdef" for character in result_hash
        ):
            raise CrossFitModelBFoldFinalizationError(
                "Model-B fold finalization returned an invalid evidence hash"
            )
        return result_hash
