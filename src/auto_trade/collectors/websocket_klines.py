from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Iterable, Mapping

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from auto_trade.collectors.service import BinanceCollectionService

logger = logging.getLogger(__name__)


def websocket_proxy(environ: Mapping[str, str] | None = None) -> str | None:
    values = os.environ if environ is None else environ
    for name in (
        "PROXY",
        "ALL_PROXY",
        "BINANCE_PROXY_URL",
        "HTTPS_PROXY",
        "HTTP_PROXY",
    ):
        value = values.get(name)
        if value:
            return value
    return None


def kline_stream_names(symbols: Iterable[str]) -> tuple[str, ...]:
    streams: list[str] = []
    for symbol in sorted(set(symbols)):
        normalized = symbol.lower()
        streams.append(f"{normalized}@kline_1m")
        streams.append(f"{normalized}@kline_5m")
    return tuple(streams)


def market_stream_names(symbols: Iterable[str]) -> tuple[str, ...]:
    return (
        *kline_stream_names(symbols),
        "!ticker@arr",
        "!markPrice@arr@1s",
    )


def chunked(values: tuple[str, ...], size: int) -> tuple[tuple[str, ...], ...]:
    if size < 1:
        raise ValueError("chunk size must be positive")
    return tuple(values[index : index + size] for index in range(0, len(values), size))


class BinanceKlineWebSocketCollector:
    """Collect reusable Futures market data over sharded WebSocket streams."""

    def __init__(
        self,
        service: BinanceCollectionService,
        *,
        base_url: str,
        streams_per_connection: int,
        reconnect_max_seconds: float,
        proxy_url: str | None = None,
    ) -> None:
        self._service = service
        self._base_url = base_url.rstrip("/")
        self._streams_per_connection = streams_per_connection
        self._reconnect_max_seconds = reconnect_max_seconds
        self._proxy_url = websocket_proxy() if proxy_url is None else proxy_url
        self._symbols: frozenset[str] = frozenset()
        self._symbols_changed = asyncio.Event()

    def update_symbols(self, symbols: set[str]) -> None:
        updated = frozenset(symbols)
        if updated != self._symbols:
            self._symbols = updated
            self._symbols_changed.set()

    async def _consume_shard(self, streams: tuple[str, ...]) -> None:
        url = f"{self._base_url}/market/stream?streams={'/'.join(streams)}"
        backoff = 1.0
        while not self._symbols_changed.is_set():
            try:
                async with connect(
                    url,
                    open_timeout=10,
                    close_timeout=10,
                    ping_interval=20,
                    ping_timeout=20,
                    max_queue=2048,
                    proxy=self._proxy_url,
                ) as websocket:
                    logger.info(
                        "Binance kline WebSocket connected streams=%d proxy_enabled=%s",
                        len(streams),
                        self._proxy_url is not None,
                    )
                    while True:
                        try:
                            raw_message = await asyncio.wait_for(
                                websocket.recv(), timeout=15
                            )
                        except TimeoutError:
                            logger.warning(
                                "Binance kline WebSocket idle streams=%d retry_seconds=%.1f",
                                len(streams),
                                backoff,
                            )
                            break
                        backoff = 1.0
                        if self._symbols_changed.is_set():
                            return
                        if not isinstance(raw_message, str):
                            raw_message = raw_message.decode()
                        message = json.loads(raw_message)
                        if not isinstance(message, dict):
                            logger.warning("ignored non-object WebSocket message")
                            continue
                        handled = await self._service.publish_websocket_kline(message)
                        if not handled:
                            await self._service.observe_websocket_market(message)
                try:
                    await asyncio.wait_for(
                        self._symbols_changed.wait(), timeout=backoff
                    )
                except TimeoutError:
                    pass
                backoff = min(backoff * 2, self._reconnect_max_seconds)
            except asyncio.CancelledError:
                raise
            except (ConnectionClosed, OSError, TimeoutError, ValueError, json.JSONDecodeError):
                logger.exception(
                    "Binance kline WebSocket disconnected streams=%d retry_seconds=%.1f",
                    len(streams),
                    backoff,
                )
                try:
                    await asyncio.wait_for(self._symbols_changed.wait(), timeout=backoff)
                except TimeoutError:
                    pass
                backoff = min(backoff * 2, self._reconnect_max_seconds)

    async def run_forever(self) -> None:
        while True:
            if not self._symbols:
                self._symbols_changed.clear()
                await self._symbols_changed.wait()
                continue
            streams = market_stream_names(self._symbols)
            shards = chunked(streams, self._streams_per_connection)
            self._symbols_changed.clear()
            logger.info(
                "starting Binance kline WebSocket shards=%d streams=%d symbols=%d",
                len(shards),
                len(streams),
                len(self._symbols),
            )
            tasks = [asyncio.create_task(self._consume_shard(shard)) for shard in shards]
            change_task = asyncio.create_task(self._symbols_changed.wait())
            try:
                done, _pending = await asyncio.wait(
                    [*tasks, change_task], return_when=asyncio.FIRST_COMPLETED
                )
                for task in done:
                    if task is not change_task:
                        task.result()
            finally:
                for task in [*tasks, change_task]:
                    task.cancel()
                await asyncio.gather(*tasks, change_task, return_exceptions=True)
