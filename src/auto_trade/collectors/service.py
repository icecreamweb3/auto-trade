from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import cast

from pydantic import BaseModel, ConfigDict, Field

from auto_trade.collectors.binance_usdm import BinanceResult, BinanceUsdMClient, JsonObject
from auto_trade.collectors.publisher import EventPublisher
from auto_trade.contracts import (
    EventEnvelope,
    InstrumentCatalogPayload,
    InstrumentRulePayload,
    KlinePayload,
    MarketSource,
    OpenInterestPayload,
    PriceType,
    QualityStatus,
    RankingEntryPayload,
    RankingSnapshotPayload,
    TickerMinutePayload,
    deterministic_event_id,
)

logger = logging.getLogger(__name__)


class RawExchangePayload(BaseModel):
    model_config = ConfigDict(frozen=True)

    endpoint: str
    request_params: dict[str, str | int] = Field(default_factory=dict)
    response: object
    used_weight_1m: int | None = None
    request_rate_1m: int | None = None


@dataclass(frozen=True, slots=True)
class CollectionSummary:
    instruments: int
    ticker_minutes: int
    klines_5m: int
    open_interest_5m: int
    skipped_symbols: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class KlineSeries:
    price_type: PriceType
    interval_seconds: int

    @property
    def binance_interval(self) -> str:
        if self.interval_seconds == 60:
            return "1m"
        if self.interval_seconds == 300:
            return "5m"
        raise ValueError(f"unsupported source kline interval: {self.interval_seconds}")

    @property
    def data_type(self) -> str:
        if self.price_type is PriceType.TRADE and self.interval_seconds == 300:
            return "KLINE"
        return f"KLINE_{self.price_type.value}"


TRADE_5M_SERIES = KlineSeries(PriceType.TRADE, 300)


@dataclass(slots=True)
class MarkMinuteState:
    open_time: datetime
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal


def _utc_from_ms(value: object) -> datetime:
    if not isinstance(value, (int, float)):
        raise TypeError(f"expected millisecond timestamp, got {value!r}")
    return datetime.fromtimestamp(value / 1000, tz=UTC)


def _decimal(value: object | None) -> Decimal | None:
    if value is None or value == "":
        return None
    return Decimal(str(value))


def _int(value: object) -> int:
    return int(str(value))


def _as_object(value: object) -> JsonObject:
    if not isinstance(value, dict):
        raise TypeError(f"expected object, got {type(value).__name__}")
    return cast(JsonObject, value)


def _as_object_list(value: object) -> list[JsonObject]:
    if not isinstance(value, list):
        raise TypeError(f"expected array, got {type(value).__name__}")
    return [_as_object(item) for item in value]


def _payload_hash(payload: object) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(canonical.encode()).hexdigest()


def build_rolling_ranking_entries(
    tickers: dict[str, JsonObject], symbols: set[str]
) -> tuple[RankingEntryPayload, ...]:
    ranked = sorted(
        (
            item
            for symbol, item in tickers.items()
            if symbol in symbols and item.get("priceChangePercent") is not None
        ),
        key=lambda item: (
            -Decimal(str(item["priceChangePercent"])),
            str(item["symbol"]),
        ),
    )[:50]
    entries: list[RankingEntryPayload] = []
    for rank_no, item in enumerate(ranked, start=1):
        open_price = Decimal(str(item["openPrice"]))
        high_price = Decimal(str(item["highPrice"]))
        low_price = Decimal(str(item["lowPrice"]))
        entries.append(
            RankingEntryPayload(
                rank_no=rank_no,
                symbol=str(item["symbol"]),
                price_change=Decimal(str(item["priceChangePercent"])),
                reference_open_price=open_price,
                snapshot_price=Decimal(str(item["lastPrice"])),
                base_volume=_decimal(item.get("volume")),
                quote_volume=_decimal(item.get("quoteVolume")),
                amplitude=(high_price - low_price) / open_price * Decimal("100"),
                period_high_price=high_price,
                period_low_price=low_price,
                metrics={
                    "binance_window_start": item.get("openTime"),
                    "binance_window_end": item.get("closeTime"),
                },
            )
        )
    return tuple(entries)


