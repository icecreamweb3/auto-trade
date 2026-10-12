import asyncio
from datetime import UTC, datetime
from types import SimpleNamespace

import pytest

from auto_trade.collectors.scheduler import (
    CollectorScheduler,
    seconds_until_daily,
    seconds_until_interval,
)


def test_seconds_until_next_minute_with_boundary_delay() -> None:
    now = datetime(2026, 10, 9, 12, 0, 40, tzinfo=UTC)
    assert seconds_until_interval(now, 60, 5) == 25


def test_seconds_until_daily_rolls_to_next_day() -> None:
    before = datetime(2026, 10, 9, 15, 30, tzinfo=UTC)
    after = datetime(2026, 10, 9, 16, 30, tzinfo=UTC)
    assert seconds_until_daily(before, 16) == 30 * 60
    assert seconds_until_daily(after, 16) == 23.5 * 60 * 60


@pytest.mark.asyncio
async def test_scheduler_starts_websocket_and_rest_fallback_loops() -> None:
    scheduler = object.__new__(CollectorScheduler)
    scheduler._settings = SimpleNamespace(collector_startup_delay_seconds=0)
    started = {
        name: asyncio.Event()
        for name in ("ticker", "one_minute", "five_minute", "instrument", "websocket")
    }

    async def sync_until_ready() -> None:
        return None

    async def mark_started(name: str) -> None:
        started[name].set()
        await asyncio.Future()

    scheduler._sync_instruments_until_ready = sync_until_ready
    scheduler._ticker_loop = lambda: mark_started("ticker")
    scheduler._one_minute_kline_loop = lambda: mark_started("one_minute")
    scheduler._kline_loop = lambda: mark_started("five_minute")
    scheduler._instrument_loop = lambda: mark_started("instrument")
    scheduler._websocket = SimpleNamespace(
        run_forever=lambda: mark_started("websocket")
    )

    task = asyncio.create_task(scheduler.run_forever())
    try:
        await asyncio.wait_for(
            asyncio.gather(*(event.wait() for event in started.values())),
            timeout=1,
        )
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
