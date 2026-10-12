from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import httpx
import pytest
from pydantic import BaseModel

from auto_trade.collectors.binance_usdm import (
    BinanceRateLimitError,
    BinanceUsdMClient,
)
from auto_trade.collectors.service import (
    BinanceCollectionService,
    KlineSeries,
    build_rolling_ranking_entries,
    parse_instrument_rules,
)
from auto_trade.contracts import (
    EventEnvelope,
    InstrumentRulePayload,
    MarketSource,
    PriceType,
)


def instrument(symbol: str = "BTCUSDT") -> dict[str, object]:
    return {
        "symbol": symbol,
        "baseAsset": symbol.removesuffix("USDT"),
        "quoteAsset": "USDT",
        "contractType": "PERPETUAL",
        "status": "TRADING",
        "onboardDate": 1_600_000_000_000,
        "pricePrecision": 2,
        "quantityPrecision": 3,
        "filters": [
            {"filterType": "PRICE_FILTER", "tickSize": "0.10"},
            {
                "filterType": "LOT_SIZE",
                "stepSize": "0.001",
                "minQty": "0.001",
                "maxQty": "1000",
            },
            {
                "filterType": "MARKET_LOT_SIZE",
                "stepSize": "0.001",
                "minQty": "0.001",
                "maxQty": "100",
            },
            {"filterType": "MIN_NOTIONAL", "notional": "5"},
            {"filterType": "MAX_NUM_ORDERS", "limit": 200},
            {"filterType": "MAX_NUM_ALGO_ORDERS", "limit": 10},
        ],
    }


class RecordingPublisher:
    def __init__(self) -> None:
        self.messages: list[tuple[str, EventEnvelope[BaseModel]]] = []

    async def publish(self, subject: str, event: EventEnvelope[BaseModel]) -> None:
        self.messages.append((subject, event))


async def test_rate_limit_is_not_retried_and_preserves_retry_after() -> None:
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(429, headers={"Retry-After": "17"})

    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=1,
        attempts=3,
        transport=httpx.MockTransport(handler),
    )
    try:
        with pytest.raises(BinanceRateLimitError) as captured:
            await client.ticker_24h()
    finally:
        await client.aclose()

    assert calls == 1
    assert captured.value.status_code == 429
    assert captured.value.retry_after_seconds == 17


def test_parse_instrument_rules_keeps_only_usdt_perpetual() -> None:
    coin_m = instrument("BTCUSDT") | {"quoteAsset": "USD"}
    dated = instrument("ETHUSDT") | {"contractType": "CURRENT_QUARTER"}
    parsed = parse_instrument_rules({"symbols": [instrument(), coin_m, dated]})
    assert len(parsed) == 1
    assert parsed[0].symbol == "BTCUSDT"
    assert str(parsed[0].tick_size) == "0.10"
    assert str(parsed[0].min_notional) == "5"


def test_parse_instrument_rules_accepts_unicode_binance_symbol() -> None:
    unicode_contract = instrument("币安人生USDT") | {"baseAsset": "币安人生"}
    parsed = parse_instrument_rules({"symbols": [unicode_contract]})
    assert parsed[0].symbol == "币安人生USDT"


def test_rolling_ranking_is_descending_and_stable() -> None:
    common: dict[str, object] = {
        "lastPrice": "105",
        "openPrice": "100",
        "volume": "12",
        "quoteVolume": "1200",
        "highPrice": "110",
        "lowPrice": "90",
        "openTime": 1,
        "closeTime": 2,
    }
    tickers = {
        "ETHUSDT": common | {"symbol": "ETHUSDT", "priceChangePercent": "5"},
        "BTCUSDT": common | {"symbol": "BTCUSDT", "priceChangePercent": "5"},
        "XRPUSDT": common | {"symbol": "XRPUSDT", "priceChangePercent": "9"},
    }
    entries = build_rolling_ranking_entries(tickers, set(tickers))
    assert [entry.symbol for entry in entries] == ["XRPUSDT", "BTCUSDT", "ETHUSDT"]
    assert [entry.rank_no for entry in entries] == [1, 2, 3]
    assert entries[0].amplitude == Decimal("20")


