from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.model_b_candidate_preparation_repository import (
    ModelBCandidatePreparationContext,
)
from auto_trade.training.model_b_candidate_preparation_task_handler import (
    ModelBCandidatePreparationError,
    ModelBCandidatePreparationTaskHandler,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _search_config() -> dict[str, object]:
    return {
        "model_family": "RULE_BASED_EXIT_V2",
        "policy_templates": {
            "FOUR_STAGE_SCALED_REMAINING_V1": {
                "base_partial_trigger_profit_percents": [10, 15, 25, 35],
                "base_stop_locked_profit_percents": [1, 5, 15, 25],
                "base_high_water_trailing_activation_percent": 25,
                "base_high_water_max_drawdown_percent": 10,
                "minimum_remaining_fraction": 0.30,
            }
        },
    }


def _candidate() -> dict[str, object]:
    return {
        "exit_policy_template": "FOUR_STAGE_SCALED_REMAINING_V1",
        "initial_stop_loss_percent": 5.0,
        "max_holding_seconds": 86400,
        "shared_close_fraction": 0.2,
        "trigger_scale": 1.0,
    }


def _context(existing_hash: str | None = None) -> ModelBCandidatePreparationContext:
    return ModelBCandidatePreparationContext(
        uuid4(),
        uuid4(),
        uuid4(),
        _search_config(),
        uuid4(),
        {"model_family": "RULE_BASED_EXIT_V2"},
        _candidate(),
        "a" * 64,
        True,
        ("b" * 64, "c" * 64),
        existing_hash,
    )


def _lease() -> TaskLease:
    return TaskLease(
        uuid4(),
        ExecutorKind.EVALUATOR,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": "MODEL_B_PREPARE_CANDIDATE", "payload_version": 1},
    )


def _handler(monkeypatch: pytest.MonkeyPatch, context):
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context)
    store.record_compiled_policy = AsyncMock(return_value="d" * 64)
    store.create_episode = AsyncMock()
    store.finalize = AsyncMock(return_value="e" * 64)
    monkeypatch.setattr(
        "auto_trade.training.model_b_candidate_preparation_task_handler."
        "DatabaseModelBCandidatePreparationStore",
        lambda _connection: store,
    )
    return ModelBCandidatePreparationTaskHandler(MagicMock()), store


@pytest.mark.asyncio
async def test_compiles_one_policy_and_prepares_every_frozen_input(monkeypatch) -> None:
    context = _context()
    handler, store = _handler(monkeypatch, context)

    result = await handler(_lease())

    assert result == "e" * 64
    stored = store.record_compiled_policy.await_args.kwargs
    assert stored["effective_exit_rule_config"]["model_family"] == "RULE_BASED_EXIT_V2"
    assert stored["remaining_position_fraction"] > 0
    assert [call.kwargs["entry_event_id"] for call in store.create_episode.await_args_list] == [
        "b" * 64,
        "c" * 64,
    ]
    store.finalize.assert_awaited_once()


@pytest.mark.asyncio
async def test_rejects_existing_policy_hash_mismatch(monkeypatch) -> None:
    handler, store = _handler(monkeypatch, _context(existing_hash="f" * 64))

    with pytest.raises(ModelBCandidatePreparationError, match="differs"):
        await handler(_lease())

    store.create_episode.assert_not_awaited()
    store.finalize.assert_not_awaited()


@pytest.mark.asyncio
async def test_invalid_remaining_fraction_never_persists(monkeypatch) -> None:
    context = _context()
    candidate = dict(context.candidate_parameters)
    candidate["shared_close_fraction"] = 0.3
    context = ModelBCandidatePreparationContext(
        context.model_b_iteration_id,
        context.optimizer_run_id,
        context.search_space_config_version_id,
        context.search_space_config,
        context.base_exit_rule_version_id,
        context.base_exit_rule_config,
        candidate,
        context.candidate_content_hash,
        context.temporary_only,
        context.input_entry_event_ids,
        None,
    )
    handler, store = _handler(monkeypatch, context)

    with pytest.raises(ModelBCandidatePreparationError, match="MINIMUM_REMAINING"):
        await handler(_lease())

    store.record_compiled_policy.assert_not_awaited()
