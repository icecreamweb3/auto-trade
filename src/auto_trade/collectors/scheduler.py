from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta

from auto_trade.collectors.binance_usdm import (
    BinanceRateLimitError,
    BinanceUsdMClient,
)
from auto_trade.collectors.publisher import JetStreamEventPublisher
from auto_trade.collectors.service import BinanceCollectionService
from auto_trade.collectors.websocket_klines import BinanceKlineWebSocketCollector
from auto_trade.config import Settings, get_settings
from auto_trade.infrastructure.nats_streams import connect, ensure_streams
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)


def seconds_until_interval(
    now: datetime,
    interval_seconds: int,
    boundary_delay_seconds: float,
) -> float:
    timestamp = now.astimezone(UTC).timestamp()
    next_boundary = (int(timestamp) // interval_seconds + 1) * interval_seconds
    return max(0.0, next_boundary + boundary_delay_seconds - timestamp)


def seconds_until_daily(now: datetime, utc_hour: int) -> float:
    now_utc = now.astimezone(UTC)
    target = now_utc.replace(hour=utc_hour, minute=0, second=0, microsecond=0)
    if target <= now_utc:
        target += timedelta(days=1)
    return (target - now_utc).total_seconds()


class CollectorScheduler:
    def __init__(self, service: BinanceCollectionService, settings: Settings) -> None:
        self._service = service
        self._settings = settings
        self._symbols: set[str] = set()
        self._websocket = BinanceKlineWebSocketCollector(
            service,
            base_url=settings.binance_usdm_websocket_url,
            streams_per_connection=settings.websocket_streams_per_connection,
            reconnect_max_seconds=settings.websocket_reconnect_max_seconds,
            receive_timeout_seconds=settings.websocket_receive_timeout_seconds,
            message_queue_size=settings.websocket_message_queue_size,
            kline_workers_per_connection=(
                settings.websocket_kline_workers_per_connection
            ),
        )

    async def _sync_instruments(self) -> None:
        instruments = await self._service.sync_instruments()
        self._symbols = {
            instrument.symbol
            for instrument in instruments
            if instrument.trading_status == "TRADING"
        }
        self._websocket.update_symbols(self._symbols)
        logger.info("instrument catalog synchronized trading_symbols=%d", len(self._symbols))

    async def _sync_instruments_until_ready(self) -> None:
        while not self._symbols:
            try:
                await self._sync_instruments()
            except BinanceRateLimitError as error:
                logger.warning(
                    "instrument synchronization rate limited status=%d "
                    "retry_after=%.0fs",
                    error.status_code,
                    error.retry_after_seconds,
                )
                await asyncio.sleep(error.retry_after_seconds)
            except Exception:
                logger.exception("initial instrument synchronization failed")
                await asyncio.sleep(60)

    async def _ticker_loop(self) -> None:
        while True:
            await asyncio.sleep(
                seconds_until_interval(
                    datetime.now(UTC),
                    60,
                    self._settings.collector_boundary_delay_seconds,
                )
            )
            try:
                count = await self._service.publish_websocket_ticker_minutes(
                    self._symbols
                )
                logger.info("WebSocket ticker minute cycle published=%d", count)
            except Exception:
                logger.exception("ticker minute cycle failed")

    async def _open_interest_loop(self) -> None:
        while True:
            await asyncio.sleep(
                seconds_until_interval(
                    datetime.now(UTC),
                    300,
                    self._settings.collector_boundary_delay_seconds,
                )
            )
            try:
                count = await self._service.collect_open_interest(self._symbols)
                logger.info(
                    "REST open interest cycle published=%d symbols=%d",
                    count,
                    len(self._symbols),
                )
            except Exception:
                logger.exception("open interest cycle failed")

    async def _kline_loop(self) -> None:
        while True:
            await asyncio.sleep(
                seconds_until_interval(
                    datetime.now(UTC),
                    300,
                    self._settings.collector_boundary_delay_seconds,
                )
            )
            try:
                count = await self._service.collect_5m_klines(self._symbols)
                logger.info("five-minute kline cycle published=%d", count)
            except Exception:
                logger.exception("five-minute kline cycle failed")

    async def _one_minute_kline_loop(self) -> None:
        while True:
            await asyncio.sleep(
                seconds_until_interval(
                    datetime.now(UTC),
                    60,
                    self._settings.collector_boundary_delay_seconds,
                )
            )
            try:
                trade_count, mark_count = await self._service.collect_1m_klines(
                    self._symbols
                )
                logger.info(
                    "one-minute kline cycle published_trade=%d published_mark=%d",
                    trade_count,
                    mark_count,
                )
            except Exception:
                logger.exception("one-minute kline cycle failed")

    async def _instrument_loop(self) -> None:
        while True:
            await asyncio.sleep(
                seconds_until_daily(
                    datetime.now(UTC),
                    self._settings.instrument_sync_utc_hour,
                )
            )
            try:
                await self._sync_instruments()
            except Exception:
                logger.exception("instrument catalog synchronization failed")
                await asyncio.sleep(60)

    async def run_forever(self) -> None:
        await self._sync_instruments_until_ready()
        await asyncio.sleep(self._settings.collector_startup_delay_seconds)
        await asyncio.gather(
            self._ticker_loop(),
            self._open_interest_loop(),
            self._one_minute_kline_loop(),
            self._kline_loop(),
            self._instrument_loop(),
            self._websocket.run_forever(),
        )


async def run(settings: Settings) -> None:
    connection = await connect(settings)
    try:
        jetstream = connection.jetstream()
        await ensure_streams(jetstream)
        async with BinanceUsdMClient(
            base_url=settings.binance_usdm_base_url,
            timeout_seconds=settings.binance_request_timeout_seconds,
            max_concurrency=settings.binance_max_concurrency,
            attempts=settings.binance_request_attempts,
        ) as client:
            service = BinanceCollectionService(
                client=client,
                publisher=JetStreamEventPublisher(jetstream),
                node_id=settings.node_id,
                shard_id=settings.shard_id,
                websocket_mark_publish_concurrency=(
                    settings.websocket_mark_publish_concurrency
                ),
            )
            await CollectorScheduler(service, settings).run_forever()
    finally:
        await connection.drain()


def main() -> None:
    settings = get_settings()
    configure_logging(settings, "collector")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    asyncio.run(run(settings))


if __name__ == "__main__":
    main()
