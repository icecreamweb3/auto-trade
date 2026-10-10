from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from pydantic import ValidationError

from auto_trade.contracts.market import (
    EventEnvelope,
    KlinePayload,
    MarketSource,
    PriceType,
    QualityStatus,
    deterministic_event_id,
)


def make_trade_kline() -> KlinePayload:
    opened = datetime(2026, 1, 1, tzinfo=UTC)
    return KlinePayload(
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


def test_deterministic_event_id_is_stable() -> None:
    first = deterministic_event_id("BINANCE", "BTCUSDT", "KLINE", 300, 1_767_225_600_000)
    second = deterministic_event_id("BINANCE", "BTCUSDT", "KLINE", 300, 1_767_225_600_000)
    assert first == second


def test_event_envelope_normalizes_timestamps_to_utc() -> None:
    payload = make_trade_kline()
    event = EventEnvelope[KlinePayload](
        event_id=deterministic_event_id("BTCUSDT", payload.open_time),
        event_type="market.kline.closed.v1",
        source=MarketSource.WEBSOCKET,
        exchange_event_time=payload.close_time,
        collected_at=payload.close_time,
        node_id="test-1",
        payload=payload,
    )
    assert event.collected_at.tzinfo is UTC


def test_naive_timestamp_is_rejected() -> None:
    payload = make_trade_kline()
    with pytest.raises(ValidationError, match="timezone-aware"):
        EventEnvelope[KlinePayload](
            event_id=deterministic_event_id("BTCUSDT", payload.open_time),
            event_type="market.kline.closed.v1",
            source=MarketSource.WEBSOCKET,
            collected_at=datetime(2026, 1, 1),
            node_id="test-1",
            payload=payload,
        )


def test_invalid_ohlc_is_rejected() -> None:
    with pytest.raises(ValidationError, match="high_price"):
        KlinePayload(
            symbol="BTCUSDT",
            price_type=PriceType.TRADE,
            interval_seconds=300,
            open_time=datetime(2026, 1, 1, tzinfo=UTC),
            close_time=datetime(2026, 1, 1, 0, 5, tzinfo=UTC),
            open_price=Decimal("100"),
            high_price=Decimal("99"),
            low_price=Decimal("90"),
            close_price=Decimal("98"),
            base_volume=Decimal("10"),
            quote_volume=Decimal("1000"),
            is_closed=True,
            quality_status=QualityStatus.VALID,
        )

