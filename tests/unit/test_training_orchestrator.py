from __future__ import annotations

from datetime import UTC, datetime
from uuid import uuid4

import pytest

from auto_trade.training.orchestrator import (
    ExecutorKind,
    GovernanceContractError,
    ResourceLimits,
    ResourceSnapshot,
    TaskLease,
    evaluate_resource_admission,
)


def _limits() -> ResourceLimits:
    return ResourceLimits(uuid4(), 1, 2, 6, 900, 2, 60, 64, 4, 8_000, 1_000, 100, 100, 1000, 10_000)


def _snapshot(**overrides: object) -> ResourceSnapshot:
    values: dict[str, object] = {
        "active_heavy_experiments": 0,
        "requested_db_workers": 2,
        "requested_pool_connections": 4,
        "requested_statement_seconds": 600,
        "requested_work_mem_bytes": 32,
        "requested_cpu": 2,
        "requested_memory_bytes": 4_000,
        "requested_temp_bytes": 100,
        "available_temp_bytes": 2_000,
        "candidate_count": 10,
        "signal_count": 20,
        "decision_row_count": 30,
        "storage_bytes": 1_000,
        "collection_checkpoint_fresh": True,
        "live_trading_healthy": True,
        "application_name_isolated": True,
    }
    values.update(overrides)
    return ResourceSnapshot(**values)  # type: ignore[arg-type]


def test_resource_admission_passes_only_when_every_gate_passes() -> None:
    decision = evaluate_resource_admission(_limits(), _snapshot())
    assert decision.admitted
    assert decision.rejection_codes == ()


def test_resource_admission_reports_all_blocking_gates() -> None:
    decision = evaluate_resource_admission(
        _limits(),
        _snapshot(
            active_heavy_experiments=1,
            requested_db_workers=3,
            live_trading_healthy=False,
            application_name_isolated=False,
        ),
    )
    assert not decision.admitted
    assert decision.rejection_codes == (
        "HEAVY_EXPERIMENT_LIMIT",
        "DB_WORKER_LIMIT",
        "LIVE_TRADING_UNHEALTHY",
        "APPLICATION_NAME_NOT_ISOLATED",
    )


def test_task_lease_rejects_empty_payload() -> None:
    with pytest.raises(GovernanceContractError, match="payload"):
        TaskLease(uuid4(), ExecutorKind.WORKER, uuid4(), 1, datetime.now(UTC), 0, {})
