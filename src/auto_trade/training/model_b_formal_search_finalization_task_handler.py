"""Evaluator-isolated comparison and finalist freeze for formal Model-B search."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_b_formal_search_repository import (
    DatabaseModelBFormalSearchStore,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class ModelBFormalSearchFinalizationError(RuntimeError):
    """The formal Model-B finalization lease or payload is invalid."""


@dataclass(frozen=True, slots=True)
class ModelBFormalSearchFinalizationPayload:
    formal_search_run_id: UUID


def parse_model_b_formal_search_finalization_payload(
    payload: Mapping[str, object],
) -> ModelBFormalSearchFinalizationPayload:
    if set(payload) != {"task_type", "payload_version", "formal_search_run_id"}:
        raise ModelBFormalSearchFinalizationError(
            "MODEL_B_FINALIZE_FORMAL requires an exact v1 payload"
        )
    if payload.get("task_type") != "MODEL_B_FINALIZE_FORMAL" or payload.get(
        "payload_version"
    ) != 1:
        raise ModelBFormalSearchFinalizationError(
            "MODEL_B_FINALIZE_FORMAL requires payload_version 1"
        )
    try:
        formal_search_run_id = UUID(str(payload["formal_search_run_id"]))
    except (TypeError, ValueError) as error:
        raise ModelBFormalSearchFinalizationError(
            "formal_search_run_id must be a UUID"
        ) from error
    return ModelBFormalSearchFinalizationPayload(formal_search_run_id)


class ModelBFormalSearchFinalizationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseModelBFormalSearchStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise ModelBFormalSearchFinalizationError(
                "MODEL_B_FINALIZE_FORMAL requires EVALUATOR executor"
            )
        parse_model_b_formal_search_finalization_payload(lease.payload)
        result_hash = await self._store.finalize(lease.task_id, lease.lease_token)
        if len(result_hash) != 64 or any(
            character not in "0123456789abcdef" for character in result_hash
        ):
            raise ModelBFormalSearchFinalizationError(
                "formal Model-B finalization returned an invalid evidence hash"
            )
        return result_hash