def parse_instrument_rules(exchange_info: JsonObject) -> list[InstrumentRulePayload]:
    symbols = _as_object_list(exchange_info.get("symbols", []))
    parsed: list[InstrumentRulePayload] = []
    for item in symbols:
        if item.get("quoteAsset") != "USDT" or item.get("contractType") != "PERPETUAL":
            continue
        filters = {
            str(filter_item.get("filterType")): filter_item
            for filter_item in _as_object_list(item.get("filters", []))
        }
        price_filter = filters.get("PRICE_FILTER", {})
        lot_size = filters.get("LOT_SIZE", {})
        market_lot = filters.get("MARKET_LOT_SIZE", {})
        min_notional = filters.get("MIN_NOTIONAL", filters.get("NOTIONAL", {}))
        percent_price = filters.get("PERCENT_PRICE", {})
        max_orders = filters.get("MAX_NUM_ORDERS", {})
        max_algo_orders = filters.get("MAX_NUM_ALGO_ORDERS", {})
        onboard_at = item.get("onboardDate")
        parsed.append(
            InstrumentRulePayload(
                symbol=str(item["symbol"]),
                base_asset=str(item["baseAsset"]),
                trading_status=str(item["status"]),
                onboard_at=_utc_from_ms(onboard_at) if onboard_at is not None else None,
                price_precision=_int(item["pricePrecision"]),
                quantity_precision=_int(item["quantityPrecision"]),
                tick_size=Decimal(str(price_filter["tickSize"])),
                step_size=Decimal(str(lot_size["stepSize"])),
                min_quantity=_decimal(lot_size.get("minQty")),
                max_quantity=_decimal(lot_size.get("maxQty")),
                min_notional=_decimal(min_notional.get("notional")),
                market_step_size=_decimal(market_lot.get("stepSize")),
                market_min_quantity=_decimal(market_lot.get("minQty")),
                market_max_quantity=_decimal(market_lot.get("maxQty")),
                max_open_orders=(
                    _int(max_orders["limit"]) if max_orders.get("limit") is not None else None
                ),
                max_algo_orders=(
                    _int(max_algo_orders["limit"])
                    if max_algo_orders.get("limit") is not None
                    else None
                ),
                percent_price_rules=percent_price,
                complete_rule_payload=item,
            )
        )
    return parsed


