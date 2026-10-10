from datetime import UTC, datetime, timedelta

from auto_trade.monitoring.models import HealthStatus
from auto_trade.monitoring.repository import (
    BackfillRows,
    CoverageRow,
    DatabaseSnapshot,
    RestUsageRow,
)
from auto_trade.monitoring.service import (
    STATUS_PRIORITY,
    backfill_metric,
    coverage_metric,
    rest_usage_metric,
)


def test_unknown_status_is_worse_than_healthy() -> None:
    assert STATUS_PRIORITY[HealthStatus.UNKNOWN] > STATUS_PRIORITY[HealthStatus.HEALTHY]


def database_snapshot(
    *,
    backfill: BackfillRows | None = None,
    rest_usage: RestUsageRow | None = None,
) -> DatabaseSnapshot:
    return DatabaseSnapshot(
        active_symbols=525,
        coverage=(),
        backfill=backfill or BackfillRows({}, 0, None),
        rest_usage=rest_usage or RestUsageRow(None, None, None),
        database_size_bytes=1024,
        database_size_display="1024 bytes",
    )


def test_complete_fresh_coverage_is_healthy() -> None:
    row = CoverageRow(
        key="trade_60",
        latest_at=datetime.now(UTC) - timedelta(seconds=70),
        age_seconds=70,
        actual_symbols=525,
        websocket_symbols=525,
    )

    metric = coverage_metric("trade_60", row, 525)

    assert metric.status is HealthStatus.HEALTHY
    assert metric.completeness_percent == 100


def test_partial_warmup_coverage_is_warning() -> None:
    row = CoverageRow(
        key="ticker_60",
        latest_at=datetime.now(UTC) - timedelta(seconds=80),
        age_seconds=80,
        actual_symbols=510,
        websocket_symbols=510,
    )

    metric = coverage_metric("ticker_60", row, 525)

    assert metric.status is HealthStatus.WARNING
    assert metric.message == "数据仍在预热或存在少量缺失"


def test_missing_or_stale_coverage_is_critical() -> None:
    row = CoverageRow(
        key="mark_60",
        latest_at=datetime.now(UTC) - timedelta(minutes=20),
        age_seconds=1200,
        actual_symbols=525,
        websocket_symbols=525,
    )

    metric = coverage_metric("mark_60", row, 525)

    assert metric.status is HealthStatus.CRITICAL


def test_backfill_oldest_pending_controls_health() -> None:
    warning = backfill_metric(
        database_snapshot(backfill=BackfillRows({"PENDING": 5}, 5, 3601))
    )
    critical = backfill_metric(
        database_snapshot(backfill=BackfillRows({"FAILED": 100}, 100, None))
    )

    assert warning.status is HealthStatus.WARNING
    assert warning.message == "最老等待任务超过1小时"
    assert critical.status is HealthStatus.CRITICAL
    assert critical.message == "失败任务达到100个"


def test_backfill_reports_recent_throughput_and_estimated_clear_time() -> None:
    metric = backfill_metric(
        database_snapshot(
            backfill=BackfillRows(
                {"PENDING": 240, "SUCCEEDED": 1000},
                240,
                1800,
                succeeded_last_hour=120,
                created_last_hour=20,
                finished_last_hour=120,
                last_succeeded_at=datetime.now(UTC),
            )
        )
    )

    assert metric.queue_delta_last_hour == -100
    assert metric.estimated_clear_seconds == 7200
    assert metric.succeeded_last_hour == 120


def test_backfill_clear_time_is_unknown_without_recent_success() -> None:
    metric = backfill_metric(
        database_snapshot(backfill=BackfillRows({"PENDING": 5}, 5, 30))
    )

    assert metric.estimated_clear_seconds is None


def test_rest_usage_uses_2400_weight_limit() -> None:
    healthy = rest_usage_metric(
        database_snapshot(
            rest_usage=RestUsageRow(525, 600, datetime.now(UTC))
        )
    )
    critical = rest_usage_metric(
        database_snapshot(
            rest_usage=RestUsageRow(1000, 1920, datetime.now(UTC))
        )
    )

    assert healthy.status is HealthStatus.HEALTHY
    assert healthy.utilization_percent == 25
    assert critical.status is HealthStatus.CRITICAL
