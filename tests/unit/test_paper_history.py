import json
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest

from auto_trade.collectors.paper_history import (
    INTERVAL,
    STATUS_SCAN_WINDOW,
    WRITE_BATCH_SIZE,
    HistoricalKline,
    PaperHistoryRepository,
    checkpoint_key,
    latest_closed_boundary,
    parse_binance_klines,
    scan_windows,
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


def test_status_scan_windows_are_bounded() -> None:
    range_start = datetime(2020, 4, 1, tzinfo=UTC)
    range_end = range_start + 2 * STATUS_SCAN_WINDOW + INTERVAL

    assert list(scan_windows(range_start, range_end)) == [
        (range_start, range_start + STATUS_SCAN_WINDOW),
        (
            range_start + STATUS_SCAN_WINDOW,
            range_start + 2 * STATUS_SCAN_WINDOW,
        ),
        (range_start + 2 * STATUS_SCAN_WINDOW, range_end),
    ]


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


async def test_database_write_prefilters_existing_rows_without_conflict_scan() -> None:
    opened = datetime(2020, 4, 1, tzinfo=UTC)
    rows = tuple(
        HistoricalKline(
            open_time=opened + offset * INTERVAL,
            close_time=opened + (offset + 1) * INTERVAL,
            open_price=Decimal("100"),
            high_price=Decimal("105"),
            low_price=Decimal("95"),
            close_price=Decimal("102"),
            base_volume=Decimal("12.5"),
            quote_volume=Decimal("1250"),
            trade_count=42,
            payload_hash=str(offset) * 64,
            collected_at=opened + 3 * INTERVAL,
        )
        for offset in range(2)
    )
    existing_result = MagicMock()
    existing_result.scalars.return_value = [opened]
    insert_result = MagicMock(rowcount=1)
    connection = AsyncMock()
    connection.execute.side_effect = (MagicMock(), existing_result, insert_result)
    transaction = AsyncMock()
    transaction.__aenter__.return_value = connection
    engine = MagicMock()
    engine.begin.return_value = transaction

    inserted = await PaperHistoryRepository(engine)._write_kline_batch(1, rows)

    assert inserted == 1
    plan_sql = str(connection.execute.await_args_list[0].args[0])
    assert "force_custom_plan" in plan_sql
    lookup_sql = str(connection.execute.await_args_list[1].args[0])
    assert "open_time >= :range_start" in lookup_sql
    assert "open_time < :range_end" in lookup_sql
    insert_sql = str(connection.execute.await_args_list[2].args[0])
    assert "ON CONFLICT" not in insert_sql
    insert_params = connection.execute.await_args_list[2].args[1]
    serialized_rows = json.loads(insert_params["rows"])
    assert [row["open_time"] for row in serialized_rows] == [
        (opened + INTERVAL).isoformat()
    ]


async def test_first_missing_releases_transaction_between_scan_windows() -> None:
    range_start = datetime(2020, 4, 1, tzinfo=UTC)
    missing_at = range_start + STATUS_SCAN_WINDOW
    connections = []
    transactions = []
    for result_value in (None, missing_at):
        scalar_result = MagicMock()
        scalar_result.scalar_one.return_value = result_value
        connection = AsyncMock()
        connection.execute.side_effect = (MagicMock(), scalar_result)
        transaction = AsyncMock()
        transaction.__aenter__.return_value = connection
        connections.append(connection)
        transactions.append(transaction)
    engine = MagicMock()
    engine.begin.side_effect = transactions

    result = await PaperHistoryRepository(engine).first_missing(
        1, range_start, missing_at + INTERVAL
    )

    assert result == missing_at
    assert engine.begin.call_count == 2
    first_params = connections[0].execute.await_args_list[1].args[1]
    second_params = connections[1].execute.await_args_list[1].args[1]
    assert first_params["range_start"] == range_start
    assert first_params["range_end"] == missing_at
    assert second_params["range_start"] == missing_at
    assert second_params["range_end"] == missing_at + INTERVAL


async def test_status_aggregates_independent_scan_windows() -> None:
    range_start = datetime(2020, 4, 1, tzinfo=UTC)
    second_window = range_start + STATUS_SCAN_WINDOW
    range_end = second_window + INTERVAL
    rows = (
        {
            "valid_count": int(STATUS_SCAN_WINDOW / INTERVAL),
            "first_open_time": range_start,
            "last_open_time": second_window - INTERVAL,
        },
        {
            "valid_count": 1,
            "first_open_time": second_window,
            "last_open_time": second_window,
        },
    )
    contexts = []
    for row in rows:
        query_result = MagicMock()
        query_result.mappings.return_value.one.return_value = row
        connection = AsyncMock()
        connection.execute.side_effect = (MagicMock(), query_result)
        context = AsyncMock()
        context.__aenter__.return_value = connection
        contexts.append(context)
    engine = MagicMock()
    engine.begin.side_effect = contexts
    repository = PaperHistoryRepository(engine)
    repository.instrument_id = AsyncMock(return_value=1)  # type: ignore[method-assign]
    repository.first_missing = AsyncMock()  # type: ignore[method-assign]

    status = await repository.status("BTCUSDT", range_start, range_end)

    assert engine.begin.call_count == 2
    assert status.valid_count == status.expected_count
    assert status.first_open_time == range_start
    assert status.last_open_time == second_window
    assert status.first_missing_at is None
    repository.first_missing.assert_not_awaited()
