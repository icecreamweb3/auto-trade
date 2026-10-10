from __future__ import annotations

import asyncio
import logging
from collections import deque
from collections.abc import Mapping
from dataclasses import dataclass
from typing import cast

import httpx

JsonObject = dict[str, object]
logger = logging.getLogger(__name__)

BINANCE_WEIGHT_LIMIT_1M = 2400
BINANCE_WEIGHT_SAFETY_RATIO = 0.8


class BinanceRateLimitError(RuntimeError):
    def __init__(self, status_code: int, retry_after_seconds: float) -> None:
        self.status_code = status_code
        self.retry_after_seconds = retry_after_seconds
        super().__init__(
            f"Binance rate limited the client with HTTP {status_code}; "
            f"retry after {retry_after_seconds:.0f}s"
        )


@dataclass(frozen=True, slots=True)
class BinanceResult:
    payload: object
    used_weight_1m: int | None
    request_rate_1m: int | None = None


class BinanceUsdMClient:
    """Single public REST gateway for Binance USD-M market data."""

    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: float,
        max_concurrency: int,
        attempts: int,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._attempts = attempts
        self._semaphore = asyncio.Semaphore(max_concurrency)
        self._cooldown_until = 0.0
        self._request_times: deque[float] = deque()
        self._client = httpx.AsyncClient(
            base_url=base_url,
            timeout=httpx.Timeout(timeout_seconds),
            transport=transport,
            headers={"User-Agent": "auto-trade-v2/0.1"},
        )

    async def __aenter__(self) -> BinanceUsdMClient:
        return self

    async def __aexit__(self, *_args: object) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _get(
        self,
        path: str,
        params: Mapping[str, str | int] | None = None,
    ) -> BinanceResult:
        last_error: Exception | None = None
        for attempt in range(1, self._attempts + 1):
            try:
                async with self._semaphore:
                    cooldown = self._cooldown_until - asyncio.get_running_loop().time()
                    if cooldown > 0:
                        await asyncio.sleep(cooldown)
                    response = await self._client.get(path, params=params)
                    now = asyncio.get_running_loop().time()
                    self._request_times.append(now)
                    while self._request_times and self._request_times[0] <= now - 60:
                        self._request_times.popleft()
                    request_rate_1m = len(self._request_times)
                    if response.status_code in {418, 429}:
                        default_delay = 300.0 if response.status_code == 418 else 60.0
                        try:
                            retry_after = float(
                                response.headers.get("retry-after", default_delay)
                            )
                        except ValueError:
                            retry_after = default_delay
                        retry_after = max(1.0, retry_after)
                        self._cooldown_until = max(
                            self._cooldown_until,
                            asyncio.get_running_loop().time() + retry_after,
                        )
                        raise BinanceRateLimitError(response.status_code, retry_after)
                if response.status_code >= 500:
                    response.raise_for_status()
                response.raise_for_status()
                weight_header = response.headers.get("x-mbx-used-weight-1m")
                used_weight_1m = int(weight_header) if weight_header else None
                if (
                    used_weight_1m is not None
                    and used_weight_1m
                    >= BINANCE_WEIGHT_LIMIT_1M * BINANCE_WEIGHT_SAFETY_RATIO
                ):
                    self._cooldown_until = max(
                        self._cooldown_until,
                        asyncio.get_running_loop().time() + 60,
                    )
                    logger.warning(
                        "Binance REST weight protection path=%s "
                        "request_rate_1m=%d used_weight_1m=%d limit_1m=%d",
                        path,
                        request_rate_1m,
                        used_weight_1m,
                        BINANCE_WEIGHT_LIMIT_1M,
                    )
                elif request_rate_1m == 1 or request_rate_1m % 100 == 0:
                    logger.info(
                        "Binance REST usage path=%s request_rate_1m=%d "
                        "used_weight_1m=%s limit_1m=%d",
                        path,
                        request_rate_1m,
                        used_weight_1m,
                        BINANCE_WEIGHT_LIMIT_1M,
                    )
                return BinanceResult(
                    payload=response.json(),
                    used_weight_1m=used_weight_1m,
                    request_rate_1m=request_rate_1m,
                )
            except BinanceRateLimitError:
                raise
            except (httpx.HTTPError, ValueError) as exc:
                last_error = exc
                if attempt == self._attempts:
                    break
                await asyncio.sleep(min(0.25 * (2 ** (attempt - 1)), 2.0))
        raise RuntimeError(
            f"Binance request failed after {self._attempts} attempts: {path}"
        ) from last_error

    async def exchange_info(self) -> BinanceResult:
        result = await self._get("/fapi/v1/exchangeInfo")
        if not isinstance(result.payload, dict):
            raise TypeError("exchangeInfo response must be an object")
        return BinanceResult(
            cast(JsonObject, result.payload),
            result.used_weight_1m,
            result.request_rate_1m,
        )

    async def ticker_24h(self) -> BinanceResult:
        result = await self._get("/fapi/v1/ticker/24hr")
        if not isinstance(result.payload, list):
            raise TypeError("ticker/24hr response must be an array")
        return result

    async def premium_index(self) -> BinanceResult:
        result = await self._get("/fapi/v1/premiumIndex")
        if not isinstance(result.payload, list):
            raise TypeError("premiumIndex response must be an array")
        return result

    async def open_interest(self, symbol: str) -> BinanceResult:
        result = await self._get("/fapi/v1/openInterest", {"symbol": symbol})
        if not isinstance(result.payload, dict):
            raise TypeError("openInterest response must be an object")
        return BinanceResult(
            cast(JsonObject, result.payload),
            result.used_weight_1m,
            result.request_rate_1m,
        )

    async def klines(
        self,
        symbol: str,
        interval: str,
        limit: int = 2,
        start_time_ms: int | None = None,
        end_time_ms: int | None = None,
    ) -> BinanceResult:
        params: dict[str, str | int] = {
            "symbol": symbol,
            "interval": interval,
            "limit": limit,
        }
        if start_time_ms is not None:
            params["startTime"] = start_time_ms
        if end_time_ms is not None:
            params["endTime"] = end_time_ms
        result = await self._get(
            "/fapi/v1/klines",
            params,
        )
        if not isinstance(result.payload, list):
            raise TypeError("klines response must be an array")
        return result

    async def mark_price_klines(
        self,
        symbol: str,
        interval: str,
        limit: int = 2,
        start_time_ms: int | None = None,
        end_time_ms: int | None = None,
    ) -> BinanceResult:
        params: dict[str, str | int] = {
            "symbol": symbol,
            "interval": interval,
            "limit": limit,
        }
        if start_time_ms is not None:
            params["startTime"] = start_time_ms
        if end_time_ms is not None:
            params["endTime"] = end_time_ms
        result = await self._get("/fapi/v1/markPriceKlines", params)
        if not isinstance(result.payload, list):
            raise TypeError("markPriceKlines response must be an array")
        return result
