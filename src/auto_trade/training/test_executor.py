from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

from auto_trade.training.contracts import EntrySource, EntryUse, assert_entry_source_allowed


class TestExecutionError(ValueError):
    """TEST execution was rejected before any payload was read."""

    __test__ = False


class TestSetStore(Protocol):
    async def consume_test_set(
        self, test_set_id: UUID, request_id: UUID, requester_service: str
    ) -> TestConsumption: ...


@dataclass(frozen=True, slots=True)
class TestConsumption:
    allowed: bool
    reason_code: str
    consumption_chain_id: UUID | None
    dataset_version_id: UUID | None
    model_a_version_id: UUID | None
    model_b_version_id: UUID | None


@dataclass(frozen=True, slots=True)
class TestExecutor:
    __test__ = False

    store: TestSetStore
    requester_service: str

    async def consume(
        self, *, test_set_id: UUID, request_id: UUID, source: EntrySource
    ) -> TestConsumption:
        try:
            assert_entry_source_allowed(source=source, usage=EntryUse.END_TO_END_TEST)
        except ValueError as exc:
            raise TestExecutionError(str(exc)) from exc
        return await self.store.consume_test_set(
            test_set_id, request_id, self.requester_service
        )
