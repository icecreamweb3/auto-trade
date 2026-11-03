"""Authoritative Model-A TRAIN L0 aggregation task."""

from __future__ import annotations

from collections.abc import Mapping

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_a_pipeline import ModelAPipelineError
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class ModelAL0AggregationError(ModelAPipelineError):
    """The governed Discovery L0 could not be produced."""


def validate_model_a_l0_payload(payload: Mapping[str, object]) -> None:
    if payload != {"task_type": "MODEL_A_L0_AGGREGATION", "payload_version": 1}:
        raise ModelAL0AggregationError(
            "MODEL_A_L0_AGGREGATION requires exact v1 payload"
        )


class ModelAL0AggregationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise ModelAL0AggregationError(
                "MODEL_A_L0_AGGREGATION requires EVALUATOR executor"
            )
        validate_model_a_l0_payload(lease.payload)
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_model_a_discovery_l0(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": lease.task_id, "lease_token": lease.lease_token},
        )
        return str(result.scalar_one())
