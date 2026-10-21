from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest

from auto_trade.collectors.paper_history import (
    INTERVAL,
    WRITE_BATCH_SIZE,
    HistoricalKline,
    PaperHistoryRepository,
    checkpoint_key,
    latest_closed_boundary,
    parse_binance_klines,
)


def raw_kline(open_time: datetime, price: str = "100") -> list[object]:
    open_ms = int(open_time.timestamp() * 1000)
    return [
        open_ms,
        price,
        "105",
        "95",
        "102",
        "12.5",
        open_ms + 299_999,
        "1250",
        42,
        "0",
        "0",
        "0",
    ]


def test_latest_closed_boundary_applies_safety_delay_and_alignment() -> None:
    assert latest_closed_boundary(
        datetime(2026, 10, 21, 12, 10, 30, tzinfo=UTC)
    ) == datetime(2026, 10, 21, 12, 5, tzinfo=UTC)
    assert latest_closed_boundary(
        datetime(2026, 10, 21, 12, 11, tzinfo=UTC)
    ) == datetime(2026, 10, 21, 12, 10, tzinfo=UTC)


def test_parse_binance_klines_builds_canonical_trade_rows() -> None:
    start = datetime(2020, 4, 1, tzinfo=UTC)
    rows = parse_binance_klines(
        "BTCUSDT",
        [raw_kline(start), raw_kline(start + INTERVAL, "102")],
        range_start=start,
        range_end=start + 2 * INTERVAL,
        collected_at=start + 3 * INTERVAL,
    )

    assert len(rows) == 2
    assert rows[0].open_price == Decimal("100")
    assert rows[0].close_price == Decimal("102")
    assert rows[0].base_volume == Decimal("12.5")
    assert rows[0].quote_volume == Decimal("1250")
    assert rows[0].trade_count == 42
    assert rows[0].close_time == start + INTERVAL
    assert len(rows[0].payload_hash) == 64
    assert rows[0].payload_hash != rows[1].payload_hash


def test_parse_binance_klines_excludes_outside_and_unclosed_rows() -> None:
    start = datetime(2020, 4, 1, tzinfo=UTC)
    rows = parse_binance_klines(
        "ETHUSDT",
        [
            raw_kline(start - INTERVAL),
            raw_kline(start),
            raw_kline(start + INTERVAL),
        ],
        range_start=start,
        range_end=start + 3 * INTERVAL,
        collected_at=start + INTERVAL + timedelta(seconds=1),
    )

    assert [row.open_time for row in rows] == [start]


def test_parse_binance_klines_rejects_bad_ohlc() -> None:
    start = datetime(2020, 4, 1, tzinfo=UTC)
    row = raw_kline(start)
    row[2] = "99"

    with pytest.raises(ValueError, match="high_price"):
        parse_binance_klines(
            "BTCUSDT",
            [row],
            range_start=start,
            range_end=start + INTERVAL,
            collected_at=start + 2 * INTERVAL,
        )


def test_parse_binance_klines_requires_increasing_aligned_rows() -> None:
    start = datetime(2020, 4, 1, tzinfo=UTC)
    with pytest.raises(ValueError, match="non-increasing"):
        parse_binance_klines(
            "BTCUSDT",
            [raw_kline(start), raw_kline(start)],
            range_start=start,
            range_end=start + INTERVAL,
            collected_at=start + 2 * INTERVAL,
        )


def test_checkpoint_key_is_isolated_per_symbol() -> None:
    assert checkpoint_key("BTCUSDT") == "PAPER_HISTORY_BTCUSDT_300"
    assert checkpoint_key("ETHUSDT") == "PAPER_HISTORY_ETHUSDT_300"


async def test_database_writes_are_split_into_bounded_transactions() -> None:
    repository = PaperHistoryRepository(MagicMock())
    write_batch = AsyncMock(
        side_effect=(WRITE_BATCH_SIZE, WRITE_BATCH_SIZE, 1)
    )
    repository._write_kline_batch = write_batch  # type: ignore[method-assign]
    opened = datetime(2020, 4, 1, tzinfo=UTC)
    row = HistoricalKline(
        open_time=opened,
        close_time=opened + INTERVAL,
        open_price=Decimal("100"),
        high_price=Decimal("105"),
        low_price=Decimal("95"),
        close_price=Decimal("102"),
        base_volume=Decimal("12.5"),
        quote_volume=Decimal("1250"),
        trade_count=42,
        payload_hash="a" * 64,
        collected_at=opened + INTERVAL,
    )

    inserted = await repository.write_klines(
        1, tuple(row for _ in range(WRITE_BATCH_SIZE * 2 + 1))
    )

    assert inserted == WRITE_BATCH_SIZE * 2 + 1
    assert [len(call.args[1]) for call in write_batch.await_args_list] == [
        WRITE_BATCH_SIZE,
        WRITE_BATCH_SIZE,
        1,
    ]
