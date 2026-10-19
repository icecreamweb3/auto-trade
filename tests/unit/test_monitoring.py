import asyncio
from datetime import UTC, date, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from auto_trade.monitoring.models import (
    DailyRankingEntry,
    HealthStatus,
    KlinePoint,
    NatsMetric,
)
from auto_trade.monitoring.repository import (
    BackfillRows,
    BackfillTaskRow,
    CoverageRow,
    DatabaseSnapshot,
    KlinePointRow,
    MonitoringRepository,
    RankingEntryRow,
    RestUsageRow,
    TableSizeRow,
    WebSocketSyncRow,
    websocket_sync_range_end,
)
from auto_trade.monitoring.service import (
    STATUS_PRIORITY,
    MonitoringService,
    backfill_metric,
    coverage_metric,
    database_metric,
    rest_usage_metric,
    websocket_sync_metric,
)


def test_websocket_sync_range_waits_for_safety_delay() -> None:
    before_safe_boundary = datetime(2026, 10, 14, 9, 43, 29, tzinfo=UTC)
    after_safe_boundary = datetime(2026, 10, 14, 9, 43, 30, tzinfo=UTC)

    assert websocket_sync_range_end(before_safe_boundary, 60, 30) == datetime(
        2026, 10, 14, 9, 42, tzinfo=UTC
    )
    assert websocket_sync_range_end(after_safe_boundary, 60, 30) == datetime(
        2026, 10, 14, 9, 43, tzinfo=UTC
    )


async def test_kline_coverage_uses_bounded_latest_index_lookup() -> None:
    connection = MagicMock()
    result = MagicMock()
    result.mappings.return_value.all.return_value = []
    connection.execute = AsyncMock(return_value=result)
    repository = MonitoringRepository(MagicMock())

    await repository._kline_coverage(connection)

    statement = str(connection.execute.await_args.args[0])
    assert "ORDER BY k.open_time DESC" in statement
    assert statement.count("k.open_time >= now() - interval '1 day'") == 2
    assert "max(open_time)" not in statement


async def test_websocket_sync_uses_absolute_kline_bounds() -> None:
    connection = MagicMock()
    result = MagicMock()
    result.mappings.return_value.all.return_value = []
    connection.execute = AsyncMock(return_value=result)
    repository = MonitoringRepository(MagicMock())

    await repository._websocket_sync(connection, 525)

    statement = str(connection.execute.await_args_list[0].args[0])
    parameters = connection.execute.await_args_list[0].args[1]
    assert "k.open_time >= CAST(:kline_range_start AS timestamptz)" in statement
    assert "k.open_time < CAST(:kline_range_end AS timestamptz)" in statement
    assert parameters["kline_range_end"] > parameters["kline_range_start"]


async def test_monitoring_snapshot_coalesces_concurrent_requests() -> None:
    repository = MagicMock()
    repository.snapshot = AsyncMock(return_value=database_snapshot())
    nats_probe = MagicMock()
    nats_probe.snapshot = AsyncMock(
        return_value=NatsMetric(
            status=HealthStatus.HEALTHY,
            connected=True,
            message="ok",
        )
    )
    settings = SimpleNamespace(environment="TEST", node_id="test-node")
    service = MonitoringService(repository, settings, nats_probe)  # type: ignore[arg-type]

    first, second = await asyncio.gather(service.snapshot(), service.snapshot())

    assert first is second
    repository.snapshot.assert_awaited_once()
    nats_probe.snapshot.assert_awaited_once()


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


