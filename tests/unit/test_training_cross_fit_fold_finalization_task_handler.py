from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from auto_trade.training.cross_fit_fold_finalization_task_handler import (
    CrossFitFoldFinalizationError,
    CrossFitFoldFinalizationTaskHandler,
    parse_cross_fit_fold_finalization_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _lease(*, executor_kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        executor_kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {
            "task_type": "CROSS_FIT_FINALIZE_FOLD",
            "payload_version": 1,
            "execution_id": str(uuid4()),
            "fold_number": 3,
        },
    )


def test_fold_finalization_payload_is_exact() -> None:
    lease = _lease()
    parsed = parse_cross_fit_fold_finalization_payload(lease.payload)
    assert parsed.fold_number == 3
    with pytest.raises(CrossFitFoldFinalizationError, match="exact v1"):
        parse_cross_fit_fold_finalization_payload({**lease.payload, "extra": True})


@pytest.mark.asyncio
async def test_fold_finalization_requires_evaluator_and_hash() -> None:
    handler = CrossFitFoldFinalizationTaskHandler(AsyncMock())
    with pytest.raises(CrossFitFoldFinalizationError, match="EVALUATOR"):
        await handler(_lease(executor_kind=ExecutorKind.WORKER))

    handler._store.finalize_fold = AsyncMock(return_value="a" * 64)  # type: ignore[method-assign]
    assert await handler(_lease()) == "a" * 64

    handler._store.finalize_fold = AsyncMock(return_value="invalid")  # type: ignore[method-assign]
    with pytest.raises(CrossFitFoldFinalizationError, match="invalid evidence"):
        await handler(_lease())
