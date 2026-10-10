from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock
from uuid import UUID

import pytest

from auto_trade.collectors.binance_usdm import BinanceRateLimitError
from auto_trade.collectors.data_repair import (
    BackfillJob,
    DataRepairService,
    GapRange,
    group_missing_points,
    next_cycle_delay,
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
