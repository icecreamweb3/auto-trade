from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.cross_fit_gate_repository import CrossFitGateContext
from auto_trade.training.cross_fit_gate_task_handler import (
    CrossFitGateError,
    CrossFitGateTaskHandler,
    parse_cross_fit_gate_payload,
)
from auto_trade.training.evaluator import FoldMetric, ModelBGateMetric
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _context(*, stressed: float = 0.2, include_model_b: bool = True) -> CrossFitGateContext:
    execution_id = uuid4()
    model_a = tuple(
        FoldMetric(fold, date(2026, 1, day), "BTCUSDT", 1.5, 1.0)
        for fold, day in enumerate(range(1, 5), start=1)
    )
    model_b = (
        tuple(
            ModelBGateMetric(date(2026, 1, day), "BTCUSDT", 0.3, stressed)
            for day in range(1, 5)
        )
        if include_model_b
        else ()
    )
    return CrossFitGateContext(
        execution_id,
        uuid4(),
        uuid4(),
        "a" * 64,
        "b" * 64 if include_model_b else "",
        uuid4(),
        uuid4(),
        Decimal("0.05"),
        Decimal("0.95"),
        4,
        4,
        200,
        7,
        Decimal("0.25"),
        Decimal("0.10"),
        Decimal("0.15"),
        Decimal(2),
        model_a,
        model_b,
    )


def _lease(context: CrossFitGateContext) -> TaskLease:
    return TaskLease(
        uuid4(),
        ExecutorKind.EVALUATOR,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {
            "task_type": "CROSS_FIT_EVALUATE_GATE",
            "payload_version": 1,
            "execution_id": str(context.execution_id),
        },
    )


def _handler(monkeypatch: pytest.MonkeyPatch, context: CrossFitGateContext):
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context)
    store.record_gate = AsyncMock(return_value=uuid4())
    store.apply_gate = AsyncMock(return_value="PASS")
    store.promote_corpus = AsyncMock(return_value=uuid4())
    monkeypatch.setattr(
        "auto_trade.training.cross_fit_gate_task_handler.DatabaseCrossFitGateStore",
        lambda _connection: store,
    )
    return CrossFitGateTaskHandler(MagicMock()), store


def test_gate_payload_is_fail_closed() -> None:
    with pytest.raises(CrossFitGateError, match="unexpected"):
        parse_cross_fit_gate_payload(
            {"task_type": "CROSS_FIT_EVALUATE_GATE", "payload_version": 1,
             "execution_id": str(uuid4()), "outcome": "PASS"}
        )


@pytest.mark.asyncio
async def test_passing_gate_records_applies_and_promotes(monkeypatch) -> None:
    context = _context()
    handler, store = _handler(monkeypatch, context)

    result_hash = await handler(_lease(context))

    assert len(result_hash) == 64
    store.record_gate.assert_awaited_once()
    store.apply_gate.assert_awaited_once()
    store.promote_corpus.assert_awaited_once_with(
        context.execution_id, context.execution_lease_token
    )


@pytest.mark.asyncio
async def test_failed_gate_never_promotes(monkeypatch) -> None:
    context = _context(stressed=0.0)
    handler, store = _handler(monkeypatch, context)
    store.apply_gate.return_value = "FAIL"

    await handler(_lease(context))

    store.promote_corpus.assert_not_awaited()


@pytest.mark.asyncio
async def test_gate_rejects_missing_temporary_model_b_evidence(monkeypatch) -> None:
    context = _context(include_model_b=False)
    handler, store = _handler(monkeypatch, context)

    with pytest.raises(CrossFitGateError, match="temporary Model-B"):
        await handler(_lease(context))
    store.record_gate.assert_not_awaited()
