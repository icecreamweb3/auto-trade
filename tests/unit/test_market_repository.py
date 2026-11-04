from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import UUID, uuid4

from auto_trade.contracts import KlinePayload, MarketSource, PriceType, QualityStatus
from auto_trade.writers.market_repository import IncomingEvent, MarketRepository


async def test_kline_write_forces_custom_plan_before_locking_chunk() -> None:
    opened = datetime(2026, 10, 22, tzinfo=UTC)
    payload = KlinePayload(
        symbol="BTCUSDT",
        price_type=PriceType.TRADE,
        interval_seconds=300,
        open_time=opened,
        close_time=opened + timedelta(minutes=5),
        open_price=Decimal("100"),
        high_price=Decimal("110"),
        low_price=Decimal("95"),
        close_price=Decimal("105"),
        base_volume=Decimal("10"),
        quote_volume=Decimal("1025"),
        trade_count=100,
        is_closed=True,
        quality_status=QualityStatus.VALID,
    )
    event = IncomingEvent(
        event_id=uuid4(),
        event_type="KLINE_CLOSED",
        schema_version=1,
        source=MarketSource.WEBSOCKET,
        exchange_event_time=payload.close_time,
        collected_at=payload.close_time,
        node_id="test-node",
        shard_id="0",
        payload=payload.model_dump(mode="json"),
    )
    connection = MagicMock()
    empty_current = MagicMock()
    empty_current.mappings.return_value.one_or_none.return_value = None
    connection.execute = AsyncMock(
        side_effect=[MagicMock(), empty_current, MagicMock()]
    )
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = MarketRepository(engine)
    repository._instrument_id = AsyncMock(return_value=1)  # type: ignore[method-assign]

    await repository._write_kline(event, payload)

    statements = [str(call.args[0]) for call in connection.execute.await_args_list]
    assert "set_config('plan_cache_mode', 'force_custom_plan', true)" in statements[0]
    assert "FOR UPDATE" in statements[1]
    assert "INSERT INTO market.klines" in statements[2]


async def test_realtime_mark_minutes_derive_closed_mark_5m() -> None:
    opened = datetime(2026, 11, 4, 1, 25, tzinfo=UTC)
    source_ids = [uuid4() for _index in range(5)]
    rows = [
        {
            "open_time": opened + timedelta(minutes=index),
            "open_price": Decimal(str(100 + index)),
            "high_price": Decimal(str(105 + index)),
            "low_price": Decimal(str(95 + index)),
            "close_price": Decimal(str(101 + index)),
            "quality_status": "VALID",
            "source_event_ids": [source_ids[index]],
        }
        for index in range(5)
    ]
    source_result = MagicMock()
    source_result.mappings.return_value.all.return_value = rows
    current_result = MagicMock()
    current_result.mappings.return_value.one_or_none.return_value = None
    connection = MagicMock()
    connection.execute = AsyncMock(
        side_effect=[MagicMock(), source_result, current_result, MagicMock()]
    )
    repository = MarketRepository(MagicMock())

    await repository._derive_realtime_mark_5m(
        connection,
        instrument_id=1,
        symbol="BTCUSDT",
        minute_open_time=opened + timedelta(minutes=4),
        collected_at=opened + timedelta(minutes=5, seconds=1),
    )

    statements = [str(call.args[0]) for call in connection.execute.await_args_list]
    assert "pg_advisory_xact_lock" in statements[0]
    assert "interval_seconds = 60" in statements[1]
    assert "interval_seconds = 300" in statements[2]
    assert "'DERIVED'" in statements[3]
    parameters = connection.execute.await_args_list[3].args[1]
    assert parameters["open_time"] == opened
    assert parameters["close_time"] == opened + timedelta(minutes=5)
    assert parameters["open_price"] == Decimal("100")
    assert parameters["high_price"] == Decimal("109")
    assert parameters["low_price"] == Decimal("95")
    assert parameters["close_price"] == Decimal("105")
    assert parameters["source_event_ids"] == source_ids
    assert parameters["derivation_version"] == "mark-1m-to-5m-v1"