def test_websocket_sync_metric_reports_fallback_and_missing_as_failures() -> None:
    metric = websocket_sync_metric(
        WebSocketSyncRow(
            key="trade_60",
            expected=1000,
            succeeded=960,
            rest_fallback=35,
            other_source=0,
            missing=5,
        )
    )

    assert metric.status is HealthStatus.WARNING
    assert metric.success_percent == 96.0
    assert metric.failed == 40
    assert metric.rest_fallback == 35
    assert metric.other_source == 0
    assert metric.missing == 5


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
    range_start = datetime(2026, 10, 10, 2, 58, tzinfo=UTC)
    range_end = range_start + timedelta(days=1)
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
                pending_range_start=range_start,
                pending_range_end=range_end,
                running_jobs=(
                    BackfillTaskRow(
                        symbol="BTCUSDT",
                        data_type="KLINE_TRADE",
                        interval_seconds=60,
                        range_start=range_start,
                        range_end=range_end,
                        started_at=datetime.now(UTC),
                        attempts=1,
                    ),
                ),
            )
        )
    )

    assert metric.queue_delta_last_hour == -100
    assert metric.estimated_clear_seconds == 8640
    assert metric.succeeded_last_hour == 120
    assert metric.pending_range_start == range_start
    assert metric.pending_range_end == range_end
    assert metric.running_jobs[0].symbol == "BTCUSDT"
    assert metric.running_jobs[0].interval_seconds == 60


def test_backfill_clear_time_is_unknown_without_recent_success() -> None:
    metric = backfill_metric(
        database_snapshot(backfill=BackfillRows({"PENDING": 5}, 5, 30))
    )

    assert metric.estimated_clear_seconds is None


def test_backfill_clear_time_is_unknown_while_queue_is_growing() -> None:
    metric = backfill_metric(
        database_snapshot(
            backfill=BackfillRows(
                {"PENDING": 9166, "SUCCEEDED": 24740},
                9166,
                18000,
                succeeded_last_hour=1015,
                created_last_hour=5667,
                finished_last_hour=1015,
            )
        )
    )

    assert metric.queue_delta_last_hour == 4652
    assert metric.estimated_clear_seconds is None


def test_rest_usage_uses_2400_weight_limit() -> None:
    healthy = rest_usage_metric(
        database_snapshot(
            rest_usage=RestUsageRow(
                525,
                600,
                datetime.now(UTC),
                average_used_weight_1h=480.5,
                sampled_minutes_1h=58,
            )
        )
    )
    critical = rest_usage_metric(
        database_snapshot(
            rest_usage=RestUsageRow(1000, 1920, datetime.now(UTC))
        )
    )

    assert healthy.status is HealthStatus.HEALTHY
    assert healthy.utilization_percent == 25
    assert healthy.average_used_weight_1h == 480.5
    assert healthy.average_utilization_percent_1h == 20.02
    assert healthy.sampled_minutes_1h == 58
    assert critical.status is HealthStatus.CRITICAL


def test_database_metric_reports_cache_and_largest_tables() -> None:
    snapshot = database_snapshot()
    snapshot = DatabaseSnapshot(
        active_symbols=snapshot.active_symbols,
        coverage=snapshot.coverage,
        backfill=snapshot.backfill,
        rest_usage=snapshot.rest_usage,
        database_size_bytes=2048,
        database_size_display="2048 bytes",
        cache_hit_percent=99.995,
        largest_tables=(
            TableSizeRow(
                "market",
                "klines",
                True,
                1000,
                1024,
                512,
                0,
                1536,
                chunk_count=4,
                compression_enabled=True,
                columnstore_chunks=3,
                columnstore_before_bytes=1000,
                columnstore_after_bytes=200,
                columnstore_policy_enabled=True,
            ),
        ),
    )

    metric = database_metric(snapshot)

    assert metric.status is HealthStatus.HEALTHY
    assert metric.cache_hit_percent == 100.0
    assert metric.largest_tables[0].table_name == "klines"
    assert metric.largest_tables[0].compression_enabled is True
    assert metric.largest_tables[0].columnstore_saved_percent == 80.0
    assert metric.largest_tables[0].columnstore_policy_enabled is True


