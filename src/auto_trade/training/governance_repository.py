from __future__ import annotations

import json
from collections.abc import Mapping
from datetime import datetime
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.orchestrator import ExecutorKind, TaskLease, TaskState

_CLAIM_FUNCTIONS = {
    ExecutorKind.WORKER: "claim_training_worker_task",
    ExecutorKind.OPTIMIZER: "claim_training_optimizer_task",
    ExecutorKind.EVALUATOR: "claim_training_evaluator_task",
    ExecutorKind.MODEL_B: "claim_training_model_b_task",
}

_TASK_EXECUTORS = {
    "DATASET_BUILD": ExecutorKind.WORKER,
    "MODEL_A_CANDIDATE_SCAN": ExecutorKind.WORKER,
    "MODEL_A_EVALUATION": ExecutorKind.EVALUATOR,
    "MODEL_A_L0_AGGREGATION": ExecutorKind.EVALUATOR,
    "MODEL_B_REPLAY": ExecutorKind.MODEL_B,
    "PORTFOLIO_EVALUATION": ExecutorKind.EVALUATOR,
    "OPTIMIZER_TRIAL": ExecutorKind.OPTIMIZER,
    "ARCHIVE_VERIFY": ExecutorKind.EVALUATOR,
}


class DatabaseOrchestratorStore:
    """State-only orchestration access; it never reads metrics or TEST payloads."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def enqueue_task(
        self,
        *,
        experiment_id: UUID,
        iteration_id: UUID | None,
        optimizer_run_id: UUID | None,
        parent_task_id: UUID | None,
        task_type: str,
        executor_kind: ExecutorKind,
        idempotency_key: str,
        payload: Mapping[str, object],
        priority: int = 100,
    ) -> UUID:
        expected_executor = _TASK_EXECUTORS.get(task_type)
        if expected_executor is None:
            raise ValueError(f"unsupported task_type: {task_type}")
        if executor_kind is not expected_executor:
            raise ValueError(
                f"task_type {task_type} requires executor {expected_executor.value}"
            )
        payload_version = payload.get("payload_version")
        if (
            isinstance(payload_version, bool)
            or not isinstance(payload_version, int)
            or payload_version <= 0
        ):
            raise ValueError("task payload requires a positive integer payload_version")
        supplied_task_type = payload.get("task_type")
        if supplied_task_type is not None and supplied_task_type != task_type:
            raise ValueError("task payload task_type does not match task_type")
        canonical_payload = dict(payload)
        canonical_payload["task_type"] = task_type
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.enqueue_training_task(
                    :experiment_id, :iteration_id, :optimizer_run_id,
                    :parent_task_id, :task_type, :executor_kind,
                    :idempotency_key, CAST(:payload AS jsonb), :priority
                )
                """
            ),
            {
                "experiment_id": experiment_id,
                "iteration_id": iteration_id,
                "optimizer_run_id": optimizer_run_id,
                "parent_task_id": parent_task_id,
                "task_type": task_type,
                "executor_kind": executor_kind.value,
                "idempotency_key": idempotency_key,
                "payload": json.dumps(
                    canonical_payload, sort_keys=True, separators=(",", ":")
                ),
                "priority": priority,
            },
        )
        return cast(UUID, result.scalar_one())

    async def request_cancellation(self, task_id: UUID, reason: str) -> None:
        await self._connection.execute(
            text("SELECT strategy_training.request_training_task_cancellation(:id, :reason)"),
            {"id": task_id, "reason": reason},
        )

    async def resume(self, task_id: UUID) -> None:
        await self._connection.execute(
            text("SELECT strategy_training.resume_training_task(:id)"),
            {"id": task_id},
        )

    async def advance_optimizer_runs(self) -> tuple[tuple[UUID, str], ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT optimizer_run_id, action
                FROM strategy_training.advance_training_optimizer_runs()
                """
            )
        )
        return tuple(
            (cast(UUID, row["optimizer_run_id"]), str(row["action"]))
            for row in result.mappings().all()
        )

    async def advance_candidate_scans(self) -> tuple[tuple[UUID, str], ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT iteration_id, action
                FROM strategy_training.advance_training_candidate_scans()
                """
            )
        )
        return tuple(
            (cast(UUID, row["iteration_id"]), str(row["action"]))
            for row in result.mappings().all()
        )

    async def advance_model_a_l0_tasks(self) -> tuple[tuple[UUID, str], ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT iteration_id, action
                FROM strategy_training.advance_training_model_a_l0_tasks()
                """
            )
        )
        return tuple(
            (cast(UUID, row["iteration_id"]), str(row["action"]))
            for row in result.mappings().all()
        )


class DatabaseTaskWorkerStore:
    """Lease-token capability interface shared by isolated execution services."""

    def __init__(
        self,
        connection: AsyncConnection,
        *,
        executor_kind: ExecutorKind,
        worker_identity: str,
    ) -> None:
        if executor_kind is ExecutorKind.ORCHESTRATOR:
            raise ValueError("orchestrator cannot claim execution tasks")
        if not worker_identity.strip():
            raise ValueError("worker_identity cannot be blank")
        self._connection = connection
        self._executor_kind = executor_kind
        self._worker_identity = worker_identity

    async def claim(self, lease_seconds: int) -> TaskLease | None:
        function_name = _CLAIM_FUNCTIONS[self._executor_kind]
        result = await self._connection.execute(
            text(
                f"""
                SELECT claimed_task_id, claimed_lease_token,
                       claimed_attempt_number, claimed_checkpoint_sequence,
                       claimed_payload, claimed_lease_expires_at
                FROM strategy_training.{function_name}(:worker, :lease_seconds)
                """
            ),
            {"worker": self._worker_identity, "lease_seconds": lease_seconds},
        )
        row = result.mappings().one_or_none()
        if row is None:
            return None
        return TaskLease(
            cast(UUID, row["claimed_task_id"]),
            self._executor_kind,
            cast(UUID, row["claimed_lease_token"]),
            int(row["claimed_attempt_number"]),
            cast(datetime, row["claimed_lease_expires_at"]),
            int(row["claimed_checkpoint_sequence"]),
            cast(Mapping[str, object], row["claimed_payload"]),
        )

    async def start(self, lease: TaskLease) -> None:
        await self._connection.execute(
            text("SELECT strategy_training.start_training_task(:task, :token, :worker)"),
            {"task": lease.task_id, "token": lease.lease_token, "worker": self._worker_identity},
        )

    async def heartbeat(self, lease: TaskLease, lease_seconds: int) -> bool:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.heartbeat_training_task(
                    :task, :token, :worker, :lease_seconds
                )
                """
            ),
            {
                "task": lease.task_id,
                "token": lease.lease_token,
                "worker": self._worker_identity,
                "lease_seconds": lease_seconds,
            },
        )
        return bool(result.scalar_one())

    async def checkpoint(
        self,
        lease: TaskLease,
        *,
        sequence_no: int,
        checkpoint_hash: str,
        checkpoint_uri_hash: str,
        fact_watermark: Mapping[str, object],
    ) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_task_checkpoint(
                    :task, :token, :worker, :sequence_no,
                    :checkpoint_hash, :uri_hash, CAST(:watermark AS jsonb)
                )
                """
            ),
            {
                "task": lease.task_id,
                "token": lease.lease_token,
                "worker": self._worker_identity,
                "sequence_no": sequence_no,
                "checkpoint_hash": checkpoint_hash,
                "uri_hash": checkpoint_uri_hash,
                "watermark": json.dumps(fact_watermark, sort_keys=True, separators=(",", ":")),
            },
        )
        return cast(UUID, result.scalar_one())

    async def pause(self, lease: TaskLease) -> None:
        await self._connection.execute(
            text("SELECT strategy_training.pause_training_task(:task, :token, :worker)"),
            {"task": lease.task_id, "token": lease.lease_token, "worker": self._worker_identity},
        )

    async def complete(
        self,
        lease: TaskLease,
        *,
        terminal_state: TaskState,
        result_hash: str | None = None,
        failure_code: str | None = None,
    ) -> None:
        if terminal_state not in {TaskState.SUCCEEDED, TaskState.FAILED, TaskState.CANCELLED}:
            raise ValueError("terminal_state must be terminal")
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.complete_training_task(
                    :task, :token, :worker, :state, :result_hash, :failure_code
                )
                """
            ),
            {
                "task": lease.task_id,
                "token": lease.lease_token,
                "worker": self._worker_identity,
                "state": terminal_state.value,
                "result_hash": result_hash,
                "failure_code": failure_code,
            },
        )
