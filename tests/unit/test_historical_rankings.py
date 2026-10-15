from datetime import UTC, date, datetime, timedelta
from decimal import Decimal

from auto_trade.collectors.historical_rankings import (
    Instrument,
    aggregate_daily_klines,
    aggregate_local_daily_rows,
    instrument_is_eligible,
)


def kline(
    open_at: datetime,
    value: int,
    *,
    high: int | None = None,
    low: int | None = None,
) -> list[object]:
    return [
        int(open_at.timestamp() * 1000), str(value), str(high or value + 2),
        str(low or value - 2), str(value + 1), "2", 0, "20", 0, "0", "0", "0",
    ]


def test_aggregate_complete_utc_day_uses_2350_bar_close() -> None:
    day = date(2026, 1, 2)
    start = datetime(2026, 1, 2, tzinfo=UTC)
    rows = [kline(start + timedelta(minutes=5 * index), 100 + index) for index in range(287)]
    rows.append(kline(start + timedelta(minutes=5 * 287), 9999))

    result = aggregate_daily_klines(day, rows)

    assert result.quality_status == "VALID"
    assert result.actual_bar_count == 287
    assert result.reference_open_price == Decimal("100")
    assert result.snapshot_price == Decimal("387")
    assert result.source_kline_time == datetime(
        2026, 1, 2, 23, 55, tzinfo=UTC
    ) - timedelta(minutes=5)
    assert result.base_volume == Decimal("574")
    assert result.quote_volume == Decimal("5740")


def test_aggregate_incomplete_day_is_partial() -> None:
    day = date(2026, 1, 2)
    start = datetime(2026, 1, 2, tzinfo=UTC)
    result = aggregate_daily_klines(day, [kline(start, 100)])
    assert result.quality_status == "PARTIAL"
    assert result.actual_bar_count == 1


def test_instrument_requires_full_eligible_utc_day() -> None:
    day = date(2026, 1, 2)
    assert instrument_is_eligible(Instrument(1, "BTCUSDT", None, None), day)
    assert not instrument_is_eligible(
        Instrument(2, "NEWUSDT", datetime(2026, 1, 2, 1, tzinfo=UTC), None), day
    )
    assert not instrument_is_eligible(
        Instrument(3, "OLDUSDT", None, datetime(2026, 1, 2, 12, tzinfo=UTC)), day
    )


def test_local_daily_rows_include_missing_instrument_as_invalid() -> None:
    day = date(2026, 1, 2)
    start = datetime(2026, 1, 2, tzinfo=UTC)
    instruments = [
        Instrument(1, "BTCUSDT", None, None),
        Instrument(2, "ETHUSDT", None, None),
    ]
    rows = [
        {
            "instrument_id": 1,
            "open_time": start + timedelta(minutes=5 * index),
            "open_price": Decimal(100 + index),
            "high_price": Decimal(102 + index),
            "low_price": Decimal(98 + index),
            "close_price": Decimal(101 + index),
            "base_volume": Decimal("2"),
            "quote_volume": Decimal("20"),
        }
        for index in range(287)
    ]

    metrics = aggregate_local_daily_rows(day, instruments, rows)

    assert [instrument_id for instrument_id, _ in metrics] == [1, 2]
    assert metrics[0][1].quality_status == "VALID"
    assert metrics[0][1].metrics["source"] == "LOCAL_DATABASE_TRADE_KLINE_5M"
    assert metrics[1][1].quality_status == "INVALID"
    assert metrics[1][1].metrics["reason"] == "NO_KLINES"
