from __future__ import annotations

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from auto_trade.training.model_b_formal_search_finalization_task_handler import (
    ModelBFormalSearchFinalizationError,
    ModelBFormalSearchFinalizationTaskHandler,
    parse_model_b_formal_search_finalization_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def payload() -> dict[str, object]:
    return {
        "task_type": "MODEL_B_FINALIZE_FORMAL",
        "payload_version": 1,
        "formal_search_run_id": str(uuid4()),
    }


def lease(kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(), kind, uuid4(), 1,
        datetime.now(UTC) + timedelta(minutes=5), 0, payload()
    )


def test_payload_requires_exact_contract() -> None:
    value = payload()
    value["unexpected"] = True
    with pytest.raises(ModelBFormalSearchFinalizationError, match="exact v1"):
        parse_model_b_formal_search_finalization_payload(value)


def test_payload_requires_uuid() -> None:
    value = payload()
    value["formal_search_run_id"] = "invalid"
    with pytest.raises(ModelBFormalSearchFinalizationError, match="must be a UUID"):
        parse_model_b_formal_search_finalization_payload(value)


@pytest.mark.asyncio
async def test_handler_requires_evaluator() -> None:
    handler = ModelBFormalSearchFinalizationTaskHandler(AsyncMock())
    with pytest.raises(ModelBFormalSearchFinalizationError, match="EVALUATOR"):
        await handler(lease(ExecutorKind.WORKER))


@pytest.mark.asyncio
async def test_handler_returns_evidence_hash(monkeypatch: pytest.MonkeyPatch) -> None:
    handler = ModelBFormalSearchFinalizationTaskHandler(AsyncMock())
    expected = "a" * 64
    monkeypatch.setattr(handler._store, "finalize", AsyncMock(return_value=expected))
    assert await handler(lease()) == expected


@pytest.mark.asyncio
async def test_handler_rejects_invalid_hash(monkeypatch: pytest.MonkeyPatch) -> None:
    handler = ModelBFormalSearchFinalizationTaskHandler(AsyncMock())
    monkeypatch.setattr(handler._store, "finalize", AsyncMock(return_value="bad"))
    with pytest.raises(ModelBFormalSearchFinalizationError, match="invalid evidence"):
        await handler(lease())
