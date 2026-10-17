import asyncio
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock
from uuid import UUID

import pytest

from auto_trade.collectors.binance_usdm import BinanceRateLimitError
from auto_trade.collectors.data_repair import (
    BackfillJob,
    DataRepairRepository,
    DataRepairService,
    GapRange,
    align_kline_range,
    group_missing_points,
    next_cycle_delay,
    split_gap_range,
)
from auto_trade.collectors.service import TRADE_5M_SERIES


def test_group_missing_points_merges_contiguous_ranges_per_instrument() -> None:
    start = datetime(2026, 10, 9, 10, 0, tzinfo=UTC)
    rows = [
        (1, "BTCUSDT", start),
        (1, "BTCUSDT", start + timedelta(minutes=5)),
        (1, "BTCUSDT", start + timedelta(minutes=15)),
        (2, "ETHUSDT", start),
    ]
    assert group_missing_points(rows, timedelta(minutes=5)) == [
        GapRange(1, "BTCUSDT", start, start + timedelta(minutes=10), 2),
        GapRange(
            1,
            "BTCUSDT",
            start + timedelta(minutes=15),
            start + timedelta(minutes=20),
            1,
        ),
        GapRange(2, "ETHUSDT", start, start + timedelta(minutes=5), 1),
    ]


def test_split_gap_range_respects_binance_kline_limit() -> None:
    start = datetime(2026, 10, 1, tzinfo=UTC)
    gap = GapRange(
        1,
        "BTCUSDT",
        start,
        start + timedelta(minutes=5 * 3_001),
        3_001,
        TRADE_5M_SERIES,
    )
    split = split_gap_range(gap, max_points=1_500)

    assert [(item.start, item.expected_count) for item in split] == [
        (start, 1_500),
        (start + timedelta(minutes=7_500), 1_500),
        (start + timedelta(minutes=15_000), 1),
    ]
    assert split[-1].end == gap.end


def test_gap_scan_ranges_align_to_series_boundaries() -> None:
    start = datetime(2026, 10, 1, 12, 1, 42, tzinfo=UTC)
    end = datetime(2026, 10, 1, 13, 4, 9, tzinfo=UTC)

    assert align_kline_range(start, end, TRADE_5M_SERIES) == (
        datetime(2026, 10, 1, 12, 0, tzinfo=UTC),
        datetime(2026, 10, 1, 13, 0, tzinfo=UTC),
    )


async def test_gap_scan_applies_explicit_hypertable_time_bounds() -> None:
    connection = MagicMock()
    result = MagicMock()
    result.all.return_value = []
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(
        return_value=connection
    )
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = DataRepairRepository(engine)
    start = datetime(2026, 10, 1, tzinfo=UTC)

    await repository.detect_kline_gaps_in_range(
        start,
        start + timedelta(days=1),
        TRADE_5M_SERIES,
    )

    timeout_call = connection.execute.await_args_list[0]
    assert "set_config('statement_timeout'" in str(timeout_call.args[0])
    assert timeout_call.args[1] == {"statement_timeout": "45s"}
    statement = str(connection.execute.await_args.args[0])
    assert "k.open_time >= CAST(:range_start AS timestamptz)" in statement
    assert "k.open_time < CAST(:range_end AS timestamptz)" in statement


async def test_historical_checkpoint_casts_timestamp_parameters() -> None:
    connection = MagicMock()
    connection.execute = AsyncMock()
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = DataRepairRepository(engine)

    await repository.save_historical_scan_checkpoint(
        datetime(2026, 10, 1, tzinfo=UTC),
        datetime(2026, 10, 2, tzinfo=UTC),
    )

    statement = str(connection.execute.await_args.args[0])
    assert "cursor_at = CAST(:cursor_at AS timestamptz)" in statement
    assert "scan_stop_at = CAST(:scan_stop_at AS timestamptz)" in statement
    assert "WHEN CAST(:cursor_at AS timestamptz)" in statement


def test_historical_gap_scan_advances_in_bounded_windows() -> None:
    settings = SimpleNamespace(
        gap_scan_lookback_hours=72,
        gap_scan_recent_lookback_hours=24,
        gap_scan_historical_window_hours=12,
        gap_scan_safety_delay_seconds=60,
    )
    service = DataRepairService(MagicMock(), MagicMock(), settings)
    now = datetime(2026, 10, 12, 12, 0, tzinfo=UTC)
    scan_end = now - timedelta(seconds=60)

    first = service._gap_scan_ranges(now)
    service._complete_historical_scan(first)
    second = service._gap_scan_ranges(now)

    assert first == (
        (scan_end - timedelta(hours=24), scan_end),
        (
            scan_end - timedelta(hours=72),
            scan_end - timedelta(hours=60),
        ),
    )
    assert second == (
        (scan_end - timedelta(hours=24), scan_end),
        (
            scan_end - timedelta(hours=60),
            scan_end - timedelta(hours=48),
        ),
    )


