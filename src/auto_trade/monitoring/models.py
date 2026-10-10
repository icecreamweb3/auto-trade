from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class HealthStatus(StrEnum):
    HEALTHY = "HEALTHY"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"
    UNKNOWN = "UNKNOWN"


class CoverageMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    key: str
    label: str
    status: HealthStatus
    latest_at: datetime | None = None
    age_seconds: float | None = None
    expected_symbols: int = 0
    actual_symbols: int = 0
    websocket_symbols: int | None = None
    completeness_percent: float = 0
    message: str


class QueueCounts(BaseModel):
    model_config = ConfigDict(frozen=True)

    pending: int = 0
    running: int = 0
    succeeded: int = 0
    failed: int = 0
    partial: int = 0
    paused: int = 0


class BackfillMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    status: HealthStatus
    counts: QueueCounts
    open_gaps: int = 0
    oldest_pending_seconds: float | None = None
    succeeded_last_hour: int = 0
    created_last_hour: int = 0
    finished_last_hour: int = 0
    queue_delta_last_hour: int = 0
    estimated_clear_seconds: float | None = None
    last_succeeded_at: datetime | None = None
    message: str


class RestUsageMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    status: HealthStatus
    request_rate_1m: int | None = None
    used_weight_1m: int | None = None
    limit_1m: int = 2400
    utilization_percent: float | None = None
    observed_at: datetime | None = None
    message: str


class NatsStreamMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    name: str
    messages: int
    bytes: int
    consumers: int


class NatsMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    status: HealthStatus
    connected: bool
    streams: tuple[NatsStreamMetric, ...] = ()
    message: str


class DatabaseTableMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    schema_name: str
    table_name: str
    is_hypertable: bool
    estimated_rows: int
    table_bytes: int
    index_bytes: int
    toast_bytes: int
    total_bytes: int
    chunk_count: int | None = None
    compression_enabled: bool | None = None
    columnstore_chunks: int = 0
    columnstore_before_bytes: int = 0
    columnstore_after_bytes: int = 0
    columnstore_saved_percent: float | None = None
    columnstore_policy_enabled: bool = False


class DatabaseMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    status: HealthStatus
    size_bytes: int
    size_display: str
    cache_hit_percent: float | None = None
    largest_tables: tuple[DatabaseTableMetric, ...] = ()
    message: str


class MonitoringSnapshot(BaseModel):
    model_config = ConfigDict(frozen=True)

    generated_at: datetime
    environment: str
    node_id: str
    overall_status: HealthStatus
    active_symbols: int
    coverage: tuple[CoverageMetric, ...]
    backfill: BackfillMetric
    rest_usage: RestUsageMetric
    nats: NatsMetric
    database: DatabaseMetric
    notices: tuple[str, ...] = Field(default_factory=tuple)
