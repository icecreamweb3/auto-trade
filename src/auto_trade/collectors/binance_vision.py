from __future__ import annotations

import asyncio
import csv
import hashlib
import io
import re
import zipfile
from collections import OrderedDict
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx

from auto_trade.contracts import PriceType

_SHA256_PATTERN = re.compile(r"\b[0-9a-fA-F]{64}\b")


class BinanceVisionError(RuntimeError):
    """Base error for Binance Vision archive retrieval and validation."""


class BinanceVisionUnavailable(BinanceVisionError):
    """The requested official archive is not available and REST may be used."""


class BinanceVisionIntegrityError(BinanceVisionError):
    """An archive failed its official checksum or structural validation."""


@dataclass(frozen=True, slots=True)
class BinanceVisionKlines:
    rows: tuple[list[object], ...]
    archive_paths: tuple[str, ...]
    sha256: tuple[str, ...]


def _month_start(value: datetime) -> datetime:
    return value.astimezone(UTC).replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def _next_month(value: datetime) -> datetime:
    if value.month == 12:
        return value.replace(year=value.year + 1, month=1)
    return value.replace(month=value.month + 1)


def _timestamp_ms(value: object) -> int:
    timestamp = int(str(value))
    # Binance has begun publishing some archives with microsecond timestamps.
    return timestamp // 1000 if timestamp >= 100_000_000_000_000 else timestamp


