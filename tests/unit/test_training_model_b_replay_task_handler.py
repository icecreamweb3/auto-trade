from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.model_b_replay_repository import ModelBReplayContext
from auto_trade.training.model_b_replay_task_handler import (
    ModelBReplayError,
    ModelBReplayTaskHandler,
    parse_model_b_replay_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease

SAMPLE_ID = "a" * 64
EPISODE_ID = "b" * 64
ENTRY_ID = "c" * 64


def payload(*sample_ids: str) -> dict[str, object]:
    return {
        "task_type": "MODEL_B_REPLAY",
        "payload_version": 1,
        "model_b_sample_ids": list(sample_ids or (SAMPLE_ID,)),
    }


def lease(
    value: dict[str, object], kind: ExecutorKind = ExecutorKind.MODEL_B
) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        value,
    )


def context(status: str = "RUNNING") -> ModelBReplayContext:
    return ModelBReplayContext(
        SAMPLE_ID,
        ENTRY_ID,
        EPISODE_ID,
        status,
        uuid4(),
        {
            "stop_loss_percent": 2,
            "take_profit_percent": 3,
            "trailing_activation_percent": 0,
            "trailing_distance_percent": 0,
            "max_holding_seconds": 600,
            "intrabar_conflict_policy": "WORST_CASE",
        },
        uuid4(),
        {"maker_rate": "0.0002", "taker_rate": "0.0004"},
        uuid4(),
        {
            "base_basis_points": 1,
            "notional_coefficient": 0,
            "reference_notional": 1000,
            "liquidity_coefficient": 0,
            "volatility_coefficient": 0,
            "maximum_basis_points": 10,
        },
        Decimal("1000"),
    )


def install_stores(monkeypatch, replay_context: ModelBReplayContext):
    task_store = MagicMock()
    task_store.load_context = AsyncMock(return_value=replay_context)
    task_store.load_terminal_decision_hash = AsyncMock(return_value="d" * 64)
    replay_service = MagicMock()
    replay_service.replay = AsyncMock()
    monkeypatch.setattr(
        "auto_trade.training.model_b_replay_task_handler.DatabaseModelBReplayTaskStore",
        lambda _connection: task_store,
    )
    monkeypatch.setattr(
        "auto_trade.training.model_b_replay_task_handler.DatabaseModelBWorkerStore",
        lambda _connection: MagicMock(),
    )
    monkeypatch.setattr(
        "auto_trade.training.model_b_replay_task_handler.FixedExitReplayService",
        lambda _store: replay_service,
    )
    return task_store, replay_service


def test_payload_requires_sorted_unique_sha256_ids() -> None:
    assert parse_model_b_replay_payload(payload()).model_b_sample_ids == (SAMPLE_ID,)
    with pytest.raises(ModelBReplayError, match="unique and sorted"):
        parse_model_b_replay_payload(payload("b" * 64, SAMPLE_ID))
    with pytest.raises(ModelBReplayError, match="SHA-256"):
        parse_model_b_replay_payload(payload("not-an-id"))


def test_payload_rejects_policy_bars_and_results() -> None:
    for forbidden in ("exit_policy", "bars", "future_outcome"):
        value = payload()
        value[forbidden] = {}
        with pytest.raises(ModelBReplayError, match="unexpected"):
            parse_model_b_replay_payload(value)


@pytest.mark.asyncio
async def test_running_episode_uses_only_trusted_context(monkeypatch) -> None:
    task_store, replay_service = install_stores(monkeypatch, context())

    result = await ModelBReplayTaskHandler(MagicMock())(lease(payload()))

    assert len(result) == 64
    task_store.load_context.assert_awaited_once()
    replay_service.replay.assert_awaited_once()
    replay_call = replay_service.replay.await_args.kwargs
    assert replay_call["model_b_sample_id"] == SAMPLE_ID
    assert replay_call["entry_event_id"] == ENTRY_ID
    assert replay_call["notional"] == Decimal("1000")
    assert replay_call["policy"].max_holding == timedelta(minutes=10)
    assert replay_call["fee_model"].entry_taker_rate == Decimal("0.0004")
    assert replay_call["slippage_model"].maximum_basis_points == Decimal("10")


@pytest.mark.asyncio
async def test_retry_reuses_committed_terminal_decision(monkeypatch) -> None:
    task_store, replay_service = install_stores(monkeypatch, context("DECIDED"))

    result = await ModelBReplayTaskHandler(MagicMock())(lease(payload()))

    assert len(result) == 64
    replay_service.replay.assert_not_awaited()
    task_store.load_terminal_decision_hash.assert_awaited_once_with(EPISODE_ID)


@pytest.mark.asyncio
async def test_handler_rejects_non_model_b_lease(monkeypatch) -> None:
    install_stores(monkeypatch, context())
    with pytest.raises(ModelBReplayError, match="MODEL_B executor"):
        await ModelBReplayTaskHandler(MagicMock())(
            lease(payload(), ExecutorKind.EVALUATOR)
        )
