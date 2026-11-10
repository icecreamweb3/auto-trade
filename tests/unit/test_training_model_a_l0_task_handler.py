from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.model_a_l0_task_handler import (
    ModelAL0AggregationError,
    ModelAL0AggregationTaskHandler,
    validate_model_a_l0_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _lease(kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": "MODEL_A_L0_AGGREGATION", "payload_version": 1},
    )


def test_l0_payload_is_exact() -> None:
    validate_model_a_l0_payload(_lease().payload)
    with pytest.raises(ModelAL0AggregationError, match="exact"):
        validate_model_a_l0_payload(
            {
                "task_type": "MODEL_A_L0_AGGREGATION",
                "payload_version": 1,
                "objective": 99,
            }
        )


async def test_l0_handler_uses_only_leased_database_capability() -> None:
    connection = MagicMock()
    timeout_result = MagicMock()
    timeout_result.scalar_one.return_value = 14_400
    universe_result = MagicMock()
    universe_result.scalar_one.return_value = uuid4()
    finalization_timeout_result = MagicMock()
    finalization_timeout_result.scalar_one.return_value = 14_000
    evidence_result = MagicMock()
    evidence_result.scalar_one.return_value = "a" * 64
    connection.execute = AsyncMock(
        side_effect=[
            timeout_result,
            universe_result,
            finalization_timeout_result,
            evidence_result,
        ]
    )

    assert await ModelAL0AggregationTaskHandler(connection)(_lease()) == "a" * 64
    assert connection.execute.await_count == 4
    for call in connection.execute.await_args_list:
        assert set(call.args[1]) == {"task_id", "lease_token"}


async def test_l0_handler_logs_governed_progress(caplog: pytest.LogCaptureFixture) -> None:
    connection = MagicMock()
    timeout_result = MagicMock()
    timeout_result.scalar_one.return_value = 14_400
    universe_result = MagicMock()
    universe_result.scalar_one.return_value = uuid4()
    finalization_timeout_result = MagicMock()
    finalization_timeout_result.scalar_one.return_value = 14_000
    evidence_result = MagicMock()
    evidence_result.scalar_one.return_value = "a" * 64
    connection.execute = AsyncMock(
        side_effect=[
            timeout_result,
            universe_result,
            finalization_timeout_result,
            evidence_result,
        ]
    )

    with caplog.at_level("INFO"):
        await ModelAL0AggregationTaskHandler(connection)(_lease())

    assert "stage=TIMEOUT_CONFIGURED" in caplog.text
    assert "stage=OPPORTUNITY_UNIVERSE_READY" in caplog.text
    assert "stage=FINALIZATION_TIMEOUT_CONFIGURED" in caplog.text
    assert "stage=EVIDENCE_RECORDED" in caplog.text


async def test_l0_handler_rejects_non_evaluator() -> None:
    with pytest.raises(ModelAL0AggregationError, match="EVALUATOR"):
        await ModelAL0AggregationTaskHandler(MagicMock())(_lease(ExecutorKind.WORKER))