def test_event_envelope_serializes_concrete_payload_fields() -> None:
    rule = parse_instrument_rules({"symbols": [instrument()]})[0]
    event = EventEnvelope[BaseModel](
        event_id=uuid4(),
        event_type="INSTRUMENT_RULE_SNAPSHOT",
        source=MarketSource.REST,
        collected_at=datetime.now(UTC),
        node_id="test-node",
        payload=rule,
    )
    serialized = event.model_dump_json()
    restored = EventEnvelope[InstrumentRulePayload].model_validate_json(serialized)
    assert restored.payload.symbol == "BTCUSDT"
    assert restored.payload.tick_size == Decimal("0.10")


async def test_collection_cycle_reuses_each_binance_response() -> None:
    now = datetime.now(UTC)
    current_ms = int(now.timestamp() * 1000)
    open_ms = int((now - timedelta(minutes=10)).timestamp() * 1000)
    close_ms = open_ms + 300_000 - 1
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path.endswith("exchangeInfo"):
            payload: object = {"symbols": [instrument()]}
        elif request.url.path.endswith("ticker/24hr"):
            payload = [
                {
                    "symbol": "BTCUSDT",
                    "lastPrice": "60000",
                    "priceChangePercent": "2.50",
                    "openTime": current_ms - 86_400_000,
                    "closeTime": current_ms,
                    "openPrice": "58500",
                    "quoteVolume": "123456789",
                    "highPrice": "61000",
                    "lowPrice": "58000",
                }
            ]
        elif request.url.path.endswith("premiumIndex"):
            payload = [
                {
                    "symbol": "BTCUSDT",
                    "markPrice": "60001",
                    "indexPrice": "59999",
                    "lastFundingRate": "0.0001",
                    "nextFundingTime": current_ms + 3_600_000,
                }
            ]
        elif request.url.path.endswith("klines"):
            payload = [
                [
                    open_ms,
                    "59000",
                    "60500",
                    "58800",
                    "60000",
                    "12.5",
                    close_ms,
                    "750000",
                    321,
                    "6.0",
                    "360000",
                    "0",
                ]
            ]
        elif request.url.path.endswith("openInterest"):
            payload = {
                "symbol": "BTCUSDT",
                "openInterest": "123.45",
                "time": current_ms,
            }
        else:
            return httpx.Response(404)
        return httpx.Response(
            200,
            json=payload,
            headers={"x-mbx-used-weight-1m": "10"},
        )

    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=2,
        attempts=1,
        transport=httpx.MockTransport(handler),
    )
    async with client:
        service = BinanceCollectionService(
            client=client,
            publisher=publisher,
            node_id="test-node",
            shard_id="0",
        )
        summary = await service.collect_once({"BTCUSDT", "MISSINGUSDT"})

    assert summary.instruments == 1
    assert summary.ticker_minutes == 1
    assert summary.klines_5m == 1
    assert summary.open_interest_5m == 1
    assert summary.skipped_symbols == ("MISSINGUSDT",)
    assert calls.count("/fapi/v1/exchangeInfo") == 1
    assert calls.count("/fapi/v1/ticker/24hr") == 1
    assert calls.count("/fapi/v1/premiumIndex") == 1
    assert calls.count("/fapi/v1/klines") == 1
    assert calls.count("/fapi/v1/openInterest") == 1
    subjects = {subject for subject, _event in publisher.messages}
    assert "market.normalized.ticker.1m.BTCUSDT" in subjects
    assert "market.normalized.kline.5m.trade.BTCUSDT" in subjects
    assert "market.normalized.open_interest.5m.BTCUSDT" in subjects
    ticker_event = next(
        event
        for subject, event in publisher.messages
        if subject == "market.normalized.ticker.1m.BTCUSDT"
    )
    ticker_payload = ticker_event.payload.model_dump()
    assert ticker_payload["price_change_24h"] == Decimal("2.50")
    assert ticker_payload["current_funding_rate"] == Decimal("0.0001")
    oi_event = next(
        event
        for subject, event in publisher.messages
        if subject == "market.normalized.open_interest.5m.BTCUSDT"
    )
    oi_payload = oi_event.payload.model_dump()
    assert oi_payload["open_interest_qty"] == Decimal("123.45")
    assert oi_payload["open_interest_value"] == Decimal("7407123.45")


