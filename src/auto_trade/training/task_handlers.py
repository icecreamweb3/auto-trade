"""Explicit task-handler registry for the database lease runtime."""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from typing import Protocol

from auto_trade.training.orchestrator import TaskLease


class TaskHandlerError(RuntimeError):
    """A task cannot be executed under the registered handler contract."""


class TaskHandler(Protocol):
    async def __call__(self, lease: TaskLease) -> str: ...


TaskHandlerFactory = Callable[[Mapping[str, object]], Awaitable[str]]


class TaskHandlerRegistry:
    """Maps database task types to explicit handlers; no implicit fallback."""

    def __init__(self) -> None:
        self._handlers: dict[str, TaskHandler] = {}

    def register(self, task_type: str, handler: TaskHandler) -> None:
        normalized = task_type.strip().upper()
        if not normalized:
            raise TaskHandlerError("task_type cannot be blank")
        if normalized in self._handlers:
            raise TaskHandlerError(f"handler already registered: {normalized}")
        self._handlers[normalized] = handler

    async def execute(self, lease: TaskLease) -> str:
        task_type = str(lease.payload.get("task_type", "")).strip().upper()
        handler = self._handlers.get(task_type)
        if handler is None:
            raise TaskHandlerError(f"no handler registered for task type: {task_type or '<blank>'}")
        return await handler(lease)


def empty_registry() -> TaskHandlerRegistry:
    """Return a fail-closed registry used until a domain handler is installed."""
    return TaskHandlerRegistry()
