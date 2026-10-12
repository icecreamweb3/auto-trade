from __future__ import annotations

from datetime import UTC, datetime
from typing import Protocol

from auto_trade.config import Settings
from auto_trade.monitoring.models import (
    BackfillMetric,
    BackfillTaskMetric,
    CoverageMetric,
    DatabaseMetric,
    DatabaseTableMetric,
    HealthStatus,
    MonitoringSnapshot,
    NatsMetric,
    QueueCounts,
    RestUsageMetric,
)
from auto_trade.monitoring.repository import (
    CoverageRow,
    DatabaseSnapshot,
    MonitoringRepository,
)

STATUS_PRIORITY = {
    HealthStatus.HEALTHY: 0,
    HealthStatus.UNKNOWN: 1,
    HealthStatus.WARNING: 2,
    HealthStatus.CRITICAL: 3,
}

SERIES = {
    "trade_60": ("Trade 1m", 180.0, 300.0),
    "mark_60": ("Mark 1m", 180.0, 300.0),
    "trade_300": ("Trade 5m", 480.0, 720.0),
    "ticker_60": ("分钟Ticker", 120.0, 300.0),
    "open_interest_300": ("Open Interest 5m", 600.0, 900.0),
}


class NatsProbeProtocol(Protocol):
    async def snapshot(self) -> NatsMetric: ...


def coverage_metric(
    key: str,
    row: CoverageRow | None,
    expected_symbols: int,
) -> CoverageMetric:
    label, healthy_age, warning_age = SERIES[key]
    if row is None or row.latest_at is None or row.age_seconds is None:
        return CoverageMetric(
            key=key,
            label=label,
            status=HealthStatus.UNKNOWN,
            expected_symbols=expected_symbols,
            message="尚无数据",
        )
    ratio = row.actual_symbols / expected_symbols if expected_symbols else 0
    completeness = round(ratio * 100, 2)
    if ratio >= 0.99 and row.age_seconds <= healthy_age:
        status = HealthStatus.HEALTHY
        message = "覆盖率与新鲜度正常"
    elif ratio >= 0.95 and row.age_seconds <= warning_age:
        status = HealthStatus.WARNING
        message = "数据仍在预热或存在少量缺失"
    else:
        status = HealthStatus.CRITICAL
        message = "覆盖率不足或数据延迟过高"
    return CoverageMetric(
        key=key,
        label=label,
        status=status,
        latest_at=row.latest_at,
        age_seconds=round(row.age_seconds, 2),
        expected_symbols=expected_symbols,
        actual_symbols=row.actual_symbols,
        websocket_symbols=row.websocket_symbols,
        completeness_percent=completeness,
        message=message,
    )


def backfill_metric(snapshot: DatabaseSnapshot) -> BackfillMetric:
    row = snapshot.backfill
    values = row.counts
    counts = QueueCounts(
        pending=values.get("PENDING", 0),
        running=values.get("RUNNING", 0),
        succeeded=values.get("SUCCEEDED", 0),
        failed=values.get("FAILED", 0),
        partial=values.get("PARTIAL", 0),
        paused=values.get("PAUSED", 0),
    )
    oldest = row.oldest_pending_seconds
    if counts.failed >= 100 and oldest is not None and oldest >= 21600:
        status = HealthStatus.CRITICAL
        message = "失败任务达到100个且最老等待超过6小时"
    elif counts.failed >= 100:
        status = HealthStatus.CRITICAL
        message = "失败任务达到100个"
    elif oldest is not None and oldest >= 21600:
        status = HealthStatus.CRITICAL
        message = "最老等待任务超过6小时"
    elif counts.failed > 0 and oldest is not None and oldest >= 3600:
        status = HealthStatus.WARNING
        message = "存在失败任务且最老等待超过1小时"
    elif counts.failed > 0:
        status = HealthStatus.WARNING
        message = "存在失败任务"
    elif oldest is not None and oldest >= 3600:
        status = HealthStatus.WARNING
        message = "最老等待任务超过1小时"
    else:
        status = HealthStatus.HEALTHY
        message = "回补队列正常"
    estimated_clear_seconds: float | None
    if counts.pending == 0:
        estimated_clear_seconds = 0
    elif row.succeeded_last_hour > 0:
        estimated_clear_seconds = counts.pending / row.succeeded_last_hour * 3600
    else:
        estimated_clear_seconds = None
    return BackfillMetric(
        status=status,
        counts=counts,
        open_gaps=row.open_gaps,
        oldest_pending_seconds=(round(oldest, 2) if oldest is not None else None),
        succeeded_last_hour=row.succeeded_last_hour,
        created_last_hour=row.created_last_hour,
        finished_last_hour=row.finished_last_hour,
        queue_delta_last_hour=row.created_last_hour - row.finished_last_hour,
        estimated_clear_seconds=(
            round(estimated_clear_seconds, 2)
            if estimated_clear_seconds is not None
            else None
        ),
        last_succeeded_at=row.last_succeeded_at,
        pending_range_start=row.pending_range_start,
        pending_range_end=row.pending_range_end,
        running_jobs=tuple(
            BackfillTaskMetric(
                symbol=job.symbol,
                data_type=job.data_type,
                interval_seconds=job.interval_seconds,
                range_start=job.range_start,
                range_end=job.range_end,
                started_at=job.started_at,
                attempts=job.attempts,
            )
            for job in row.running_jobs
        ),
        message=message,
    )


