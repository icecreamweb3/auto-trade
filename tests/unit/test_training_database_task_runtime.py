from __future__ import annotations

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.database_task_runtime import DatabaseTaskRuntimeBackend
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class _ConnectionContext:
    def __init__(self, connection: object) -> None:
        self.connection = connection

    async def __aenter__(self) -> object:
        return self.connection

    async def __aexit__(self, *_args: object) -> None:
        return None


class _Engine:
    def __init__(self) -> None:
        self.connection = object()
        self.connect_count = 0
        self.begin_count = 0

    def connect(self) -> _ConnectionContext:
        self.connect_count += 1
        return _ConnectionContext(self.connection)

    def begin(self) -> _ConnectionContext:
        self.begin_count += 1
        return _ConnectionContext(self.connection)


def _lease(task_type: str) -> TaskLease:
    return TaskLease(
        uuid4(),
        ExecutorKind.EVALUATOR,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": task_type, "payload_version": 1},
    )


@pytest.mark.asyncio
async def test_model_a_evaluation_uses_chunk_managed_connection(monkeypatch) -> None:
    engine = _Engine()
    registry = MagicMock()
    registry.execute = AsyncMock(return_value="a" * 64)
    registry_factory = MagicMock(return_value=registry)

    def build_registry(
        connection: object,
        executor_kind: ExecutorKind,
        *,
        evaluation_commit_interval: int | None = None,
    ) -> MagicMock:
        registry_factory(connection, executor_kind, evaluation_commit_interval)
        return registry

    monkeypatch.setattr(
        "auto_trade.training.database_task_runtime.build_handler_registry",
        build_registry,
    )
    backend = DatabaseTaskRuntimeBackend(
        engine,  # type: ignore[arg-type]
        executor_kind=ExecutorKind.EVALUATOR,
        worker_identity="evaluator-test",
    )

    result = await backend.execute(_lease("MODEL_A_EVALUATION"))

    assert result == "a" * 64
    assert engine.connect_count == 1
    assert engine.begin_count == 0
    registry_factory.assert_called_once_with(
        engine.connection,
        ExecutorKind.EVALUATOR,
        1,
    )