async def test_closed_websocket_klines_publish_trade_and_mark_series() -> None:
    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=1,
        attempts=1,
        transport=httpx.MockTransport(lambda _request: httpx.Response(500)),
    )
    service = BinanceCollectionService(
        client=client,
        publisher=publisher,
        node_id="test-node",
        shard_id="0",
    )
    base_kline: dict[str, object] = {
        "s": "BTCUSDT",
        "i": "1m",
        "t": 1_600_000_020_000,
        "T": 1_600_000_079_999,
        "o": "100",
        "h": "110",
        "l": "90",
        "c": "105",
        "v": "12",
        "q": "1200",
        "n": 7,
        "x": True,
    }
    try:
        assert await service.publish_websocket_kline(
            {"stream": "btcusdt@kline_1m", "data": {"e": "kline", "k": base_kline}}
        )
        assert await service.publish_websocket_kline(
            {
                "stream": "btcusdt@markPriceKline_1m",
                "data": {"e": "markPrice_kline", "k": base_kline},
            }
        )
        assert await service.publish_websocket_kline(
            {
                "stream": "btcusdt@kline_5m",
                "data": {"e": "kline", "k": base_kline | {"i": "5m"}},
            }
        )
    finally:
        await client.aclose()

    normalized = [
        (subject, event.payload)
        for subject, event in publisher.messages
        if subject.startswith("market.normalized")
    ]
    assert [subject for subject, _payload in normalized] == [
        "market.normalized.kline.1m.trade.BTCUSDT",
        "market.normalized.kline.1m.mark.BTCUSDT",
        "market.normalized.kline.5m.trade.BTCUSDT",
    ]
    assert normalized[0][1].price_type is PriceType.TRADE
    assert normalized[0][1].base_volume == Decimal("12")
    assert normalized[1][1].price_type is PriceType.MARK
    assert normalized[1][1].base_volume is None
    assert normalized[2][1].interval_seconds == 300


async def test_websocket_market_cache_publishes_ticker_snapshot_without_rest() -> None:
    now = datetime.now(UTC)
    current_minute = now.replace(second=0, microsecond=0)
    current_ms = int(current_minute.timestamp() * 1000)
    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=1,
        attempts=1,
        transport=httpx.MockTransport(lambda _request: httpx.Response(500)),
    )
    service = BinanceCollectionService(
        client=client,
        publisher=publisher,
        node_id="test-node",
        shard_id="0",
    )
    service.set_active_symbols({"BTCUSDT"})
    try:
        ticker_message = {
            "stream": "!ticker@arr",
            "data": [
                {
                    "e": "24hrTicker",
                    "E": current_ms,
                    "s": "BTCUSDT",
                    "c": "60000",
                    "P": "2.5",
                    "O": current_ms - 86_400_000,
                    "C": current_ms,
                    "o": "58500",
                    "q": "123456789",
                    "h": "61000",
                    "l": "58000",
                }
            ],
        }
        assert not await service.publish_websocket_kline(ticker_message)
        assert await service.observe_websocket_market(
            ticker_message
        )
        assert await service.observe_websocket_market(
            {
                "stream": "!markPrice@arr@1s",
                "data": [
                    {
                        "e": "markPriceUpdate",
                        "E": current_ms,
                        "s": "BTCUSDT",
                        "p": "60001",
                        "i": "59999",
                        "r": "0.0001",
                        "T": current_ms + 3_600_000,
                    }
                ],
            }
        )
        assert await service.observe_websocket_market(
            {
                "stream": "!markPrice@arr@1s",
                "data": [
                    {
                        "e": "markPriceUpdate",
                        "E": current_ms + 60_000,
                        "s": "BTCUSDT",
                        "p": "60003",
                        "i": "60001",
                        "r": "0.0001",
                        "T": current_ms + 3_600_000,
                    }
                ],
            }
        )
        assert await service.publish_websocket_ticker_minutes({"BTCUSDT"}) == 1
    finally:
        await client.aclose()

    ticker_event = next(
        event
        for subject, event in publisher.messages
        if subject == "market.normalized.ticker.1m.BTCUSDT"
    )
    assert ticker_event.source is MarketSource.WEBSOCKET
    assert ticker_event.payload.price_change_24h == Decimal("2.5")
    assert ticker_event.payload.current_funding_rate == Decimal("0.0001")
    mark_kline_event = next(
        event
        for subject, event in publisher.messages
        if subject == "market.normalized.kline.1m.mark.BTCUSDT"
    )
    assert mark_kline_event.source is MarketSource.WEBSOCKET
    assert mark_kline_event.payload.open_time == current_minute
    assert mark_kline_event.payload.close_price == Decimal("60001")


