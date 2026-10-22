from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

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
