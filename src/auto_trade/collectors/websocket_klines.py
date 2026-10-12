from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Iterable, Mapping
from time import monotonic
from typing import Any

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from auto_trade.collectors.service import BinanceCollectionService

logger = logging.getLogger(__name__)

MARKET_WIDE_STREAMS = ("!ticker@arr", "!markPrice@arr@1s")


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


def websocket_connect_options(proxy_url: str | None) -> dict[str, Any]:
    """Use Binance server pings without sending client keepalive pings."""
    return {
        "open_timeout": 10,
        "close_timeout": 10,
        "ping_interval": None,
        "max_queue": 2048,
        "proxy": proxy_url,
    }


def kline_stream_names(symbols: Iterable[str]) -> tuple[str, ...]:
    streams: list[str] = []
    for symbol in sorted(set(symbols)):
        normalized = symbol.lower()
        streams.append(f"{normalized}@kline_1m")
        streams.append(f"{normalized}@kline_5m")
    return tuple(streams)


def market_stream_names(symbols: Iterable[str]) -> tuple[str, ...]:
    return (*kline_stream_names(symbols), *MARKET_WIDE_STREAMS)


def chunked(values: tuple[str, ...], size: int) -> tuple[tuple[str, ...], ...]:
    if size < 1:
        raise ValueError("chunk size must be positive")
    return tuple(values[index : index + size] for index in range(0, len(values), size))


def market_stream_shards(
    symbols: Iterable[str], streams_per_connection: int
) -> tuple[tuple[str, ...], ...]:
    """Keep large all-market payloads off the high-rate kline connections."""
    return (
        *chunked(kline_stream_names(symbols), streams_per_connection),
        MARKET_WIDE_STREAMS,
    )


class BinanceKlineWebSocketCollector:
    """Collect reusable Futures market data over sharded WebSocket streams."""

    def __init__(
        self,
        service: BinanceCollectionService,
        *,
        base_url: str,
        streams_per_connection: int,
        reconnect_max_seconds: float,
        receive_timeout_seconds: float,
        message_queue_size: int,
        kline_workers_per_connection: int,
        proxy_url: str | None = None,
    ) -> None:
        self._service = service
        self._base_url = base_url.rstrip("/")
        self._streams_per_connection = streams_per_connection
        self._reconnect_max_seconds = reconnect_max_seconds
        self._receive_timeout_seconds = receive_timeout_seconds
        self._message_queue_size = message_queue_size
        self._kline_workers_per_connection = kline_workers_per_connection
        self._proxy_url = websocket_proxy() if proxy_url is None else proxy_url
        self._symbols: frozenset[str] = frozenset()
        self._symbols_changed = asyncio.Event()

    def update_symbols(self, symbols: set[str]) -> None:
        updated = frozenset(symbols)
        if updated != self._symbols:
            self._symbols = updated
            self._symbols_changed.set()

    async def _process_messages(
        self,
        messages: asyncio.Queue[dict[str, Any]],
        *,
        streams_count: int,
        worker_id: int,
    ) -> None:
        while True:
            message = await messages.get()
            started_at = monotonic()
            try:
                handled = await self._service.publish_websocket_kline(message)
                if not handled:
                    await self._service.observe_websocket_market(message)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception(
                    "Binance WebSocket message processing failed "
                    "streams=%d worker=%d queue_depth=%d",
                    streams_count,
                    worker_id,
                    messages.qsize(),
                )
            finally:
                messages.task_done()
            elapsed = monotonic() - started_at
            if elapsed >= 2:
                logger.warning(
                    "Binance WebSocket slow message handler "
                    "streams=%d worker=%d elapsed_seconds=%.3f queue_depth=%d",
                    streams_count,
                    worker_id,
                    elapsed,
                    messages.qsize(),
                )

    async def _consume_shard(self, streams: tuple[str, ...]) -> None:
        url = f"{self._base_url}/market/stream?streams={'/'.join(streams)}"
        backoff = 1.0
        messages: asyncio.Queue[dict[str, Any]] = asyncio.Queue(
            maxsize=self._message_queue_size
        )
        worker_count = (
            1 if streams == MARKET_WIDE_STREAMS else self._kline_workers_per_connection
        )
        workers = [
            asyncio.create_task(
                self._process_messages(
                    messages, streams_count=len(streams), worker_id=index + 1
                )
            )
            for index in range(worker_count)
        ]
        queue_saturated = False
        try:
            while not self._symbols_changed.is_set():
                connected_at: float | None = None
                try:
                    async with connect(
                        url,
                        **websocket_connect_options(self._proxy_url),
                    ) as websocket:
                        connected_at = monotonic()
                        logger.info(
                            "Binance WebSocket connected streams=%d workers=%d "
                            "proxy_enabled=%s",
                            len(streams),
                            worker_count,
                            self._proxy_url is not None,
                        )
                        while True:
                            try:
                                raw_message = await asyncio.wait_for(
                                    websocket.recv(),
                                    timeout=self._receive_timeout_seconds,
                                )
                            except TimeoutError:
                                logger.warning(
                                    "Binance WebSocket idle streams=%d "
                                    "timeout_seconds=%.1f queue_depth=%d",
                                    len(streams),
                                    self._receive_timeout_seconds,
                                    messages.qsize(),
                                )
                                break
                            if self._symbols_changed.is_set():
                                return
                            if not isinstance(raw_message, str):
                                raw_message = raw_message.decode()
                            try:
                                message = json.loads(raw_message)
                            except json.JSONDecodeError:
                                logger.warning(
                                    "ignored invalid Binance WebSocket JSON streams=%d",
                                    len(streams),
                                )
                                continue
                            if not isinstance(message, dict):
                                logger.warning("ignored non-object WebSocket message")
                                continue
                            if messages.full() and not queue_saturated:
                                queue_saturated = True
                                logger.error(
                                    "Binance WebSocket processing queue saturated "
                                    "streams=%d queue_depth=%d",
                                    len(streams),
                                    messages.qsize(),
                                )
                            await messages.put(message)
                            if (
                                queue_saturated
                                and messages.qsize() < self._message_queue_size // 2
                            ):
                                queue_saturated = False
                                logger.info(
                                    "Binance WebSocket processing queue recovered "
                                    "streams=%d queue_depth=%d",
                                    len(streams),
                                    messages.qsize(),
                                )
                except asyncio.CancelledError:
                    raise
                except (ConnectionClosed, OSError, TimeoutError, ValueError) as error:
                    logger.warning(
                        "Binance WebSocket disconnected streams=%d "
                        "error_type=%s error=%s queue_depth=%d",
                        len(streams),
                        type(error).__name__,
                        error,
                        messages.qsize(),
                    )
                if connected_at is not None and monotonic() - connected_at >= 60:
                    backoff = 1.0
                logger.info(
                    "Binance WebSocket reconnect scheduled streams=%d "
                    "retry_seconds=%.1f queue_depth=%d",
                    len(streams),
                    backoff,
                    messages.qsize(),
                )
                try:
                    await asyncio.wait_for(self._symbols_changed.wait(), timeout=backoff)
                except TimeoutError:
                    pass
                backoff = min(backoff * 2, self._reconnect_max_seconds)
        finally:
            for worker in workers:
                worker.cancel()
            await asyncio.gather(*workers, return_exceptions=True)

    async def run_forever(self) -> None:
        while True:
            if not self._symbols:
                self._symbols_changed.clear()
                await self._symbols_changed.wait()
                continue
            streams = market_stream_names(self._symbols)
            shards = market_stream_shards(
                self._symbols, self._streams_per_connection
            )
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