def test_database_metric_warns_on_low_cache_hit_rate() -> None:
    snapshot = database_snapshot()
    snapshot = DatabaseSnapshot(
        active_symbols=snapshot.active_symbols,
        coverage=snapshot.coverage,
        backfill=snapshot.backfill,
        rest_usage=snapshot.rest_usage,
        database_size_bytes=snapshot.database_size_bytes,
        database_size_display=snapshot.database_size_display,
        cache_hit_percent=98.5,
    )

    assert database_metric(snapshot).status is HealthStatus.WARNING


def test_daily_ranking_entry_serializes_repository_row() -> None:
    snapshot_at = datetime(2026, 10, 9, 23, 55, tzinfo=UTC)
    row = RankingEntryRow(
        utc_trade_date=date(2026, 10, 9),
        snapshot_at=snapshot_at,
        rank_no=1,
        symbol="BTCUSDT",
        price_change=12.5,
        reference_open_price=100.0,
        snapshot_price=112.5,
        base_volume=10.0,
        quote_volume=1000.0,
        amplitude=15.0,
        period_high_price=115.0,
        period_high_at=snapshot_at,
        period_low_price=99.0,
        period_low_at=snapshot_at - timedelta(hours=20),
        open_interest_qty=None,
        open_interest_value=None,
        open_interest_status="UNAVAILABLE",
        quality_status="VALID",
    )

    payload = DailyRankingEntry.model_validate(row)

    assert payload.symbol == "BTCUSDT"
    assert payload.price_change == 12.5
    assert payload.utc_trade_date == date(2026, 10, 9)
    assert payload.open_interest_status == "UNAVAILABLE"


def test_kline_point_serializes_repository_row() -> None:
    open_time = datetime(2026, 10, 18, tzinfo=UTC)
    row = KlinePointRow(
        open_time=open_time,
        close_time=open_time + timedelta(minutes=5),
        open_price=100.0,
        high_price=112.0,
        low_price=98.0,
        close_price=110.0,
        base_volume=12.0,
        quote_volume=1260.0,
        ema20=105.0,
        ema240=101.0,
    )

    payload = KlinePoint.model_validate(row)

    assert payload.open_price == 100.0
    assert payload.close_price == 110.0
    assert payload.ema20 == 105.0
    assert payload.close_time == open_time + timedelta(minutes=5)


async def test_daily_klines_uses_ranking_day_through_latest_closed_window() -> None:
    rows_result = MagicMock()
    rows_result.mappings.return_value.all.return_value = []
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=rows_result)
    context = AsyncMock()
    context.__aenter__.return_value = connection
    engine = MagicMock()
    engine.connect.return_value = context
    repository = MonitoringRepository(engine)

    before_call = datetime.now(UTC)
    await repository.daily_klines(
        symbol=" btcusdt ", utc_trade_date=date(2026, 10, 18)
    )
    after_call = datetime.now(UTC)

    statement = str(connection.execute.await_args_list[0].args[0])
    parameters = connection.execute.await_args_list[0].args[1]
    assert "k.interval_seconds = 300" in statement
    assert "k.is_current" in statement
    assert "i.market = 'USD_M_FUTURES'" in statement
    assert parameters["symbol"] == "BTCUSDT"
    assert parameters["range_start"] == datetime(2026, 10, 18, tzinfo=UTC)
    assert parameters["range_end"] > datetime(2026, 10, 18, 23, 55, tzinfo=UTC)
    assert parameters["range_end"].second == 0
    assert parameters["range_end"].microsecond == 0
    assert before_call - timedelta(minutes=5) <= parameters["range_end"] <= after_call
    ema_statement = str(connection.execute.await_args_list[1].args[0])
    assert "market.kline_ema_indicators" in ema_statement