class BinanceVisionClient:
    """Checksum-verified reader for Binance USD-M monthly Kline archives."""

    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: float,
        attempts: int,
        cache_entries: int,
        max_archive_bytes: int,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._attempts = attempts
        self._cache_entries = cache_entries
        self._max_archive_bytes = max_archive_bytes
        self._cache: OrderedDict[str, tuple[tuple[list[object], ...], str]] = OrderedDict()
        self._locks: dict[str, asyncio.Lock] = {}
        self._client = httpx.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=httpx.Timeout(timeout_seconds),
            transport=transport,
            headers={"User-Agent": "auto-trade-v2/0.1"},
        )

    async def __aenter__(self) -> BinanceVisionClient:
        return self

    async def __aexit__(self, *_args: object) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        await self._client.aclose()

    @staticmethod
    def archive_path(
        symbol: str,
        interval: str,
        month: datetime,
        price_type: PriceType,
    ) -> str:
        dataset = "klines" if price_type is PriceType.TRADE else "markPriceKlines"
        if price_type not in {PriceType.TRADE, PriceType.MARK}:
            raise ValueError(f"unsupported Binance Vision price type: {price_type}")
        filename = f"{symbol}-{interval}-{month:%Y-%m}.zip"
        return f"/data/futures/um/monthly/{dataset}/{symbol}/{interval}/{filename}"

    async def fetch_klines(
        self,
        *,
        symbol: str,
        interval: str,
        price_type: PriceType,
        start: datetime,
        end: datetime,
    ) -> BinanceVisionKlines:
        if start.tzinfo is None or end.tzinfo is None:
            raise ValueError("archive range timestamps must be timezone-aware")
        start = start.astimezone(UTC)
        end = end.astimezone(UTC)
        if start >= end:
            raise ValueError("archive range start must precede end")

        range_start_ms = int(start.timestamp() * 1000)
        range_end_ms = int(end.timestamp() * 1000)
        month = _month_start(start)
        final_month = _month_start(end)
        if end == final_month:
            final_month = _month_start(end - _ONE_MICROSECOND)

        selected: list[list[object]] = []
        paths: list[str] = []
        checksums: list[str] = []
        while month <= final_month:
            path = self.archive_path(symbol, interval, month, price_type)
            rows, checksum = await self._load_archive(path)
            selected.extend(
                row for row in rows if range_start_ms <= _timestamp_ms(row[0]) < range_end_ms
            )
            paths.append(path)
            checksums.append(checksum)
            month = _next_month(month)
        return BinanceVisionKlines(tuple(selected), tuple(paths), tuple(checksums))

    async def _load_archive(self, path: str) -> tuple[tuple[list[object], ...], str]:
        cached = self._cache.get(path)
        if cached is not None:
            self._cache.move_to_end(path)
            return cached
        lock = self._locks.setdefault(path, asyncio.Lock())
        async with lock:
            cached = self._cache.get(path)
            if cached is not None:
                self._cache.move_to_end(path)
                return cached
            checksum_content = await self._download(f"{path}.CHECKSUM")
            try:
                checksum_text = checksum_content.decode("ascii", errors="strict")
            except UnicodeError as error:
                raise BinanceVisionIntegrityError(
                    f"official checksum is not ASCII for {path}"
                ) from error
            match = _SHA256_PATTERN.search(checksum_text)
            if match is None:
                raise BinanceVisionIntegrityError(f"official checksum is malformed for {path}")
            expected = match.group(0).lower()
            archive = await self._download(path)
            actual = hashlib.sha256(archive).hexdigest()
            if actual != expected:
                raise BinanceVisionIntegrityError(
                    f"SHA-256 mismatch for {path}: expected {expected}, got {actual}"
                )
            rows = self._parse_archive(path, archive)
            value = (rows, actual)
            self._cache[path] = value
            self._cache.move_to_end(path)
            while len(self._cache) > self._cache_entries:
                self._cache.popitem(last=False)
            return value

    async def _download(self, path: str) -> bytes:
        last_error: Exception | None = None
        for attempt in range(1, self._attempts + 1):
            try:
                response = await self._client.get(path)
                if response.status_code == 404:
                    raise BinanceVisionUnavailable(f"archive not found: {path}")
                response.raise_for_status()
                content = response.content
                if len(content) > self._max_archive_bytes:
                    raise BinanceVisionIntegrityError(
                        f"archive exceeds {self._max_archive_bytes} bytes: {path}"
                    )
                return content
            except BinanceVisionUnavailable:
                raise
            except BinanceVisionIntegrityError:
                raise
            except httpx.HTTPError as error:
                last_error = error
                if attempt < self._attempts:
                    await asyncio.sleep(min(0.25 * (2 ** (attempt - 1)), 2.0))
        raise BinanceVisionUnavailable(
            f"archive request failed after {self._attempts} attempts: {path}"
        ) from last_error

    @staticmethod
    def _parse_archive(path: str, content: bytes) -> tuple[list[object], ...]:
        try:
            with zipfile.ZipFile(io.BytesIO(content)) as archive:
                files = [item for item in archive.infolist() if not item.is_dir()]
                if len(files) != 1 or not files[0].filename.lower().endswith(".csv"):
                    raise BinanceVisionIntegrityError(
                        f"archive must contain exactly one CSV file: {path}"
                    )
                if files[0].file_size > 2 * len(content) + 64_000_000:
                    raise BinanceVisionIntegrityError(
                        f"archive has an excessive uncompressed size: {path}"
                    )
                with archive.open(files[0]) as source:
                    text = io.TextIOWrapper(source, encoding="utf-8", newline="")
                    parsed: list[list[object]] = []
                    for index, row in enumerate(csv.reader(text)):
                        if not row:
                            continue
                        if index == 0 and not row[0].isdigit():
                            continue
                        if len(row) < 9:
                            raise BinanceVisionIntegrityError(
                                f"Kline CSV row has fewer than 9 fields: {path}"
                            )
                        normalized: list[object] = list(row)
                        normalized[0] = _timestamp_ms(normalized[0])
                        normalized[6] = _timestamp_ms(normalized[6])
                        parsed.append(normalized)
                    return tuple(parsed)
        except BinanceVisionIntegrityError:
            raise
        except (OSError, UnicodeError, ValueError, zipfile.BadZipFile) as error:
            raise BinanceVisionIntegrityError(f"invalid archive {path}: {error}") from error


_ONE_MICROSECOND = timedelta(microseconds=1)
