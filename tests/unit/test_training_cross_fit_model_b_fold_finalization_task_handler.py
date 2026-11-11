from __future__ import annotations

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from auto_trade.training.cross_fit_model_b_fold_finalization_task_handler import (
    CrossFitModelBFoldFinalizationError,
    CrossFitModelBFoldFinalizationTaskHandler,
    parse_cross_fit_model_b_fold_finalization_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def payload() -> dict[str, object]:
    return {
        "task_type": "CROSS_FIT_MODEL_B_FINALIZE_FOLD",
        "payload_version": 1,
        "execution_id": str(uuid4()),
        "fold_number": 4,
    }


def lease(kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        payload(),
    )


def test_payload_requires_exact_contract() -> None:
    value = payload()
    value["unexpected"] = True
    with pytest.raises(CrossFitModelBFoldFinalizationError, match="exact v1"):
        parse_cross_fit_model_b_fold_finalization_payload(value)


@pytest.mark.asyncio
async def test_handler_requires_evaluator() -> None:
    handler = CrossFitModelBFoldFinalizationTaskHandler(AsyncMock())
    with pytest.raises(CrossFitModelBFoldFinalizationError, match="EVALUATOR"):
        await handler(lease(ExecutorKind.WORKER))


@pytest.mark.asyncio
async def test_handler_returns_evidence_hash(monkeypatch: pytest.MonkeyPatch) -> None:
    handler = CrossFitModelBFoldFinalizationTaskHandler(AsyncMock())
    expected = "a" * 64
    monkeypatch.setattr(
        handler._store,
        "finalize_model_b_fold",
        AsyncMock(return_value=expected),
    )

    assert await handler(lease()) == expected


@pytest.mark.asyncio
async def test_handler_rejects_invalid_hash(monkeypatch: pytest.MonkeyPatch) -> None:
    handler = CrossFitModelBFoldFinalizationTaskHandler(AsyncMock())
    monkeypatch.setattr(
        handler._store,
        "finalize_model_b_fold",
        AsyncMock(return_value="bad"),
    )

    with pytest.raises(CrossFitModelBFoldFinalizationError, match="invalid evidence"):
        await handler(lease())