def test_kline_series_preserves_legacy_5m_repair_type() -> None:
    assert KlineSeries(PriceType.TRADE, 300).data_type == "KLINE"
    assert KlineSeries(PriceType.TRADE, 60).data_type == "KLINE_TRADE"
    assert KlineSeries(PriceType.MARK, 60).data_type == "KLINE_MARK"


async def test_one_minute_rest_skips_trade_already_closed_by_websocket() -> None:
    now = datetime.now(UTC)
    open_time = now.replace(second=0, microsecond=0) - timedelta(minutes=1)
    open_ms = int(open_time.timestamp() * 1000)
    close_ms = open_ms + 60_000 - 1
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        return httpx.Response(
            200,
            json=[
                [
                    open_ms,
                    "100",
                    "110",
                    "90",
                    "105",
                    "0",
                    close_ms,
                    "0",
                    60,
                    "0",
                    "0",
                    "0",
                ]
            ],
        )

    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=2,
        attempts=1,
        transport=httpx.MockTransport(handler),
    )
    async with client:
        service = BinanceCollectionService(
            client=client,
            publisher=publisher,
            node_id="test-node",
            shard_id="0",
        )
        await service.publish_websocket_kline(
            {
                "stream": "btcusdt@kline_1m",
                "data": {
                    "e": "kline",
                    "k": {
                        "s": "BTCUSDT",
                        "i": "1m",
                        "t": open_ms,
                        "T": close_ms,
                        "o": "100",
                        "h": "110",
                        "l": "90",
                        "c": "105",
                        "v": "12",
                        "q": "1200",
                        "n": 7,
                        "x": True,
                    },
                },
            }
        )
        trade_count, mark_count = await service.collect_1m_klines({"BTCUSDT"})

    assert trade_count == 0
    assert mark_count == 1
    assert calls == ["/fapi/v1/markPriceKlines"]


async def test_one_minute_rest_skips_mark_already_closed_by_websocket() -> None:
    now = datetime.now(UTC)
    open_time = now.replace(second=0, microsecond=0) - timedelta(minutes=1)
    next_minute = open_time + timedelta(minutes=1)
    open_ms = int(open_time.timestamp() * 1000)
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        return httpx.Response(
            200,
            json=[
                [
                    open_ms,
                    "100",
                    "110",
                    "90",
                    "105",
                    "12",
                    open_ms + 60_000 - 1,
                    "1200",
                    7,
                    "0",
                    "0",
                    "0",
                ]
            ],
        )

    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=2,
        attempts=1,
        transport=httpx.MockTransport(handler),
    )
    async with client:
        service = BinanceCollectionService(
            client=client,
            publisher=publisher,
            node_id="test-node",
            shard_id="0",
        )
        service.set_active_symbols({"BTCUSDT"})
        for event_time, price in (
            (open_time + timedelta(seconds=30), "60000"),
            (next_minute + timedelta(seconds=1), "60001"),
        ):
            assert await service.observe_websocket_market(
                {
                    "stream": "!markPrice@arr@1s",
                    "data": [
                        {
                            "e": "markPriceUpdate",
                            "E": int(event_time.timestamp() * 1000),
                            "s": "BTCUSDT",
                            "p": price,
                            "i": price,
                            "r": "0.0001",
                            "T": int((event_time + timedelta(hours=1)).timestamp() * 1000),
                        }
                    ],
                }
            )
        trade_count, mark_count = await service.collect_1m_klines({"BTCUSDT"})

    assert trade_count == 1
    assert mark_count == 0
    assert calls == ["/fapi/v1/klines"]