async def test_realtime_mark_minute_triggers_5m_derivation_after_persistence() -> None:
    opened = datetime(2026, 11, 4, 1, 29, tzinfo=UTC)
    payload = KlinePayload(
        symbol="BTCUSDT",
        price_type=PriceType.MARK,
        interval_seconds=60,
        open_time=opened,
        close_time=opened + timedelta(minutes=1),
        open_price=Decimal("100"),
        high_price=Decimal("101"),
        low_price=Decimal("99"),
        close_price=Decimal("100"),
        is_closed=True,
        quality_status=QualityStatus.VALID,
    )
    event = IncomingEvent(
        event_id=uuid4(),
        event_type="KLINE_CLOSED",
        schema_version=1,
        source=MarketSource.WEBSOCKET,
        exchange_event_time=payload.close_time,
        collected_at=payload.close_time + timedelta(seconds=1),
        node_id="test-node",
        shard_id="0",
        payload=payload.model_dump(mode="json"),
    )
    connection = MagicMock()
    empty_current = MagicMock()
    empty_current.mappings.return_value.one_or_none.return_value = None
    connection.execute = AsyncMock(
        side_effect=[MagicMock(), empty_current, MagicMock()]
    )
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = MarketRepository(engine)
    repository._instrument_id = AsyncMock(return_value=1)  # type: ignore[method-assign]
    repository._derive_realtime_mark_5m = AsyncMock()  # type: ignore[method-assign]

    await repository._write_kline(event, payload)

    repository._derive_realtime_mark_5m.assert_awaited_once_with(  # type: ignore[attr-defined]
        connection,
        instrument_id=1,
        symbol="BTCUSDT",
        minute_open_time=opened,
        collected_at=event.collected_at,
    )


async def test_realtime_mark_5m_waits_for_five_contiguous_minutes() -> None:
    opened = datetime(2026, 11, 4, 1, 25, tzinfo=UTC)
    result = MagicMock()
    result.mappings.return_value.all.return_value = [
        {
            "open_time": opened + timedelta(minutes=index),
            "open_price": Decimal("100"),
            "high_price": Decimal("101"),
            "low_price": Decimal("99"),
            "close_price": Decimal("100"),
            "quality_status": "VALID",
            "source_event_ids": [UUID(int=index + 1)],
        }
        for index in range(4)
    ]
    connection = MagicMock()
    connection.execute = AsyncMock(side_effect=[MagicMock(), result])
    repository = MarketRepository(MagicMock())

    await repository._derive_realtime_mark_5m(
        connection,
        instrument_id=1,
        symbol="BTCUSDT",
        minute_open_time=opened + timedelta(minutes=4),
        collected_at=opened + timedelta(minutes=5, seconds=1),
    )

    assert connection.execute.await_count == 2


async def test_realtime_mark_5m_does_not_replace_exchange_sourced_bar() -> None:
    opened = datetime(2026, 11, 4, 1, 25, tzinfo=UTC)
    rows = [
        {
            "open_time": opened + timedelta(minutes=index),
            "open_price": Decimal("100"),
            "high_price": Decimal("101"),
            "low_price": Decimal("99"),
            "close_price": Decimal("100"),
            "quality_status": "VALID",
            "source_event_ids": [UUID(int=index + 1)],
        }
        for index in range(5)
    ]
    source_result = MagicMock()
    source_result.mappings.return_value.all.return_value = rows
    current_result = MagicMock()
    current_result.mappings.return_value.one_or_none.return_value = {
        "revision_no": 1,
        "payload_hash": "different",
        "source": "BACKFILL",
    }
    connection = MagicMock()
    connection.execute = AsyncMock(
        side_effect=[MagicMock(), source_result, current_result]
    )
    repository = MarketRepository(MagicMock())

    await repository._derive_realtime_mark_5m(
        connection,
        instrument_id=1,
        symbol="BTCUSDT",
        minute_open_time=opened + timedelta(minutes=4),
        collected_at=opened + timedelta(minutes=5, seconds=1),
    )

    assert connection.execute.await_count == 3


async def test_historical_mark_minute_does_not_trigger_realtime_aggregation() -> None:
    opened = datetime(2026, 11, 4, 1, 25, tzinfo=UTC)
    payload = KlinePayload(
        symbol="BTCUSDT",
        price_type=PriceType.MARK,
        interval_seconds=60,
        open_time=opened,
        close_time=opened + timedelta(minutes=1),
        open_price=Decimal("100"),
        high_price=Decimal("101"),
        low_price=Decimal("99"),
        close_price=Decimal("100"),
        is_closed=True,
        quality_status=QualityStatus.VALID,
    )
    event = IncomingEvent(
        event_id=uuid4(),
        event_type="KLINE_CLOSED",
        schema_version=1,
        source=MarketSource.BACKFILL,
        exchange_event_time=payload.close_time,
        collected_at=payload.close_time + timedelta(hours=1),
        node_id="test-node",
        shard_id="0",
        payload=payload.model_dump(mode="json"),
    )
    connection = MagicMock()
    empty_current = MagicMock()
    empty_current.mappings.return_value.one_or_none.return_value = None
    connection.execute = AsyncMock(
        side_effect=[MagicMock(), empty_current, MagicMock()]
    )
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = MarketRepository(engine)
    repository._instrument_id = AsyncMock(return_value=1)  # type: ignore[method-assign]

    await repository._write_kline(event, payload)

    assert connection.execute.await_count == 3
