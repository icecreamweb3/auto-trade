"""Transactional adapter between TaskExecutor and PostgreSQL procedures."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from auto_trade.training.archive_verify_task_handler import ArchiveVerifyTaskHandler
from auto_trade.training.dataset_task_handler import DatasetBuildTaskHandler
from auto_trade.training.governance_repository import DatabaseTaskWorkerStore
from auto_trade.training.model_a_evaluation_task_handler import (
    ModelAEvaluationTaskHandler,
)
from auto_trade.training.model_b_replay_task_handler import ModelBReplayTaskHandler
from auto_trade.training.optimizer_trial_task_handler import OptimizerTrialTaskHandler
from auto_trade.training.orchestrator import ExecutorKind, TaskLease, TaskState
from auto_trade.training.portfolio_evaluation_task_handler import (
    PortfolioEvaluationTaskHandler,
)
from auto_trade.training.task_handlers import TaskHandlerRegistry


def build_handler_registry(
    connection: AsyncConnection, executor_kind: ExecutorKind
) -> TaskHandlerRegistry:
    registry = TaskHandlerRegistry()
    if executor_kind is ExecutorKind.WORKER:
        registry.register("DATASET_BUILD", DatasetBuildTaskHandler(connection))
    elif executor_kind is ExecutorKind.EVALUATOR:
        registry.register("ARCHIVE_VERIFY", ArchiveVerifyTaskHandler(connection))
        registry.register("MODEL_A_EVALUATION", ModelAEvaluationTaskHandler(connection))
        registry.register(
            "PORTFOLIO_EVALUATION", PortfolioEvaluationTaskHandler(connection)
        )
    elif executor_kind is ExecutorKind.MODEL_B:
        registry.register("MODEL_B_REPLAY", ModelBReplayTaskHandler(connection))
    elif executor_kind is ExecutorKind.OPTIMIZER:
        registry.register("OPTIMIZER_TRIAL", OptimizerTrialTaskHandler(connection))
    return registry


class DatabaseTaskRuntimeBackend:
    def __init__(
        self,
        engine: AsyncEngine,
        *,
        executor_kind: ExecutorKind,
        worker_identity: str,
    ) -> None:
        self._engine = engine
        self._executor_kind = executor_kind
        self._worker_identity = worker_identity

    def _store(self, connection: AsyncConnection) -> DatabaseTaskWorkerStore:
        return DatabaseTaskWorkerStore(
            connection,
            executor_kind=self._executor_kind,
            worker_identity=self._worker_identity,
        )

    async def claim(self, lease_seconds: int) -> TaskLease | None:
        async with self._engine.begin() as connection:
            return await self._store(connection).claim(lease_seconds)

    async def start(self, lease: TaskLease) -> None:
        async with self._engine.begin() as connection:
            await self._store(connection).start(lease)

    async def heartbeat(self, lease: TaskLease, lease_seconds: int) -> bool:
        async with self._engine.begin() as connection:
            return await self._store(connection).heartbeat(lease, lease_seconds)

    async def execute(self, lease: TaskLease) -> str:
        async with self._engine.begin() as connection:
            registry = build_handler_registry(connection, self._executor_kind)
            return await registry.execute(lease)

    async def complete(
        self,
        lease: TaskLease,
        *,
        terminal_state: TaskState,
        result_hash: str | None = None,
        failure_code: str | None = None,
    ) -> None:
        async with self._engine.begin() as connection:
            await self._store(connection).complete(
                lease,
                terminal_state=terminal_state,
                result_hash=result_hash,
                failure_code=failure_code,
            )