async def test_historical_gap_scan_checkpoint_is_restored_and_advanced() -> None:
    cursor = datetime(2026, 8, 1, tzinfo=UTC)
    stop = datetime(2026, 10, 1, tzinfo=UTC)
    settings = SimpleNamespace(
        gap_scan_lookback_hours=72,
        gap_scan_recent_lookback_hours=24,
        gap_scan_historical_window_hours=12,
        gap_scan_safety_delay_seconds=60,
        backfill_jobs_per_cycle=1,
        backfill_worker_count=1,
        backfill_verify_timeout_seconds=60.0,
        backfill_verify_poll_interval_seconds=1.0,
        backfill_request_interval_seconds=0,
    )
    repository = MagicMock()
    repository.load_historical_scan_checkpoint = AsyncMock(
        return_value=(cursor, stop)
    )
    repository.detect_kline_gaps_in_range = AsyncMock(return_value=[])
    repository.save_historical_scan_checkpoint = AsyncMock()
    repository.claim_job = AsyncMock(return_value=None)
    service = DataRepairService(repository, MagicMock(), settings)

    await service._restore_historical_scan_checkpoint()
    result = await service.run_cycle(scan_gaps=True)

    assert result == {"detected": 0, "queued": 0, "succeeded": 0, "failed": 0}
    assert repository.detect_kline_gaps_in_range.await_count == 6
    repository.save_historical_scan_checkpoint.assert_awaited_once_with(
        cursor + timedelta(hours=12),
        stop,
    )
    assert service._historical_scan_cursor == cursor + timedelta(hours=12)
    assert service._historical_scan_stop == stop


async def test_run_forever_repairs_while_gap_scan_is_running() -> None:
    scan_started = asyncio.Event()
    repair_started = asyncio.Event()
    never_complete = asyncio.Event()
    settings = SimpleNamespace(
        gap_scan_lookback_hours=24,
        gap_scan_recent_lookback_hours=24,
        gap_scan_interval_seconds=300,
        backfill_worker_count=8,
        backfill_jobs_per_cycle=50,
        backfill_request_interval_seconds=2.0,
        backfill_stale_job_seconds=300,
        backfill_failed_retry_limit=3,
    )
    repository = MagicMock()
    repository.recover_interrupted_jobs = AsyncMock(
        return_value={"stale": 0, "failed": 0}
    )
    service = DataRepairService(repository, MagicMock(), settings)

    async def scan() -> dict[str, int]:
        scan_started.set()
        await never_complete.wait()
        return {"detected": 0, "queued": 0}

    async def repair(*, scan_gaps: bool) -> dict[str, int]:
        assert scan_gaps is False
        repair_started.set()
        await never_complete.wait()
        return {"detected": 0, "queued": 0, "succeeded": 0, "failed": 0}

    service._scan_and_queue_gaps = AsyncMock(side_effect=scan)  # type: ignore[method-assign]
    service.run_cycle = AsyncMock(side_effect=repair)  # type: ignore[method-assign]

    task = asyncio.create_task(service.run_forever())
    try:
        await asyncio.wait_for(scan_started.wait(), timeout=1)
        await asyncio.wait_for(repair_started.wait(), timeout=1)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task


def test_completed_historical_checkpoint_tracks_recent_scan_boundary() -> None:
    settings = SimpleNamespace(
        gap_scan_lookback_hours=72,
        gap_scan_recent_lookback_hours=24,
        gap_scan_historical_window_hours=12,
        gap_scan_safety_delay_seconds=60,
    )
    service = DataRepairService(MagicMock(), MagicMock(), settings)
    service._historical_scan_cursor = datetime(2026, 10, 1, tzinfo=UTC)
    service._historical_scan_stop = datetime(2026, 10, 1, tzinfo=UTC)
    now = datetime(2026, 10, 12, 12, 0, tzinfo=UTC)
    expected_boundary = now - timedelta(seconds=60, hours=24)

    ranges = service._gap_scan_ranges(now)
    service._complete_historical_scan(ranges)

    assert ranges == ((expected_boundary, now - timedelta(seconds=60)),)
    assert service._historical_scan_cursor == expected_boundary
    assert service._historical_scan_stop == expected_boundary


def test_backlog_cycles_continue_without_full_idle_delay() -> None:
    assert (
        next_cycle_delay(
            {"detected": 0, "queued": 0, "succeeded": 50, "failed": 0},
            batch_limit=50,
            idle_interval_seconds=300,
        )
        == 1
    )
    assert (
        next_cycle_delay(
            {"detected": 0, "queued": 0, "succeeded": 49, "failed": 1},
            batch_limit=50,
            idle_interval_seconds=300,
        )
        == 1
    )
    assert (
        next_cycle_delay(
            {"detected": 0, "queued": 0, "succeeded": 0, "failed": 0},
            batch_limit=50,
            idle_interval_seconds=300,
        )
        == 300
    )


