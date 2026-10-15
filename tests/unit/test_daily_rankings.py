from datetime import UTC, date, datetime

from auto_trade.collectors.daily_rankings import latest_completed_utc_day


def test_latest_completed_utc_day_uses_utc_not_local_date() -> None:
    now = datetime(2026, 10, 15, 0, 3, tzinfo=UTC)

    assert latest_completed_utc_day(now) == date(2026, 10, 14)
