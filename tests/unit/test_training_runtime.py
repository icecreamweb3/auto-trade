from unittest.mock import MagicMock

import pytest

from auto_trade.infrastructure.database import create_database_engine
from auto_trade.training.orchestrator import ExecutorKind
from auto_trade.training.runtime import SERVICE_ROLES


def test_runtime_roles_map_only_execution_services_to_task_kinds() -> None:
    assert SERVICE_ROLES["orchestrator"].executor_kind is None
    assert SERVICE_ROLES["worker"].executor_kind is ExecutorKind.WORKER
    assert SERVICE_ROLES["optimizer"].executor_kind is ExecutorKind.OPTIMIZER
    assert SERVICE_ROLES["evaluator"].executor_kind is ExecutorKind.EVALUATOR
    assert SERVICE_ROLES["model-b"].executor_kind is ExecutorKind.MODEL_B
    assert SERVICE_ROLES["test-executor"].executor_kind is None


def test_runtime_roles_use_isolated_schemas() -> None:
    assert SERVICE_ROLES["weak-holdout"].schema == "strategy_training_weak_holdout"
    assert SERVICE_ROLES["test-auditor"].schema == "strategy_training_test"


def test_database_engine_honors_minimum_pool_size(monkeypatch: pytest.MonkeyPatch) -> None:
    create_async_engine = MagicMock(return_value=MagicMock())
    monkeypatch.setattr(
        "auto_trade.infrastructure.database.create_async_engine", create_async_engine
    )
    settings = MagicMock(
        database_dsn="postgresql+asyncpg://fixture",
        postgres_pool_size=1,
        postgres_max_overflow=0,
        database_application_name="training-worker-test",
    )

    create_database_engine(settings, minimum_pool_size=2)

    assert create_async_engine.call_args.kwargs["pool_size"] == 2
