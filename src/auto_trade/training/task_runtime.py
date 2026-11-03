"""Lease-safe execution loop for governed training tasks."""

from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import Awaitable, Callable
from typing import Protocol

from auto_trade.training.archive_verify_task_handler import ArchiveVerifyError
from auto_trade.training.dataset_builder import DatasetBuildError
from auto_trade.training.model_a_candidate_scan_task_handler import (
    ModelACandidateScanError,
)
from auto_trade.training.model_a_l0_task_handler import ModelAL0AggregationError
from auto_trade.training.model_a_pipeline import ModelAPipelineError
from auto_trade.training.model_b_replay_task_handler import ModelBReplayError
from auto_trade.training.optimizer_trial_task_handler import OptimizerTrialError
from auto_trade.training.orchestrator import TaskLease, TaskState
from auto_trade.training.portfolio_evaluation_task_handler import (
    PortfolioEvaluationError,
)
from auto_trade.training.task_handlers import TaskHandlerError

LOGGER = logging.getLogger(__name__)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class TaskCancellationRequested(RuntimeError):
    """The database cancellation flag was observed by a heartbeat."""


class InvalidTaskResult(RuntimeError):
    """A handler returned evidence that is not a SHA-256 content hash."""


class TaskRuntimeBackend(Protocol):
    async def claim(self, lease_seconds: int) -> TaskLease | None: ...

    async def start(self, lease: TaskLease) -> None: ...

    async def heartbeat(self, lease: TaskLease, lease_seconds: int) -> bool: ...

    async def execute(self, lease: TaskLease) -> str: ...

    async def complete(
        self,
        lease: TaskLease,
        *,
        terminal_state: TaskState,
        result_hash: str | None = None,
        failure_code: str | None = None,
    ) -> None: ...


Sleep = Callable[[float], Awaitable[None]]


def failure_code(error: BaseException) -> str:
    """Return a bounded non-secret code; exception text never reaches the database."""
    if isinstance(error, TaskHandlerError):
        return "UNSUPPORTED_TASK_TYPE"
    if isinstance(error, InvalidTaskResult):
        return "INVALID_RESULT_HASH"
    if isinstance(error, ArchiveVerifyError):
        return "ARCHIVE_VERIFY_REJECTED"
    if isinstance(error, DatasetBuildError):
        return "DATASET_BUILD_REJECTED"
    if isinstance(error, ModelACandidateScanError):
        return "MODEL_A_CANDIDATE_SCAN_REJECTED"
    if isinstance(error, ModelAL0AggregationError):
        return "MODEL_A_L0_AGGREGATION_REJECTED"
    if isinstance(error, ModelAPipelineError):
        return "MODEL_A_EVALUATION_REJECTED"
    if isinstance(error, ModelBReplayError):
        return "MODEL_B_REPLAY_REJECTED"
    if isinstance(error, PortfolioEvaluationError):
        return "PORTFOLIO_EVALUATION_REJECTED"
    if isinstance(error, OptimizerTrialError):
        return "OPTIMIZER_TRIAL_REJECTED"
    return "HANDLER_FAILED"


class TaskExecutor:
    def __init__(
        self,
        backend: TaskRuntimeBackend,
        *,
        lease_seconds: int = 300,
        heartbeat_interval_seconds: float = 60.0,
        sleep: Sleep = asyncio.sleep,
    ) -> None:
        if lease_seconds <= 1:
            raise ValueError("lease_seconds must be greater than 1")
        if not 0 < heartbeat_interval_seconds < lease_seconds:
            raise ValueError("heartbeat interval must be positive and shorter than the lease")
        self._backend = backend
        self._lease_seconds = lease_seconds
        self._heartbeat_interval_seconds = heartbeat_interval_seconds
        self._sleep = sleep

    async def _heartbeat(self, lease: TaskLease) -> None:
        while True:
            await self._sleep(self._heartbeat_interval_seconds)
            if await self._backend.heartbeat(lease, self._lease_seconds):
                raise TaskCancellationRequested

    @staticmethod
    async def _cancel(task: asyncio.Task[object]) -> None:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception:
            # Cleanup must not replace the terminal decision selected by the
            # lease/cancellation branch. The primary failure is logged there.
            pass

    async def run_once(self) -> bool:
        lease = await self._backend.claim(self._lease_seconds)
        if lease is None:
            return False
        await self._backend.start(lease)

        handler_task = asyncio.create_task(self._backend.execute(lease))
        heartbeat_task = asyncio.create_task(self._heartbeat(lease))
        done, _ = await asyncio.wait(
            {handler_task, heartbeat_task}, return_when=asyncio.FIRST_COMPLETED
        )

        if heartbeat_task in done:
            try:
                await heartbeat_task
            except TaskCancellationRequested:
                await self._cancel(handler_task)
                await self._backend.complete(
                    lease,
                    terminal_state=TaskState.CANCELLED,
                    failure_code="CANCELLATION_REQUESTED",
                )
                return True
            except BaseException:
                # The lease capability is now uncertain. Roll the handler back,
                # but do not attempt a terminal update using a possibly stale token.
                await self._cancel(handler_task)
                raise

        await self._cancel(heartbeat_task)
        try:
            result_hash = await handler_task
            if not _SHA256.fullmatch(result_hash):
                raise InvalidTaskResult("handler result must be a lowercase SHA-256 hash")
        except Exception as error:
            LOGGER.exception("training task failed task_id=%s", lease.task_id)
            await self._backend.complete(
                lease,
                terminal_state=TaskState.FAILED,
                failure_code=failure_code(error),
            )
            return True

        await self._backend.complete(
            lease,
            terminal_state=TaskState.SUCCEEDED,
            result_hash=result_hash,
        )
        return True