class BinanceCollectionService:
    def __init__(
        self,
        *,
        client: BinanceUsdMClient,
        publisher: EventPublisher,
        node_id: str,
        shard_id: str,
    ) -> None:
        self._client = client
        self._publisher = publisher
        self._node_id = node_id
        self._shard_id = shard_id
        self._latest_mark_prices: dict[str, Decimal] = {}
        self._websocket_trade_closes: dict[str, datetime] = {}
        self._websocket_trade_5m_closes: dict[str, datetime] = {}
        self._websocket_mark_closes: dict[str, datetime] = {}
        self._websocket_tickers: dict[str, JsonObject] = {}
        self._websocket_premiums: dict[str, JsonObject] = {}
        self._websocket_mark_minutes: dict[str, MarkMinuteState] = {}
        self._active_symbols: frozenset[str] = frozenset()

    def set_active_symbols(self, symbols: set[str]) -> None:
        self._active_symbols = frozenset(symbols)
        self._websocket_tickers = {
            symbol: value
            for symbol, value in self._websocket_tickers.items()
            if symbol in self._active_symbols
        }
        self._websocket_premiums = {
            symbol: value
            for symbol, value in self._websocket_premiums.items()
            if symbol in self._active_symbols
        }
        self._websocket_mark_minutes = {
            symbol: value
            for symbol, value in self._websocket_mark_minutes.items()
            if symbol in self._active_symbols
        }
        self._websocket_trade_closes = {
            symbol: value
            for symbol, value in self._websocket_trade_closes.items()
            if symbol in self._active_symbols
        }
        self._websocket_trade_5m_closes = {
            symbol: value
            for symbol, value in self._websocket_trade_5m_closes.items()
            if symbol in self._active_symbols
        }
        self._websocket_mark_closes = {
            symbol: value
            for symbol, value in self._websocket_mark_closes.items()
            if symbol in self._active_symbols
        }

    def _event(
        self,
        *,
        event_type: str,
        source: MarketSource,
        collected_at: datetime,
        business_key: tuple[object, ...],
        payload: BaseModel,
        exchange_event_time: datetime | None = None,
    ) -> EventEnvelope[BaseModel]:
        return EventEnvelope[BaseModel](
            event_id=deterministic_event_id(event_type, *business_key),
            event_type=event_type,
            source=source,
            exchange_event_time=exchange_event_time,
            collected_at=collected_at,
            node_id=self._node_id,
            shard_id=self._shard_id,
            payload=payload,
        )

    async def _publish_raw(
        self,
        *,
        name: str,
        endpoint: str,
        result: BinanceResult,
        collected_at: datetime,
        params: dict[str, str | int] | None = None,
        symbol: str | None = None,
        source: MarketSource = MarketSource.REST,
    ) -> None:
        payload = RawExchangePayload(
            endpoint=endpoint,
            request_params=params or {},
            response=result.payload,
            used_weight_1m=result.used_weight_1m,
            request_rate_1m=result.request_rate_1m,
        )
        event = self._event(
            event_type=f"BINANCE_{name.upper()}_RAW",
            source=source,
            collected_at=collected_at,
            business_key=(
                name,
                symbol or "ALL",
                collected_at.isoformat(),
                _payload_hash(result.payload),
            ),
            payload=payload,
        )
        suffix = f".{symbol}" if symbol else ""
        await self._publisher.publish(f"raw.market.binance.{name}{suffix}", event)

    async def collect_once(self, symbols: set[str] | None = None) -> CollectionSummary:
        instruments = await self.sync_instruments()
        trading = {item.symbol for item in instruments if item.trading_status == "TRADING"}
        selected = trading if symbols is None else trading.intersection(symbols)
        skipped = tuple(sorted((symbols or set()) - selected))
        ticker_count = await self.collect_ticker_minutes(selected)
        kline_count, open_interest_count = await asyncio.gather(
            self.collect_5m_klines(selected),
            self.collect_open_interest(selected),
        )
        return CollectionSummary(
            instruments=len(instruments),
            ticker_minutes=ticker_count,
            klines_5m=kline_count,
            open_interest_5m=open_interest_count,
            skipped_symbols=skipped,
        )

    async def sync_instruments(self) -> list[InstrumentRulePayload]:
        exchange_result = await self._client.exchange_info()
        exchange_collected_at = datetime.now(UTC)
        await self._publish_raw(
            name="exchange_info",
            endpoint="/fapi/v1/exchangeInfo",
            result=exchange_result,
            collected_at=exchange_collected_at,
        )
        exchange_info = _as_object(exchange_result.payload)
        instruments = parse_instrument_rules(exchange_info)
        self.set_active_symbols(
            {
                instrument.symbol
                for instrument in instruments
                if instrument.trading_status == "TRADING"
            }
        )
        for instrument in instruments:
            event = self._event(
                event_type="INSTRUMENT_RULE_SNAPSHOT",
                source=MarketSource.REST,
                collected_at=exchange_collected_at,
                business_key=(instrument.symbol, _payload_hash(instrument.complete_rule_payload)),
                payload=instrument,
            )
            await self._publisher.publish(
                f"market.normalized.instrument.rule.{instrument.symbol}", event
            )

        catalog = InstrumentCatalogPayload(
            snapshot_time=exchange_collected_at,
            symbols=tuple(sorted(item.symbol for item in instruments)),
        )
        catalog_event = self._event(
            event_type="INSTRUMENT_CATALOG_SNAPSHOT",
            source=MarketSource.REST,
            collected_at=exchange_collected_at,
            business_key=(
                exchange_collected_at.isoformat(),
                _payload_hash(catalog.symbols),
            ),
            payload=catalog,
        )
        await self._publisher.publish("market.normalized.instrument.catalog", catalog_event)
        return instruments

    async def collect_ticker_minutes(self, symbols: set[str]) -> int:
        ticker_result, premium_result = await asyncio.gather(
            self._client.ticker_24h(), self._client.premium_index()
        )
        market_collected_at = datetime.now(UTC)
        await asyncio.gather(
            self._publish_raw(
                name="ticker_24h",
                endpoint="/fapi/v1/ticker/24hr",
                result=ticker_result,
                collected_at=market_collected_at,
            ),
            self._publish_raw(
                name="premium_index",
                endpoint="/fapi/v1/premiumIndex",
                result=premium_result,
                collected_at=market_collected_at,
            ),
        )
        tickers = {str(item["symbol"]): item for item in _as_object_list(ticker_result.payload)}
        premiums = {str(item["symbol"]): item for item in _as_object_list(premium_result.payload)}
        self._latest_mark_prices = {
            symbol: Decimal(str(item["markPrice"]))
            for symbol, item in premiums.items()
            if item.get("markPrice") not in (None, "")
        }
        ticker_count = 0
        minute_time = market_collected_at.replace(second=0, microsecond=0)
        for symbol in sorted(symbols):
            ticker = tickers.get(symbol)
            if ticker is None:
                continue
            premium = premiums.get(symbol)
            quality = QualityStatus.VALID if premium is not None else QualityStatus.PARTIAL
            payload = TickerMinutePayload(
                symbol=symbol,
                minute_time=minute_time,
                last_price=Decimal(str(ticker["lastPrice"])),
                mark_price=_decimal(premium.get("markPrice")) if premium else None,
                index_price=_decimal(premium.get("indexPrice")) if premium else None,
                price_change_24h=_decimal(ticker.get("priceChangePercent")),
                rolling_window_start=_utc_from_ms(ticker["openTime"]),
                rolling_window_end=_utc_from_ms(ticker["closeTime"]),
                rolling_open_price=_decimal(ticker.get("openPrice")),
                quote_volume_24h=_decimal(ticker.get("quoteVolume")),
                high_price_24h=_decimal(ticker.get("highPrice")),
                low_price_24h=_decimal(ticker.get("lowPrice")),
                current_funding_rate=_decimal(premium.get("lastFundingRate")) if premium else None,
                next_funding_time=(
                    _utc_from_ms(premium["nextFundingTime"])
                    if premium and premium.get("nextFundingTime")
                    else None
                ),
                quality_status=quality,
            )
            event = self._event(
                event_type="TICKER_MINUTE_SNAPSHOT",
                source=MarketSource.REST,
                collected_at=market_collected_at,
                exchange_event_time=_utc_from_ms(ticker["closeTime"]),
                business_key=(symbol, minute_time.isoformat()),
                payload=payload,
            )
            await self._publisher.publish(f"market.normalized.ticker.1m.{symbol}", event)
            ticker_count += 1
        if int(minute_time.timestamp()) % 300 == 0:
            await self._publish_rolling_ranking(
                tickers=tickers,
                symbols=symbols,
                snapshot_at=minute_time,
                generated_at=market_collected_at,
            )
        return ticker_count

    async def observe_websocket_market(self, message: JsonObject) -> bool:
        """Cache all-market ticker and mark-price updates for minute snapshots."""
        data = message.get("data", message)
        items = data if isinstance(data, list) else [data]
        handled = False
        for value in items:
            if not isinstance(value, dict):
                continue
            event_name = str(value.get("e", ""))
            symbol = str(value.get("s", ""))
            if symbol not in self._active_symbols:
                continue
            if event_name == "24hrTicker":
                self._websocket_tickers[symbol] = {
                    "symbol": symbol,
                    "lastPrice": value.get("c"),
                    "priceChangePercent": value.get("P"),
                    "openTime": value.get("O"),
                    "closeTime": value.get("C", value.get("E")),
                    "openPrice": value.get("o"),
                    "quoteVolume": value.get("q"),
                    "highPrice": value.get("h"),
                    "lowPrice": value.get("l"),
                }
                handled = True
            elif event_name == "markPriceUpdate":
                self._websocket_premiums[symbol] = {
                    "symbol": symbol,
                    "markPrice": value.get("p"),
                    "indexPrice": value.get("i"),
                    "lastFundingRate": value.get("r"),
                    "nextFundingTime": value.get("T"),
                }
                mark_price = value.get("p")
                if mark_price not in (None, ""):
                    price = Decimal(str(mark_price))
                    self._latest_mark_prices[symbol] = price
                    event_time = _utc_from_ms(value.get("E"))
                    minute_time = event_time.replace(second=0, microsecond=0)
                    state = self._websocket_mark_minutes.get(symbol)
                    if state is None or minute_time < state.open_time:
                        self._websocket_mark_minutes[symbol] = MarkMinuteState(
                            minute_time, price, price, price, price
                        )
                    elif minute_time == state.open_time:
                        state.high_price = max(state.high_price, price)
                        state.low_price = min(state.low_price, price)
                        state.close_price = price
                    else:
                        close_ms = int(
                            (state.open_time + timedelta(minutes=1)).timestamp() * 1000
                        ) - 1
                        await self._publish_kline_row(
                            symbol,
                            [
                                int(state.open_time.timestamp() * 1000),
                                state.open_price,
                                state.high_price,
                                state.low_price,
                                state.close_price,
                                "0",
                                close_ms,
                                "0",
                                0,
                            ],
                            datetime.now(UTC),
                            MarketSource.WEBSOCKET,
                            KlineSeries(PriceType.MARK, 60),
                        )
                        self._websocket_mark_closes[symbol] = state.open_time
                        self._websocket_mark_minutes[symbol] = MarkMinuteState(
                            minute_time, price, price, price, price
                        )
                handled = True
        return handled

    async def publish_websocket_ticker_minutes(self, symbols: set[str]) -> int:
        """Persist one minute snapshot from the latest WebSocket-only caches."""
        collected_at = datetime.now(UTC)
        minute_time = collected_at.replace(second=0, microsecond=0)
        tickers = dict(self._websocket_tickers)
        premiums = dict(self._websocket_premiums)
        await asyncio.gather(
            self._publish_raw(
                name="websocket_ticker_24h",
                endpoint="!ticker@arr",
                result=BinanceResult(list(tickers.values()), None),
                collected_at=collected_at,
                source=MarketSource.WEBSOCKET,
            ),
            self._publish_raw(
                name="websocket_premium_index",
                endpoint="!markPrice@arr@1s",
                result=BinanceResult(list(premiums.values()), None),
                collected_at=collected_at,
                source=MarketSource.WEBSOCKET,
            ),
        )
        ticker_count = 0
        for symbol in sorted(symbols):
            ticker = tickers.get(symbol)
            if ticker is None or ticker.get("lastPrice") in (None, ""):
                continue
            premium = premiums.get(symbol)
            quality = QualityStatus.VALID if premium is not None else QualityStatus.PARTIAL
            close_time = ticker.get("closeTime")
            payload = TickerMinutePayload(
                symbol=symbol,
                minute_time=minute_time,
                last_price=Decimal(str(ticker["lastPrice"])),
                mark_price=_decimal(premium.get("markPrice")) if premium else None,
                index_price=_decimal(premium.get("indexPrice")) if premium else None,
                price_change_24h=_decimal(ticker.get("priceChangePercent")),
                rolling_window_start=(
                    _utc_from_ms(ticker["openTime"])
                    if ticker.get("openTime") is not None
                    else None
                ),
                rolling_window_end=(
                    _utc_from_ms(close_time) if close_time is not None else None
                ),
                rolling_open_price=_decimal(ticker.get("openPrice")),
                quote_volume_24h=_decimal(ticker.get("quoteVolume")),
                high_price_24h=_decimal(ticker.get("highPrice")),
                low_price_24h=_decimal(ticker.get("lowPrice")),
                current_funding_rate=(
                    _decimal(premium.get("lastFundingRate")) if premium else None
                ),
                next_funding_time=(
                    _utc_from_ms(premium["nextFundingTime"])
                    if premium and premium.get("nextFundingTime")
                    else None
                ),
                quality_status=quality,
            )
            event = self._event(
                event_type="TICKER_MINUTE_SNAPSHOT",
                source=MarketSource.WEBSOCKET,
                collected_at=collected_at,
                exchange_event_time=(
                    _utc_from_ms(close_time) if close_time is not None else None
                ),
                business_key=(symbol, minute_time.isoformat()),
                payload=payload,
            )
            await self._publisher.publish(f"market.normalized.ticker.1m.{symbol}", event)
            ticker_count += 1
        if int(minute_time.timestamp()) % 300 == 0:
            await self._publish_rolling_ranking(
                tickers=tickers,
                symbols=symbols,
                snapshot_at=minute_time,
                generated_at=collected_at,
            )
        return ticker_count

    async def _publish_rolling_ranking(
        self,
        *,
        tickers: dict[str, JsonObject],
        symbols: set[str],
        snapshot_at: datetime,
        generated_at: datetime,
    ) -> None:
        entries = build_rolling_ranking_entries(tickers, symbols)
        payload = RankingSnapshotPayload(
            ranking_type="ROLLING_24H_5M",
            snapshot_at=snapshot_at,
            scheduled_at=snapshot_at,
            generated_at=generated_at,
            window_start=snapshot_at - timedelta(days=1),
            window_end=snapshot_at,
            entries=entries,
            quality_status=(
                QualityStatus.VALID if len(entries) == 50 else QualityStatus.PARTIAL
            ),
        )
        event = self._event(
            event_type="RANKING_SNAPSHOT",
            source=MarketSource.DERIVED,
            collected_at=generated_at,
            business_key=(payload.ranking_type, snapshot_at.isoformat()),
            payload=payload,
        )
        await self._publisher.publish("market.normalized.ranking.rolling_24h", event)

    async def collect_open_interest(self, symbols: set[str]) -> int:
        results = await asyncio.gather(
            *(self._collect_open_interest(symbol) for symbol in sorted(symbols)),
            return_exceptions=True,
        )
        for symbol, result in zip(sorted(symbols), results, strict=True):
            if isinstance(result, BaseException):
                logger.error(
                    "open interest collection failed symbol=%s error=%s",
                    symbol,
                    result,
                )
        return sum(1 for result in results if result is True)

    async def _collect_open_interest(self, symbol: str) -> bool:
        result = await self._client.open_interest(symbol)
        collected_at = datetime.now(UTC)
        await self._publish_raw(
            name="open_interest",
            endpoint="/fapi/v1/openInterest",
            result=result,
            collected_at=collected_at,
            params={"symbol": symbol},
            symbol=symbol,
        )
        item = _as_object(result.payload)
        exchange_time = _utc_from_ms(item["time"])
        quantity = Decimal(str(item["openInterest"]))
        mark_price = self._latest_mark_prices.get(symbol)
        payload = OpenInterestPayload(
            symbol=symbol,
            observed_at=exchange_time,
            open_interest_qty=quantity,
            mark_price=mark_price,
            open_interest_value=quantity * mark_price if mark_price is not None else None,
            quality_status=(
                QualityStatus.VALID if mark_price is not None else QualityStatus.PARTIAL
            ),
        )
        event = self._event(
            event_type="OPEN_INTEREST_SNAPSHOT",
            source=MarketSource.REST,
            collected_at=collected_at,
            exchange_event_time=exchange_time,
            business_key=(symbol, exchange_time.isoformat()),
            payload=payload,
        )
        await self._publisher.publish(f"market.normalized.open_interest.5m.{symbol}", event)
        return True

    async def collect_5m_klines(self, symbols: set[str]) -> int:
        now = datetime.now(UTC)
        current_open = now.replace(
            minute=now.minute - now.minute % 5,
            second=0,
            microsecond=0,
        )
        expected_open = current_open - timedelta(minutes=5)
        missing_symbols = {
            symbol
            for symbol in symbols
            if self._websocket_trade_5m_closes.get(symbol) != expected_open
        }
        results = await asyncio.gather(
            *(self._collect_latest_closed_5m(symbol) for symbol in sorted(missing_symbols)),
            return_exceptions=True,
        )
        count = 0
        for symbol, result in zip(sorted(missing_symbols), results, strict=True):
            if isinstance(result, BaseException):
                logger.error(
                    "five-minute kline collection failed symbol=%s error=%s",
                    symbol,
                    result,
                )
            else:
                count += result
        cutoff = expected_open - timedelta(minutes=10)
        self._websocket_trade_5m_closes = {
            symbol: open_time
            for symbol, open_time in self._websocket_trade_5m_closes.items()
            if open_time >= cutoff
        }
        return count

    async def collect_1m_klines(self, symbols: set[str]) -> tuple[int, int]:
        """REST-fetch only 1m series not confirmed closed by WebSocket."""
        now = datetime.now(UTC)
        expected_open = now.replace(second=0, microsecond=0) - timedelta(minutes=1)
        trade_symbols = {
            symbol
            for symbol in symbols
            if self._websocket_trade_closes.get(symbol) != expected_open
        }
        mark_symbols = {
            symbol
            for symbol in symbols
            if self._websocket_mark_closes.get(symbol) != expected_open
        }
        requests = [
            (symbol, KlineSeries(PriceType.MARK, 60))
            for symbol in sorted(mark_symbols)
        ]
        requests.extend(
            (symbol, KlineSeries(PriceType.TRADE, 60))
            for symbol in sorted(trade_symbols)
        )
        results = await asyncio.gather(
            *(self.collect_latest_closed_kline(symbol, series) for symbol, series in requests),
            return_exceptions=True,
        )
        trade_count = 0
        mark_count = 0
        for (symbol, series), result in zip(requests, results, strict=True):
            if isinstance(result, BaseException):
                logger.error(
                    "one-minute kline collection failed symbol=%s price_type=%s error=%s",
                    symbol,
                    series.price_type.value,
                    result,
                )
            elif series.price_type is PriceType.TRADE:
                trade_count += result
            else:
                mark_count += result
        cutoff = expected_open - timedelta(minutes=2)
        self._websocket_trade_closes = {
            symbol: open_time
            for symbol, open_time in self._websocket_trade_closes.items()
            if open_time >= cutoff
        }
        self._websocket_mark_closes = {
            symbol: open_time
            for symbol, open_time in self._websocket_mark_closes.items()
            if open_time >= cutoff
        }
        return trade_count, mark_count

    async def _collect_latest_closed_5m(self, symbol: str) -> int:
        return await self.collect_latest_closed_kline(
            symbol, TRADE_5M_SERIES
        )

    async def collect_latest_closed_kline(
        self,
        symbol: str,
        series: KlineSeries,
    ) -> int:
        result = await self._fetch_klines(symbol, series, limit=2)
        collected_at = datetime.now(UTC)
        params: dict[str, str | int] = {
            "symbol": symbol,
            "interval": series.binance_interval,
            "limit": 2,
        }
        await self._publish_raw(
            name=f"kline_{series.price_type.value.lower()}_{series.binance_interval}",
            endpoint=self._kline_endpoint(series.price_type),
            result=result,
            collected_at=collected_at,
            params=params,
            symbol=symbol,
        )
        rows = cast(list[list[object]], result.payload)
        closed_rows = [row for row in rows if _utc_from_ms(row[6]) < collected_at]
        if not closed_rows:
            return 0
        await self._publish_kline_row(
            symbol,
            closed_rows[-1],
            collected_at,
            MarketSource.REST,
            series,
        )
        return 1

    async def collect_5m_range(
        self,
        symbol: str,
        start: datetime,
        end: datetime,
    ) -> int:
        return await self.collect_kline_range(
            symbol,
            start,
            end,
            TRADE_5M_SERIES,
        )

    async def collect_kline_range(
        self,
        symbol: str,
        start: datetime,
        end: datetime,
        series: KlineSeries,
    ) -> int:
        result = await self._fetch_klines(
            symbol,
            series,
            limit=1500,
            start_time_ms=int(start.timestamp() * 1000),
            end_time_ms=int(end.timestamp() * 1000) - 1,
        )
        collected_at = datetime.now(UTC)
        params: dict[str, str | int] = {
            "symbol": symbol,
            "interval": series.binance_interval,
            "limit": 1500,
            "startTime": int(start.timestamp() * 1000),
            "endTime": int(end.timestamp() * 1000) - 1,
        }
        await self._publish_raw(
            name=(
                f"kline_{series.price_type.value.lower()}_"
                f"{series.binance_interval}_backfill"
            ),
            endpoint=self._kline_endpoint(series.price_type),
            result=result,
            collected_at=collected_at,
            params=params,
            symbol=symbol,
        )
        rows = cast(list[list[object]], result.payload)
        closed_rows = [
            row
            for row in rows
            if start <= _utc_from_ms(row[0]) < end and _utc_from_ms(row[6]) < collected_at
        ]
        for row in closed_rows:
            await self._publish_kline_row(
                symbol, row, collected_at, MarketSource.BACKFILL, series
            )
        return len(closed_rows)

    async def _fetch_klines(
        self,
        symbol: str,
        series: KlineSeries,
        *,
        limit: int,
        start_time_ms: int | None = None,
        end_time_ms: int | None = None,
    ) -> BinanceResult:
        if series.price_type is PriceType.TRADE:
            return await self._client.klines(
                symbol,
                series.binance_interval,
                limit,
                start_time_ms,
                end_time_ms,
            )
        if series.price_type is PriceType.MARK:
            return await self._client.mark_price_klines(
                symbol,
                series.binance_interval,
                limit,
                start_time_ms,
                end_time_ms,
            )
        raise ValueError(f"unsupported source kline price type: {series.price_type}")

    @staticmethod
    def _kline_endpoint(price_type: PriceType) -> str:
        if price_type is PriceType.TRADE:
            return "/fapi/v1/klines"
        if price_type is PriceType.MARK:
            return "/fapi/v1/markPriceKlines"
        raise ValueError(f"unsupported source kline price type: {price_type}")

    async def _publish_kline_row(
        self,
        symbol: str,
        row: list[object],
        collected_at: datetime,
        source: MarketSource,
        series: KlineSeries = TRADE_5M_SERIES,
    ) -> None:
        open_time = _utc_from_ms(row[0])
        close_time = open_time + timedelta(seconds=series.interval_seconds)
        is_trade = series.price_type is PriceType.TRADE
        payload = KlinePayload(
            symbol=symbol,
            price_type=series.price_type,
            interval_seconds=series.interval_seconds,
            open_time=open_time,
            close_time=close_time,
            open_price=Decimal(str(row[1])),
            high_price=Decimal(str(row[2])),
            low_price=Decimal(str(row[3])),
            close_price=Decimal(str(row[4])),
            base_volume=Decimal(str(row[5])) if is_trade else None,
            quote_volume=Decimal(str(row[7])) if is_trade else None,
            trade_count=_int(row[8]) if is_trade else None,
            is_closed=True,
            quality_status=QualityStatus.VALID,
        )
        event = self._event(
            event_type="KLINE_CLOSED",
            source=source,
            collected_at=collected_at,
            exchange_event_time=_utc_from_ms(row[6]),
            business_key=(
                symbol,
                series.price_type.value,
                series.interval_seconds,
                open_time.isoformat(),
            ),
            payload=payload,
        )
        await self._publisher.publish(
            ".".join(
                (
                    "market.normalized.kline",
                    series.binance_interval,
                    series.price_type.value.lower(),
                    symbol,
                )
            ),
            event,
        )

    async def publish_websocket_kline(self, message: JsonObject) -> bool:
        """Publish one closed Binance combined-stream kline message."""
        candidate = message.get("data", message)
        if not isinstance(candidate, dict):
            return False
        data = candidate
        event_name = str(data.get("e", ""))
        if event_name not in {"kline", "markPrice_kline"}:
            return False
        kline = _as_object(data.get("k"))
        interval = str(kline.get("i", ""))
        if not bool(kline.get("x")) or interval not in {"1m", "5m"}:
            return False
        price_type = PriceType.MARK if event_name == "markPrice_kline" else PriceType.TRADE
        symbol = str(kline["s"])
        open_time = _utc_from_ms(kline["t"])
        collected_at = datetime.now(UTC)
        raw_result = BinanceResult(payload=message, used_weight_1m=None)
        await self._publish_raw(
            name=f"websocket_kline_{interval}",
            endpoint=str(message.get("stream", "binance-websocket")),
            result=raw_result,
            collected_at=collected_at,
            symbol=symbol,
            source=MarketSource.WEBSOCKET,
        )
        row: list[object] = [
            kline["t"],
            kline["o"],
            kline["h"],
            kline["l"],
            kline["c"],
            kline.get("v", "0"),
            kline["T"],
            kline.get("q", "0"),
            kline.get("n", 0),
        ]
        await self._publish_kline_row(
            symbol,
            row,
            collected_at,
            MarketSource.WEBSOCKET,
            KlineSeries(price_type, 60 if interval == "1m" else 300),
        )
        if price_type is PriceType.TRADE:
            if interval == "1m":
                self._websocket_trade_closes[symbol] = open_time
            else:
                self._websocket_trade_5m_closes[symbol] = open_time
        return True