async def test_one_minute_flushes_cached_mark_minute_before_rest_fallback() -> None:
    now = datetime.now(UTC)
    open_time = now.replace(second=0, microsecond=0) - timedelta(minutes=1)
    open_ms = int(open_time.timestamp() * 1000)
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        return httpx.Response(
            200,
            json=[
                [
                    open_ms,
                    "100",
                    "110",
                    "90",
                    "105",
                    "12",
                    open_ms + 60_000 - 1,
                    "1200",
                    7,
                    "0",
                    "0",
                    "0",
                ]
            ],
        )

    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=2,
        attempts=1,
        transport=httpx.MockTransport(handler),
    )
    async with client:
        service = BinanceCollectionService(
            client=client,
            publisher=publisher,
            node_id="test-node",
            shard_id="0",
        )
        service.set_active_symbols({"BTCUSDT"})
        assert await service.observe_websocket_market(
            {
                "stream": "!markPrice@arr@1s",
                "data": [
                    {
                        "e": "markPriceUpdate",
                        "E": open_ms + 30_000,
                        "s": "BTCUSDT",
                        "p": "60000",
                        "i": "60000",
                        "r": "0.0001",
                        "T": open_ms + 3_600_000,
                    }
                ],
            }
        )
        trade_count, mark_count = await service.collect_1m_klines({"BTCUSDT"})
        assert await service.observe_websocket_market(
            {
                "stream": "!markPrice@arr@1s",
                "data": [
                    {
                        "e": "markPriceUpdate",
                        "E": open_ms + 60_001,
                        "s": "BTCUSDT",
                        "p": "60001",
                        "i": "60001",
                        "r": "0.0001",
                        "T": open_ms + 3_600_000,
                    }
                ],
            }
        )

    assert trade_count == 1
    assert mark_count == 0
    assert calls == ["/fapi/v1/klines"]
    mark_events = [
        event
        for subject, event in publisher.messages
        if subject == "market.normalized.kline.1m.mark.BTCUSDT"
    ]
    assert len(mark_events) == 1
    assert mark_events[0].payload.open_time == open_time


async def test_five_minute_rest_skips_trade_already_closed_by_websocket() -> None:
    now = datetime.now(UTC)
    current_open = now.replace(
        minute=now.minute - now.minute % 5,
        second=0,
        microsecond=0,
    )
    open_time = current_open - timedelta(minutes=5)
    open_ms = int(open_time.timestamp() * 1000)
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        return httpx.Response(500)

    publisher = RecordingPublisher()
    client = BinanceUsdMClient(
        base_url="https://example.test",
        timeout_seconds=1,
        max_concurrency=2,
        attempts=1,
        transport=httpx.MockTransport(handler),
    )
    async with client:
        service = BinanceCollectionService(
            client=client,
            publisher=publisher,
            node_id="test-node",
            shard_id="0",
        )
        assert await service.publish_websocket_kline(
            {
                "stream": "btcusdt@kline_5m",
                "data": {
                    "e": "kline",
                    "k": {
                        "s": "BTCUSDT",
                        "i": "5m",
                        "t": open_ms,
                        "T": open_ms + 300_000 - 1,
                        "o": "100",
                        "h": "110",
                        "l": "90",
                        "c": "105",
                        "v": "12",
                        "q": "1200",
                        "n": 7,
                        "x": True,
                    },
                },
            }
        )
        count = await service.collect_5m_klines({"BTCUSDT"})

    assert count == 0
    assert calls == []
