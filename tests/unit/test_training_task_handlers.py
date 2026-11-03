from datetime import UTC, datetime
from uuid import uuid4

import pytest

from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.task_handlers import TaskHandlerError, TaskHandlerRegistry


def lease(payload: dict[str, object]) -> TaskLease:
    return TaskLease(
        uuid4(),
        ExecutorKind.WORKER,
        uuid4(),
        1,
        datetime.now(UTC),
        0,
        payload,
    )


@pytest.mark.asyncio
async def test_registry_rejects_unregistered_task() -> None:
    with pytest.raises(TaskHandlerError, match="no handler registered"):
        await TaskHandlerRegistry().execute(lease({"task_type": "DATASET_BUILD"}))


@pytest.mark.asyncio
async def test_registry_dispatches_registered_handler() -> None:
    registry = TaskHandlerRegistry()

    async def handler(_lease: TaskLease) -> str:
        return "result-hash"

    registry.register("DATASET_BUILD", handler)
    assert await registry.execute(lease({"task_type": "dataset_build"})) == "result-hash"


def test_registry_rejects_duplicate_handler() -> None:
    registry = TaskHandlerRegistry()

    async def handler(_lease: TaskLease) -> str:
        return "result-hash"

    registry.register("DATASET_BUILD", handler)
    with pytest.raises(TaskHandlerError, match="already registered"):
        registry.register("dataset_build", handler)
