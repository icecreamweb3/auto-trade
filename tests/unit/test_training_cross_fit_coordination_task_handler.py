from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from auto_trade.training.cross_fit_coordination_task_handler import (
    CrossFitCoordinationError,
    CrossFitCoordinationTaskHandler,
    parse_cross_fit_coordination_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _payload() -> dict[str, object]:
    return {
        "task_type": "CROSS_FIT_COORDINATE",
        "payload_version": 1,
        "execution_id": str(uuid4()),
        "fold_number": 1,
    }


def _lease(*, executor: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        executor,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        _payload(),
    )


def test_coordination_payload_is_exact_and_typed() -> None:
    parsed = parse_cross_fit_coordination_payload(_payload())
    assert parsed.fold_number == 1

    unexpected = _payload()
    unexpected["decision"] = "PASS"
    with pytest.raises(CrossFitCoordinationError, match="exact v1"):
        parse_cross_fit_coordination_payload(unexpected)

    invalid = _payload()
    invalid["fold_number"] = 0
    with pytest.raises(CrossFitCoordinationError, match="positive"):
        parse_cross_fit_coordination_payload(invalid)


@pytest.mark.asyncio
async def test_handler_requires_evaluator_and_returns_database_hash() -> None:
    connection = AsyncMock()
    handler = CrossFitCoordinationTaskHandler(connection)
    handler._store.prepare_optimizer_pair = AsyncMock(  # type: ignore[method-assign]
        return_value=("PAIR_PREPARED", "a" * 64)
    )
    lease = _lease()

    assert await handler(lease) == "a" * 64
    handler._store.prepare_optimizer_pair.assert_awaited_once_with(  # type: ignore[attr-defined]
        lease.task_id, lease.lease_token
    )

    with pytest.raises(CrossFitCoordinationError, match="EVALUATOR"):
        await handler(_lease(executor=ExecutorKind.WORKER))


@pytest.mark.asyncio
async def test_handler_rejects_unknown_database_action() -> None:
    handler = CrossFitCoordinationTaskHandler(AsyncMock())
    handler._store.prepare_optimizer_pair = AsyncMock(  # type: ignore[method-assign]
        return_value=("WAITING", "b" * 64)
    )
    with pytest.raises(CrossFitCoordinationError, match="unexpected"):
        await handler(_lease())
