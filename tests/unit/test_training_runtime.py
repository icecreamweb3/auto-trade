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