def rest_usage_metric(snapshot: DatabaseSnapshot) -> RestUsageMetric:
    row = snapshot.rest_usage
    if row.used_weight_1m is None:
        return RestUsageMetric(
            status=HealthStatus.UNKNOWN,
            message="最近10分钟没有REST权重样本",
        )
    utilization = row.used_weight_1m / 2400 * 100
    if row.used_weight_1m >= 1920:
        status = HealthStatus.CRITICAL
        message = "已达到系统主动冷却阈值"
    elif row.used_weight_1m >= 1440:
        status = HealthStatus.WARNING
        message = "REST权重超过60%"
    else:
        status = HealthStatus.HEALTHY
        message = "REST权重安全"
    return RestUsageMetric(
        status=status,
        request_rate_1m=row.request_rate_1m,
        used_weight_1m=row.used_weight_1m,
        utilization_percent=round(utilization, 2),
        observed_at=row.observed_at,
        message=message,
    )


def database_metric(snapshot: DatabaseSnapshot) -> DatabaseMetric:
    cache_hit = snapshot.cache_hit_percent
    if cache_hit is None:
        status = HealthStatus.UNKNOWN
        message = "缓存命中率尚无统计"
    elif cache_hit < 95:
        status = HealthStatus.CRITICAL
        message = "数据库缓存命中率低于95%"
    elif cache_hit < 99:
        status = HealthStatus.WARNING
        message = "数据库缓存命中率低于99%"
    else:
        status = HealthStatus.HEALTHY
        message = "数据库连接与缓存命中率正常"
    return DatabaseMetric(
        status=status,
        size_bytes=snapshot.database_size_bytes,
        size_display=snapshot.database_size_display,
        cache_hit_percent=round(cache_hit, 2) if cache_hit is not None else None,
        largest_tables=tuple(
            DatabaseTableMetric(
                schema_name=row.schema_name,
                table_name=row.table_name,
                is_hypertable=row.is_hypertable,
                estimated_rows=row.estimated_rows,
                table_bytes=row.table_bytes,
                index_bytes=row.index_bytes,
                toast_bytes=row.toast_bytes,
                total_bytes=row.total_bytes,
                chunk_count=row.chunk_count,
                compression_enabled=row.compression_enabled,
                columnstore_chunks=row.columnstore_chunks,
                columnstore_before_bytes=row.columnstore_before_bytes,
                columnstore_after_bytes=row.columnstore_after_bytes,
                columnstore_saved_percent=(
                    round(
                        100
                        * (
                            row.columnstore_before_bytes
                            - row.columnstore_after_bytes
                        )
                        / row.columnstore_before_bytes,
                        2,
                    )
                    if row.columnstore_before_bytes > 0
                    else None
                ),
                columnstore_policy_enabled=row.columnstore_policy_enabled,
            )
            for row in snapshot.largest_tables
        ),
        message=message,
    )


class MonitoringService:
    def __init__(
        self,
        repository: MonitoringRepository,
        settings: Settings,
        nats_probe: NatsProbeProtocol,
    ) -> None:
        self._repository = repository
        self._settings = settings
        self._nats_probe = nats_probe

    async def snapshot(self) -> MonitoringSnapshot:
        database = await self._repository.snapshot()
        nats_status = await self._nats_probe.snapshot()
        by_key = {row.key: row for row in database.coverage}
        coverage = tuple(
            coverage_metric(key, by_key.get(key), database.active_symbols)
            for key in SERIES
        )
        backfill = backfill_metric(database)
        rest_usage = rest_usage_metric(database)
        db_metric = database_metric(database)
        statuses = [
            *(item.status for item in coverage),
            backfill.status,
            rest_usage.status,
            nats_status.status,
            db_metric.status,
        ]
        overall = max(statuses, key=STATUS_PRIORITY.__getitem__)
        notices: list[str] = []
        if database.active_symbols == 0:
            notices.append("当前没有TRADING状态的USDT永续合约")
        if any(item.status is HealthStatus.UNKNOWN for item in coverage):
            notices.append("新环境启动后需要等待首个完整1m/5m周期")
        return MonitoringSnapshot(
            generated_at=datetime.now(UTC),
            environment=self._settings.environment,
            node_id=self._settings.node_id,
            overall_status=overall,
            active_symbols=database.active_symbols,
            coverage=coverage,
            backfill=backfill,
            rest_usage=rest_usage,
            nats=nats_status,
            database=db_metric,
            notices=tuple(notices),
        )