async def test_daily_klines_aggregates_15m_and_attaches_latest_oi() -> None:
    start = datetime(2026, 10, 18, tzinfo=UTC)
    kline_rows = [
        {
            "open_time": start + timedelta(minutes=offset),
            "close_time": start + timedelta(minutes=offset + 5),
            "open_price": price - 1,
            "high_price": price + 2,
            "low_price": price - 2,
            "close_price": price,
            "base_volume": 10,
            "quote_volume": 100,
        }
        for offset, price in ((0, 10), (5, 20), (10, 30), (15, 40))
    ]
    oi_rows = [
        {
            "observed_at": start + timedelta(minutes=6),
            "open_interest_qty": 1000,
            "open_interest_value": 2000,
        },
        {
            "observed_at": start + timedelta(minutes=14),
            "open_interest_qty": 1100,
            "open_interest_value": 2200,
        },
    ]
    kline_result = MagicMock()
    kline_result.mappings.return_value.all.return_value = kline_rows
    oi_result = MagicMock()
    oi_result.mappings.return_value.all.return_value = oi_rows
    ema_result = MagicMock()
    ema_result.mappings.return_value.all.return_value = [
        {"open_time": start, "ema20": 25, "ema240": 15},
        {
            "open_time": start + timedelta(minutes=15),
            "ema20": 999,
            "ema240": 999,
        },
    ]
    connection = MagicMock()
    connection.execute = AsyncMock(side_effect=[kline_result, ema_result, oi_result])
    context = AsyncMock()
    context.__aenter__.return_value = connection
    engine = MagicMock()
    engine.connect.return_value = context

    points = await MonitoringRepository(engine).daily_klines(
        symbol="BTCUSDT",
        utc_trade_date=date(2026, 10, 18),
        interval_seconds=900,
    )

    assert len(points) == 2
    assert points[0].open_time == start
    assert points[0].open_price == 9
    assert points[0].high_price == 32
    assert points[0].low_price == 8
    assert points[0].close_price == 30
    assert points[0].quote_volume == 300
    assert points[0].open_interest_qty == 1100
    assert points[0].open_interest_value == 2200
    assert points[0].ema20 == 25
    assert points[0].ema240 == 15
    assert points[1].ema20 > points[0].ema20
    assert points[1].ema20 != 999


async def test_kline_history_returns_older_page_and_has_more() -> None:
    before = datetime(2026, 10, 18, tzinfo=UTC)
    kline_rows = [
        {
            "open_time": before - timedelta(minutes=5 * (4 - index)),
            "close_time": before - timedelta(minutes=5 * (3 - index)),
            "open_price": 100 + index,
            "high_price": 102 + index,
            "low_price": 99 + index,
            "close_price": 101 + index,
            "base_volume": 10,
            "quote_volume": 100,
        }
        for index in range(4)
    ]
    kline_result = MagicMock()
    kline_result.mappings.return_value.all.return_value = kline_rows
    oi_result = MagicMock()
    oi_result.mappings.return_value.all.return_value = []
    ema_result = MagicMock()
    ema_result.mappings.return_value.all.return_value = [
        {
            "open_time": row["open_time"],
            "ema20": row["close_price"] - 1,
            "ema240": row["close_price"] - 2,
        }
        for row in kline_rows[-2:]
    ]
    connection = MagicMock()
    connection.execute = AsyncMock(side_effect=[kline_result, ema_result, oi_result])
    context = AsyncMock()
    context.__aenter__.return_value = connection
    engine = MagicMock()
    engine.connect.return_value = context

    result = await MonitoringRepository(engine).kline_history(
        symbol="BTCUSDT",
        before=before,
        interval_seconds=300,
        limit=2,
    )

    assert result.has_more is True
    assert len(result.items) == 2
    assert result.items[0].open_time == before - timedelta(minutes=10)
    statement = str(connection.execute.await_args_list[0].args[0])
    parameters = connection.execute.await_args_list[0].args[1]
    assert "ORDER BY k.open_time DESC" in statement
    assert parameters["before"] == before
    assert parameters["raw_limit"] == 3
