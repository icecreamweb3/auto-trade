from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.governance_repository import DatabaseOrchestratorStore
from auto_trade.training.orchestrator import ExecutorKind


def enqueue_arguments(payload: dict[str, object]) -> dict[str, object]:
    return {
        "experiment_id": uuid4(),
        "iteration_id": None,
        "optimizer_run_id": None,
        "parent_task_id": None,
        "task_type": "DATASET_BUILD",
        "executor_kind": ExecutorKind.WORKER,
        "idempotency_key": "a" * 64,
        "payload": payload,
    }


@pytest.mark.asyncio
async def test_enqueue_requires_explicit_positive_payload_version() -> None:
    connection = AsyncMock()
    store = DatabaseOrchestratorStore(connection)

    with pytest.raises(ValueError, match="payload_version"):
        await store.enqueue_task(**enqueue_arguments({}))
    connection.execute.assert_not_awaited()


@pytest.mark.asyncio
async def test_enqueue_rejects_mismatched_payload_task_type() -> None:
    connection = AsyncMock()
    store = DatabaseOrchestratorStore(connection)

    with pytest.raises(ValueError, match="does not match"):
        await store.enqueue_task(
            **enqueue_arguments(
                {"payload_version": 1, "task_type": "MODEL_A_EVALUATION"}
            )
        )
    connection.execute.assert_not_awaited()


@pytest.mark.asyncio
async def test_enqueue_rejects_wrong_executor_for_task_type() -> None:
    connection = AsyncMock()
    store = DatabaseOrchestratorStore(connection)
    arguments = enqueue_arguments({"payload_version": 1})
    arguments["executor_kind"] = ExecutorKind.EVALUATOR

    with pytest.raises(ValueError, match="requires executor WORKER"):
        await store.enqueue_task(**arguments)
    connection.execute.assert_not_awaited()


@pytest.mark.asyncio
async def test_enqueue_adds_authoritative_task_type_to_payload() -> None:
    expected_id = uuid4()
    result = MagicMock()
    result.scalar_one.return_value = expected_id
    connection = AsyncMock()
    connection.execute.return_value = result
    store = DatabaseOrchestratorStore(connection)

    actual_id = await store.enqueue_task(
        **enqueue_arguments({"payload_version": 1, "dataset_version_id": str(uuid4())})
    )

    assert actual_id == expected_id
    parameters = connection.execute.await_args.args[1]
    assert '"payload_version":1' in parameters["payload"]
    assert '"task_type":"DATASET_BUILD"' in parameters["payload"]


@pytest.mark.asyncio
async def test_advance_optimizer_runs_returns_only_ids_and_actions() -> None:
    run_id = uuid4()
    result = MagicMock()
    result.mappings.return_value.all.return_value = [
        {"optimizer_run_id": run_id, "action": "ASK_ENQUEUED"}
    ]
    connection = AsyncMock()
    connection.execute.return_value = result

    actions = await DatabaseOrchestratorStore(connection).advance_optimizer_runs()

    assert actions == ((run_id, "ASK_ENQUEUED"),)
    sql = str(connection.execute.await_args.args[0])
    assert "advance_training_optimizer_runs" in sql
    assert "objective" not in sql.lower()
