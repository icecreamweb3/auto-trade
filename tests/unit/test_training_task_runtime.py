from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from auto_trade.training.dataset_builder import DatasetBuildError
from auto_trade.training.model_a_pipeline import ModelAPipelineError
from auto_trade.training.orchestrator import ExecutorKind, TaskLease, TaskState
from auto_trade.training.task_handlers import TaskHandlerError
from auto_trade.training.task_runtime import TaskExecutor, failure_code


def lease() -> TaskLease:
    return TaskLease(
        uuid4(),
        ExecutorKind.WORKER,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": "DATASET_BUILD", "payload_version": 1},
    )


class FakeBackend:
    def __init__(
        self,
        claimed: TaskLease | None,
        *,
        result: str = "a" * 64,
        error: Exception | None = None,
        cancellation_requested: bool = False,
    ) -> None:
        self.claimed = claimed
        self.result = result
        self.error = error
        self.cancellation_requested = cancellation_requested
        self.started = False
        self.heartbeat_count = 0
        self.completions: list[tuple[TaskState, str | None, str | None]] = []

    async def claim(self, _lease_seconds: int) -> TaskLease | None:
        return self.claimed

    async def start(self, _lease: TaskLease) -> None:
        self.started = True

    async def heartbeat(self, _lease: TaskLease, _lease_seconds: int) -> bool:
        self.heartbeat_count += 1
        return self.cancellation_requested

    async def execute(self, _lease: TaskLease) -> str:
        if self.cancellation_requested:
            await asyncio.Event().wait()
        if self.error is not None:
            raise self.error
        return self.result

    async def complete(
        self,
        _lease: TaskLease,
        *,
        terminal_state: TaskState,
        result_hash: str | None = None,
        failure_code: str | None = None,
    ) -> None:
        self.completions.append((terminal_state, result_hash, failure_code))


async def immediate_sleep(_seconds: float) -> None:
    await asyncio.sleep(0)


@pytest.mark.asyncio
async def test_empty_queue_does_not_start_or_complete() -> None:
    backend = FakeBackend(None)

    assert not await TaskExecutor(backend).run_once()
    assert not backend.started
    assert backend.completions == []


@pytest.mark.asyncio
async def test_success_records_only_valid_result_hash() -> None:
    backend = FakeBackend(lease())

    assert await TaskExecutor(backend).run_once()
    assert backend.completions == [(TaskState.SUCCEEDED, "a" * 64, None)]


@pytest.mark.asyncio
async def test_invalid_result_hash_fails_closed() -> None:
    backend = FakeBackend(lease(), result="not-a-hash")

    assert await TaskExecutor(backend).run_once()
    assert backend.completions == [(TaskState.FAILED, None, "INVALID_RESULT_HASH")]


@pytest.mark.asyncio
async def test_handler_failure_persists_only_bounded_code() -> None:
    backend = FakeBackend(lease(), error=DatasetBuildError("secret detail"))

    assert await TaskExecutor(backend).run_once()
    assert backend.completions == [(TaskState.FAILED, None, "DATASET_BUILD_REJECTED")]


@pytest.mark.asyncio
async def test_heartbeat_cancellation_rolls_back_handler() -> None:
    backend = FakeBackend(lease(), cancellation_requested=True)
    executor = TaskExecutor(
        backend,
        lease_seconds=10,
        heartbeat_interval_seconds=1,
        sleep=immediate_sleep,
    )

    assert await executor.run_once()
    assert backend.heartbeat_count == 1
    assert backend.completions == [(TaskState.CANCELLED, None, "CANCELLATION_REQUESTED")]


def test_failure_codes_do_not_include_exception_text() -> None:
    assert failure_code(TaskHandlerError("payload secret")) == "UNSUPPORTED_TASK_TYPE"
    assert failure_code(RuntimeError("payload secret")) == "HANDLER_FAILED"
    assert (
        failure_code(ModelAPipelineError("future label detail"))
        == "MODEL_A_EVALUATION_REJECTED"
    )


def test_heartbeat_must_be_shorter_than_lease() -> None:
    with pytest.raises(ValueError, match="shorter"):
        TaskExecutor(FakeBackend(None), lease_seconds=10, heartbeat_interval_seconds=10)
