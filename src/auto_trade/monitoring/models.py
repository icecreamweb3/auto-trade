from __future__ import annotations

from datetime import date, datetime
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


class WebSocketSyncMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    key: str
    label: str
    status: HealthStatus
    window_minutes: int = 60
    expected: int
    succeeded: int
    failed: int
    rest_fallback: int
    other_source: int
    missing: int
    success_percent: float


class BackfillTaskMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str
    data_type: str
    interval_seconds: int
    range_start: datetime
    range_end: datetime
    started_at: datetime | None = None
    attempts: int = 0


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
    pending_range_start: datetime | None = None
    pending_range_end: datetime | None = None
    running_jobs: tuple[BackfillTaskMetric, ...] = ()
    message: str


class RestUsageMetric(BaseModel):
    model_config = ConfigDict(frozen=True)

    status: HealthStatus
    request_rate_1m: int | None = None
    used_weight_1m: int | None = None
    limit_1m: int = 2400
    utilization_percent: float | None = None
    average_used_weight_1h: float | None = None
    average_utilization_percent_1h: float | None = None
    sampled_minutes_1h: int = 0
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
    websocket_sync: tuple[WebSocketSyncMetric, ...]
    backfill: BackfillMetric
    rest_usage: RestUsageMetric
    nats: NatsMetric
    database: DatabaseMetric
    notices: tuple[str, ...] = Field(default_factory=tuple)


class DailyRankingEntry(BaseModel):
    model_config = ConfigDict(frozen=True, from_attributes=True)

    utc_trade_date: date
    snapshot_at: datetime
    rank_no: int
    symbol: str
    price_change: float
    reference_open_price: float | None = None
    snapshot_price: float | None = None
    base_volume: float | None = None
    quote_volume: float | None = None
    amplitude: float | None = None
    period_high_price: float | None = None
    period_high_at: datetime | None = None
    period_low_price: float | None = None
    period_low_at: datetime | None = None
    open_interest_qty: float | None = None
    open_interest_value: float | None = None
    open_interest_status: str
    quality_status: str


class DailyRankingResult(BaseModel):
    model_config = ConfigDict(frozen=True)

    available_first_date: date | None = None
    available_last_date: date | None = None
    date_from: date | None = None
    date_to: date | None = None
    symbol: str | None = None
    rank_from: int
    rank_to: int
    page: int
    page_size: int
    total: int
    matching_days: int
    average_change: float | None = None
    maximum_change: float | None = None
    minimum_change: float | None = None
    items: tuple[DailyRankingEntry, ...] = ()