async def test_backlog_cycle_skips_scan_and_binance_for_prefilled_job() -> None:
    start = datetime(2026, 10, 9, 10, 0, tzinfo=UTC)
    job = BackfillJob(
        UUID(int=1),
        UUID(int=2),
        1,
        "BTCUSDT",
        start,
        start + timedelta(minutes=5),
        1,
        TRADE_5M_SERIES,
    )
    repository = MagicMock()
    repository.detect_kline_gaps = AsyncMock()
    repository.queue_gaps = AsyncMock()
    repository.claim_job = AsyncMock(side_effect=[job, None])
    repository.complete_if_filled = AsyncMock(return_value=True)
    repository.finish_job = AsyncMock()
    repository.fail_job = AsyncMock()
    collector = MagicMock()
    collector.collect_kline_range = AsyncMock()
    settings = SimpleNamespace(
        backfill_jobs_per_cycle=2,
        backfill_worker_count=2,
        gap_scan_lookback_hours=24,
        backfill_verify_timeout_seconds=60.0,
        backfill_verify_poll_interval_seconds=1.0,
    )

    result = await DataRepairService(repository, collector, settings).run_cycle(
        scan_gaps=False
    )

    assert result == {"detected": 0, "queued": 0, "succeeded": 1, "failed": 0}
    repository.detect_kline_gaps.assert_not_awaited()
    repository.queue_gaps.assert_not_awaited()
    collector.collect_kline_range.assert_not_awaited()


async def test_rate_limit_defers_job_and_stops_cycle() -> None:
    start = datetime(2026, 10, 9, 10, 0, tzinfo=UTC)
    job = BackfillJob(
        UUID(int=1),
        UUID(int=2),
        1,
        "BTCUSDT",
        start,
        start + timedelta(minutes=5),
        1,
        TRADE_5M_SERIES,
    )
    repository = MagicMock()
    repository.claim_job = AsyncMock(return_value=job)
    repository.complete_if_filled = AsyncMock(return_value=False)
    repository.defer_job = AsyncMock()
    repository.fail_job = AsyncMock()
    collector = MagicMock()
    rate_limit = BinanceRateLimitError(418, 300)
    collector.collect_kline_range = AsyncMock(side_effect=rate_limit)
    settings = SimpleNamespace(
        backfill_jobs_per_cycle=2,
        backfill_worker_count=1,
        gap_scan_lookback_hours=24,
        backfill_verify_timeout_seconds=60.0,
        backfill_verify_poll_interval_seconds=1.0,
        backfill_request_interval_seconds=2.0,
    )

    with pytest.raises(BinanceRateLimitError):
        await DataRepairService(repository, collector, settings).run_cycle(
            scan_gaps=False
        )

    repository.defer_job.assert_awaited_once_with(job, rate_limit)
    repository.fail_job.assert_not_awaited()


async def test_backfill_workers_process_jobs_concurrently() -> None:
    start = datetime(2026, 10, 9, 10, 0, tzinfo=UTC)
    jobs = [
        BackfillJob(
            UUID(int=index),
            UUID(int=100 + index),
            index,
            f"TEST{index}USDT",
            start,
            start + timedelta(minutes=5),
            1,
            TRADE_5M_SERIES,
        )
        for index in range(1, 5)
    ]
    repository = MagicMock()
    repository.claim_job = AsyncMock(side_effect=[*jobs, None, None, None, None])
    repository.complete_if_filled = AsyncMock(return_value=False)
    repository.finish_job = AsyncMock(return_value=True)
    repository.defer_job = AsyncMock()
    repository.fail_job = AsyncMock()
    collector = MagicMock()
    active = 0
    maximum_active = 0

    async def collect(*_args: object) -> int:
        nonlocal active, maximum_active
        active += 1
        maximum_active = max(maximum_active, active)
        await asyncio.sleep(0)
        active -= 1
        return 1

    collector.collect_kline_range = AsyncMock(side_effect=collect)
    settings = SimpleNamespace(
        backfill_jobs_per_cycle=4,
        backfill_worker_count=4,
        gap_scan_lookback_hours=24,
        backfill_verify_timeout_seconds=60.0,
        backfill_verify_poll_interval_seconds=1.0,
        backfill_request_interval_seconds=0,
    )

    result = await DataRepairService(repository, collector, settings).run_cycle(
        scan_gaps=False
    )

    assert result == {"detected": 0, "queued": 0, "succeeded": 4, "failed": 0}
    assert maximum_active == 4
