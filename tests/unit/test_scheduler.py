from datetime import UTC, datetime

from auto_trade.collectors.scheduler import seconds_until_daily, seconds_until_interval


def test_seconds_until_next_minute_with_boundary_delay() -> None:
    now = datetime(2026, 10, 9, 12, 0, 40, tzinfo=UTC)
    assert seconds_until_interval(now, 60, 5) == 25


def test_seconds_until_daily_rolls_to_next_day() -> None:
    before = datetime(2026, 10, 9, 15, 30, tzinfo=UTC)
    after = datetime(2026, 10, 9, 16, 30, tzinfo=UTC)
    assert seconds_until_daily(before, 16) == 30 * 60
    assert seconds_until_daily(after, 16) == 23.5 * 60 * 60
