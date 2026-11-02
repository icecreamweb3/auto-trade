from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from uuid import UUID


class GovernanceContractError(ValueError):
    """Raised when an orchestration or admission contract is incomplete."""


class TaskState(StrEnum):
    QUEUED = "QUEUED"
    LEASED = "LEASED"
    RUNNING = "RUNNING"
    PAUSED = "PAUSED"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"


class ExecutorKind(StrEnum):
    ORCHESTRATOR = "ORCHESTRATOR"
    WORKER = "WORKER"
    OPTIMIZER = "OPTIMIZER"
    EVALUATOR = "EVALUATOR"
    MODEL_B = "MODEL_B"


@dataclass(frozen=True, slots=True)
class ResourceLimits:
    version_id: UUID
    max_heavy_experiments: int
    db_workers_per_experiment: int
    pool_connections: int
    statement_timeout_seconds: int
    lock_timeout_seconds: int
    idle_in_transaction_session_timeout_seconds: int
    work_mem_bytes: int
    cpu_limit: int
    memory_bytes: int
    temp_disk_min_free_bytes: int
    max_candidate_count: int
    max_signal_count: int
    max_decision_row_count: int
    max_storage_bytes: int

    def __post_init__(self) -> None:
        for field_name in self.__dataclass_fields__:
            if field_name == "version_id":
                continue
            if getattr(self, field_name) <= 0:
                raise GovernanceContractError(f"{field_name} must be positive")


@dataclass(frozen=True, slots=True)
class ResourceSnapshot:
    active_heavy_experiments: int
    requested_db_workers: int
    requested_pool_connections: int
    requested_statement_seconds: int
    requested_work_mem_bytes: int
    requested_cpu: int
    requested_memory_bytes: int
    requested_temp_bytes: int
    available_temp_bytes: int
    candidate_count: int
    signal_count: int
    decision_row_count: int
    storage_bytes: int
    collection_checkpoint_fresh: bool
    live_trading_healthy: bool
    application_name_isolated: bool

    def __post_init__(self) -> None:
        numeric_fields = (
            "active_heavy_experiments",
            "requested_db_workers",
            "requested_pool_connections",
            "requested_statement_seconds",
            "requested_work_mem_bytes",
            "requested_cpu",
            "requested_memory_bytes",
            "requested_temp_bytes",
            "available_temp_bytes",
            "candidate_count",
            "signal_count",
            "decision_row_count",
            "storage_bytes",
        )
        if any(getattr(self, field_name) < 0 for field_name in numeric_fields):
            raise GovernanceContractError("resource snapshot counts cannot be negative")


@dataclass(frozen=True, slots=True)
class AdmissionDecision:
    admitted: bool
    rejection_codes: tuple[str, ...]


def evaluate_resource_admission(
    limits: ResourceLimits,
    snapshot: ResourceSnapshot,
) -> AdmissionDecision:
    checks: Mapping[str, bool] = {
        "HEAVY_EXPERIMENT_LIMIT": (
            snapshot.active_heavy_experiments < limits.max_heavy_experiments
        ),
        "DB_WORKER_LIMIT": snapshot.requested_db_workers <= limits.db_workers_per_experiment,
        "POOL_CONNECTION_LIMIT": (snapshot.requested_pool_connections <= limits.pool_connections),
        "STATEMENT_TIMEOUT_LIMIT": (
            snapshot.requested_statement_seconds <= limits.statement_timeout_seconds
        ),
        "WORK_MEM_LIMIT": snapshot.requested_work_mem_bytes <= limits.work_mem_bytes,
        "CPU_LIMIT": snapshot.requested_cpu <= limits.cpu_limit,
        "MEMORY_LIMIT": snapshot.requested_memory_bytes <= limits.memory_bytes,
        "TEMP_DISK_LIMIT": (
            snapshot.requested_temp_bytes <= snapshot.available_temp_bytes
            and snapshot.available_temp_bytes >= limits.temp_disk_min_free_bytes
        ),
        "CANDIDATE_LIMIT": snapshot.candidate_count <= limits.max_candidate_count,
        "SIGNAL_LIMIT": snapshot.signal_count <= limits.max_signal_count,
        "DECISION_ROW_LIMIT": snapshot.decision_row_count <= limits.max_decision_row_count,
        "STORAGE_LIMIT": snapshot.storage_bytes <= limits.max_storage_bytes,
        "COLLECTION_CHECKPOINT_STALE": snapshot.collection_checkpoint_fresh,
        "LIVE_TRADING_UNHEALTHY": snapshot.live_trading_healthy,
        "APPLICATION_NAME_NOT_ISOLATED": snapshot.application_name_isolated,
    }
    rejections = tuple(code for code, passed in checks.items() if not passed)
    return AdmissionDecision(not rejections, rejections)


@dataclass(frozen=True, slots=True)
class TaskLease:
    task_id: UUID
    executor_kind: ExecutorKind
    lease_token: UUID
    attempt_number: int
    lease_expires_at: datetime
    checkpoint_sequence: int
    payload: Mapping[str, object]

    def __post_init__(self) -> None:
        if self.attempt_number <= 0 or self.checkpoint_sequence < 0:
            raise GovernanceContractError("task lease counters are invalid")
        if not self.payload:
            raise GovernanceContractError("task payload cannot be empty")
