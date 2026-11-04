import hashlib
import io
import zipfile
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from auto_trade.collectors.binance_vision import (
    BinanceVisionClient,
    BinanceVisionIntegrityError,
    BinanceVisionUnavailable,
)
from auto_trade.contracts import PriceType


def _zip_csv(rows: list[list[object]]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "BTCUSDT-5m-2020-01.csv",
            "\n".join(",".join(str(value) for value in row) for row in rows),
        )
    return output.getvalue()


def _row(open_time: datetime) -> list[object]:
    opened = int(open_time.timestamp() * 1000)
    return [
        opened,
        "100",
        "102",
        "99",
        "101",
        "10",
        opened + 299_999,
        "1005",
        12,
        "5",
        "500",
        "0",
    ]


def _client(transport: httpx.AsyncBaseTransport) -> BinanceVisionClient:
    return BinanceVisionClient(
        base_url="https://data.binance.vision",
        timeout_seconds=10,
        attempts=1,
        cache_entries=2,
        max_archive_bytes=10_000_000,
        transport=transport,
    )


async def test_fetches_checksum_verified_monthly_rows_and_reuses_cache() -> None:
    month = datetime(2020, 1, 1, tzinfo=UTC)
    rows = [_row(month), _row(month + timedelta(minutes=5))]
    content = _zip_csv(rows)
    checksum = hashlib.sha256(content).hexdigest()
    requested: list[str] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requested.append(request.url.path)
        if request.url.path.endswith(".CHECKSUM"):
            return httpx.Response(200, text=f"{checksum}  BTCUSDT-5m-2020-01.zip")
        return httpx.Response(200, content=content)

    async with _client(httpx.MockTransport(handler)) as client:
        first = await client.fetch_klines(
            symbol="BTCUSDT",
            interval="5m",
            price_type=PriceType.TRADE,
            start=month + timedelta(minutes=5),
            end=month + timedelta(minutes=10),
        )
        second = await client.fetch_klines(
            symbol="BTCUSDT",
            interval="5m",
            price_type=PriceType.TRADE,
            start=month,
            end=month + timedelta(minutes=5),
        )

    expected_path = "/data/futures/um/monthly/klines/BTCUSDT/5m/BTCUSDT-5m-2020-01.zip"
    assert requested == [f"{expected_path}.CHECKSUM", expected_path]
    assert len(first.rows) == 1
    assert first.rows[0][0] == rows[1][0]
    assert len(second.rows) == 1
    assert second.rows[0][0] == rows[0][0]
    assert first.archive_paths == (expected_path,)
    assert first.sha256 == (checksum,)


def test_mark_price_archive_uses_distinct_official_dataset() -> None:
    path = BinanceVisionClient.archive_path(
        "ETHUSDT", "1m", datetime(2021, 2, 1, tzinfo=UTC), PriceType.MARK
    )

    assert path == ("/data/futures/um/monthly/markPriceKlines/ETHUSDT/1m/ETHUSDT-1m-2021-02.zip")


async def test_missing_archive_is_explicitly_available_for_rest_fallback() -> None:
    transport = httpx.MockTransport(lambda _request: httpx.Response(404))
    async with _client(transport) as client:
        with pytest.raises(BinanceVisionUnavailable, match="archive not found"):
            await client.fetch_klines(
                symbol="BTCUSDT",
                interval="5m",
                price_type=PriceType.TRADE,
                start=datetime(2020, 1, 1, tzinfo=UTC),
                end=datetime(2020, 1, 2, tzinfo=UTC),
            )


async def test_checksum_mismatch_is_not_treated_as_rest_fallback() -> None:
    content = _zip_csv([_row(datetime(2020, 1, 1, tzinfo=UTC))])

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith(".CHECKSUM"):
            return httpx.Response(200, text=f"{'0' * 64}  archive.zip")
        return httpx.Response(200, content=content)

    async with _client(httpx.MockTransport(handler)) as client:
        with pytest.raises(BinanceVisionIntegrityError, match="SHA-256 mismatch"):
            await client.fetch_klines(
                symbol="BTCUSDT",
                interval="5m",
                price_type=PriceType.TRADE,
                start=datetime(2020, 1, 1, tzinfo=UTC),
                end=datetime(2020, 1, 2, tzinfo=UTC),
            )
