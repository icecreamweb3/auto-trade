"""Authoritative Model-A TRAIN L0 aggregation task."""

from __future__ import annotations

import logging
import time
from collections.abc import Mapping

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_a_pipeline import ModelAPipelineError
from auto_trade.training.orchestrator import ExecutorKind, TaskLease

LOGGER = logging.getLogger(__name__)


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
        started_at = time.monotonic()
        LOGGER.info(
            "model-A L0 started task_id=%s attempt=%s",
            lease.task_id,
            lease.attempt_number,
        )
        timeout_result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.configure_training_l0_statement_timeout(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": lease.task_id, "lease_token": lease.lease_token},
        )
        timeout_seconds = int(timeout_result.scalar_one())
        LOGGER.info(
            "model-A L0 stage complete task_id=%s stage=TIMEOUT_CONFIGURED "
            "timeout_seconds=%s elapsed_seconds=%.3f",
            lease.task_id,
            timeout_seconds,
            time.monotonic() - started_at,
        )
        universe_result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.build_training_opportunity_universe(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": lease.task_id, "lease_token": lease.lease_token},
        )
        universe_id = str(universe_result.scalar_one())
        LOGGER.info(
            "model-A L0 stage complete task_id=%s "
            "stage=OPPORTUNITY_UNIVERSE_READY universe_id=%s elapsed_seconds=%.3f",
            lease.task_id,
            universe_id,
            time.monotonic() - started_at,
        )
        finalization_timeout_result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.configure_training_l0_statement_timeout(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": lease.task_id, "lease_token": lease.lease_token},
        )
        finalization_timeout_seconds = int(finalization_timeout_result.scalar_one())
        LOGGER.info(
            "model-A L0 stage complete task_id=%s "
            "stage=FINALIZATION_TIMEOUT_CONFIGURED remaining_seconds=%s "
            "elapsed_seconds=%.3f",
            lease.task_id,
            finalization_timeout_seconds,
            time.monotonic() - started_at,
        )
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
        evidence_hash = str(result.scalar_one())
        LOGGER.info(
            "model-A L0 stage complete task_id=%s stage=EVIDENCE_RECORDED "
            "elapsed_seconds=%.3f",
            lease.task_id,
            time.monotonic() - started_at,
        )
        return evidence_hash
