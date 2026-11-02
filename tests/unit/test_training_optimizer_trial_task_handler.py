from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.optimizer_trial_repository import OptimizerTrialContext
from auto_trade.training.optimizer_trial_task_handler import (
    OptimizerTrialError,
    OptimizerTrialTaskHandler,
    parse_optimizer_trial_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def lease(kind: ExecutorKind = ExecutorKind.OPTIMIZER) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": "OPTIMIZER_TRIAL", "payload_version": 1, "trial_number": 3},
    )


def context(
    *, candidate: dict[str, object] | None = None, objective: Decimal | None = Decimal("1.5")
) -> OptimizerTrialContext:
    return OptimizerTrialContext(
        uuid4(),
        uuid4(),
        3,
        candidate or {"lookback": 5, "threshold": 0.7},
        "a" * 64,
        uuid4(),
        "44.0.1",
        {
            "parameters": {
                "lookback": {
                    "kind": "numeric",
                    "minimum": 1,
                    "maximum": 20,
                    "integer": True,
                },
                "threshold": [0, 1],
            }
        },
        objective,
        None if objective is None else "b" * 64,
    )


def test_payload_rejects_candidate_and_result_injection() -> None:
    value = dict(lease().payload)
    value["candidate"] = {"threshold": 0.5}
    with pytest.raises(OptimizerTrialError, match="unexpected"):
        parse_optimizer_trial_payload(value)


@pytest.mark.asyncio
async def test_complete_trial_records_only_train_objective(monkeypatch) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context())
    store.record_result = AsyncMock()
    monkeypatch.setattr(
        "auto_trade.training.optimizer_trial_task_handler.DatabaseOptimizerTrialStore",
        lambda _connection: store,
    )

    result = await OptimizerTrialTaskHandler(MagicMock())(lease())

    assert len(result) == 64
    call = store.record_result.await_args.kwargs
    assert call["trial_state"] == "COMPLETE"
    assert call["train_objective"] == Decimal("1.5")
    assert call["train_evidence_hash"] == "b" * 64
    assert call["rejection_codes"] == ()


@pytest.mark.asyncio
async def test_invalid_candidate_is_told_fail_without_objective(monkeypatch) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(
        return_value=context(candidate={"lookback": 5, "threshold": 9.0})
    )
    store.record_result = AsyncMock()
    monkeypatch.setattr(
        "auto_trade.training.optimizer_trial_task_handler.DatabaseOptimizerTrialStore",
        lambda _connection: store,
    )

    await OptimizerTrialTaskHandler(MagicMock())(lease())

    call = store.record_result.await_args.kwargs
    assert call["trial_state"] == "FAIL"
    assert call["train_objective"] is None
    assert call["train_evidence_hash"] is None
    assert call["rejection_codes"] == ("PARAMETER_OUT_OF_RANGE",)


@pytest.mark.asyncio
async def test_valid_candidate_without_train_objective_fails_closed(monkeypatch) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context(objective=None))
    store.record_result = AsyncMock()
    monkeypatch.setattr(
        "auto_trade.training.optimizer_trial_task_handler.DatabaseOptimizerTrialStore",
        lambda _connection: store,
    )

    with pytest.raises(OptimizerTrialError, match="no completed TRAIN objective"):
        await OptimizerTrialTaskHandler(MagicMock())(lease())
    store.record_result.assert_not_awaited()


@pytest.mark.asyncio
async def test_handler_requires_optimizer_executor(monkeypatch) -> None:
    monkeypatch.setattr(
        "auto_trade.training.optimizer_trial_task_handler.DatabaseOptimizerTrialStore",
        lambda _connection: MagicMock(),
    )
    with pytest.raises(OptimizerTrialError, match="OPTIMIZER executor"):
        await OptimizerTrialTaskHandler(MagicMock())(lease(ExecutorKind.WORKER))
