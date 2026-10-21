from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.collectors.binance_usdm import BinanceUsdMClient
from auto_trade.config import Settings, get_settings
from auto_trade.contracts import KlinePayload, PriceType, QualityStatus
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)

SYMBOLS = ("BTCUSDT", "ETHUSDT")
START_AT = datetime.combine(date(2020, 4, 1), time.min, tzinfo=UTC)
INTERVAL_SECONDS = 300
INTERVAL = timedelta(seconds=INTERVAL_SECONDS)
PAGE_LIMIT = 1000
CHECKPOINT_PREFIX = "PAPER_HISTORY"
CONFIG_SIGNATURE = "v1:BTCUSDT,ETHUSDT:TRADE:300:2020-04-01"


@dataclass(frozen=True, slots=True)
class HistoricalKline:
    open_time: datetime
    close_time: datetime
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal
    base_volume: Decimal
    quote_volume: Decimal
    trade_count: int
    payload_hash: str
    collected_at: datetime


@dataclass(frozen=True, slots=True)
class HistoryCheckpoint:
    cursor_at: datetime
    scan_stop_at: datetime
    completed: bool


@dataclass(frozen=True, slots=True)
class HistoryStatus:
    symbol: str
    range_start: datetime
    range_end: datetime
    expected_count: int
    valid_count: int
    first_open_time: datetime | None
    last_open_time: datetime | None
    first_missing_at: datetime | None


def latest_closed_boundary(
    now: datetime, *, safety_delay_seconds: int = 60
) -> datetime:
    safe_now = now.astimezone(UTC) - timedelta(seconds=safety_delay_seconds)
    safe_timestamp = int(safe_now.timestamp())
    aligned = safe_timestamp // INTERVAL_SECONDS * INTERVAL_SECONDS
    return datetime.fromtimestamp(aligned, tz=UTC)


def checkpoint_key(symbol: str) -> str:
    return f"{CHECKPOINT_PREFIX}_{symbol}_{INTERVAL_SECONDS}"


def parse_binance_klines(
    symbol: str,
    payload: object,
    *,
    range_start: datetime,
    range_end: datetime,
    collected_at: datetime,
) -> tuple[HistoricalKline, ...]:
    if not isinstance(payload, list):
        raise TypeError("Binance kline response must be an array")
    rows: list[HistoricalKline] = []
    previous_open: datetime | None = None
    for raw in payload:
        if not isinstance(raw, list) or len(raw) < 9:
            raise TypeError(f"invalid Binance kline row for {symbol}")
        open_time = datetime.fromtimestamp(int(str(raw[0])) / 1000, tz=UTC)
        if open_time < range_start or open_time >= range_end:
            continue
        if int(open_time.timestamp()) % INTERVAL_SECONDS:
            raise ValueError(f"unaligned Binance kline for {symbol}: {open_time.isoformat()}")
        if previous_open is not None and open_time <= previous_open:
            raise ValueError(f"non-increasing Binance kline page for {symbol}")
        close_time = open_time + INTERVAL
        if close_time > collected_at:
            continue
        kline = KlinePayload(
            symbol=symbol,
            price_type=PriceType.TRADE,
            interval_seconds=INTERVAL_SECONDS,
            open_time=open_time,
            close_time=close_time,
            open_price=Decimal(str(raw[1])),
            high_price=Decimal(str(raw[2])),
            low_price=Decimal(str(raw[3])),
            close_price=Decimal(str(raw[4])),
            base_volume=Decimal(str(raw[5])),
            quote_volume=Decimal(str(raw[7])),
            trade_count=int(str(raw[8])),
            is_closed=True,
            quality_status=QualityStatus.VALID,
        )
        canonical = json.dumps(
            kline.model_dump(mode="json"),
            sort_keys=True,
            separators=(",", ":"),
            default=str,
        )
        rows.append(
            HistoricalKline(
                open_time=open_time,
                close_time=close_time,
                open_price=kline.open_price,
                high_price=kline.high_price,
                low_price=kline.low_price,
                close_price=kline.close_price,
                base_volume=cast(Decimal, kline.base_volume),
                quote_volume=cast(Decimal, kline.quote_volume),
                trade_count=cast(int, kline.trade_count),
                payload_hash=hashlib.sha256(canonical.encode()).hexdigest(),
                collected_at=collected_at,
            )
        )
        previous_open = open_time
    return tuple(rows)


class PaperHistoryRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def instrument_id(self, symbol: str) -> int:
        async with self._engine.connect() as connection:
            value: object = (
                await connection.execute(
                    text(
                        """
                        SELECT instrument_id
                        FROM core.instruments
                        WHERE exchange = 'BINANCE'
                          AND market = 'USD_M_FUTURES'
                          AND contract_type = 'PERPETUAL'
                          AND upper(symbol) = :symbol
                        """
                    ),
                    {"symbol": symbol},
                )
            ).scalar_one_or_none()
        if value is None:
            raise RuntimeError(f"instrument is not registered: {symbol}")
        return cast(int, value)

    async def load_checkpoint(
        self, symbol: str, range_end: datetime
    ) -> HistoryCheckpoint:
        async with self._engine.begin() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        INSERT INTO market.backfill_scan_checkpoints AS checkpoint (
                            scan_key, cursor_at, scan_stop_at, config_signature
                        ) VALUES (
                            :scan_key, :range_start, :range_end, :config_signature
                        )
                        ON CONFLICT (scan_key) DO UPDATE SET
                            cursor_at = CASE
                                WHEN checkpoint.config_signature = EXCLUDED.config_signature
                                THEN checkpoint.cursor_at
                                ELSE EXCLUDED.cursor_at
                            END,
                            scan_stop_at = CASE
                                WHEN checkpoint.config_signature = EXCLUDED.config_signature
                                THEN GREATEST(checkpoint.scan_stop_at, EXCLUDED.scan_stop_at)
                                ELSE EXCLUDED.scan_stop_at
                            END,
                            completed_at = CASE
                                WHEN checkpoint.config_signature <> EXCLUDED.config_signature
                                  OR checkpoint.scan_stop_at < EXCLUDED.scan_stop_at
                                THEN NULL
                                ELSE checkpoint.completed_at
                            END,
                            config_signature = EXCLUDED.config_signature,
                            updated_at = clock_timestamp()
                        RETURNING cursor_at, scan_stop_at, completed_at
                        """
                    ),
                    {
                        "scan_key": checkpoint_key(symbol),
                        "range_start": START_AT,
                        "range_end": range_end,
                        "config_signature": CONFIG_SIGNATURE,
                    },
                )
            ).one()
        return HistoryCheckpoint(
            cursor_at=cast(datetime, row[0]),
            scan_stop_at=cast(datetime, row[1]),
            completed=row[2] is not None,
        )

    async def save_cursor(
        self, symbol: str, cursor_at: datetime, scan_stop_at: datetime
    ) -> None:
        async with self._engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.backfill_scan_checkpoints
                    SET cursor_at = :cursor_at,
                        scan_stop_at = :scan_stop_at,
                        completed_at = NULL,
                        updated_at = clock_timestamp()
                    WHERE scan_key = :scan_key
                    """
                ),
                {
                    "scan_key": checkpoint_key(symbol),
                    "cursor_at": cursor_at,
                    "scan_stop_at": scan_stop_at,
                },
            )

    async def mark_complete(self, symbol: str, scan_stop_at: datetime) -> None:
        async with self._engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.backfill_scan_checkpoints
                    SET cursor_at = :scan_stop_at,
                        scan_stop_at = :scan_stop_at,
                        completed_at = clock_timestamp(),
                        updated_at = clock_timestamp()
                    WHERE scan_key = :scan_key
                    """
                ),
                {
                    "scan_key": checkpoint_key(symbol),
                    "scan_stop_at": scan_stop_at,
                },
            )

    async def write_klines(
        self, instrument_id: int, rows: tuple[HistoricalKline, ...]
    ) -> int:
        if not rows:
            return 0
        serialized = json.dumps(
            [
                {
                    "open_time": row.open_time.isoformat(),
                    "close_time": row.close_time.isoformat(),
                    "open_price": str(row.open_price),
                    "high_price": str(row.high_price),
                    "low_price": str(row.low_price),
                    "close_price": str(row.close_price),
                    "base_volume": str(row.base_volume),
                    "quote_volume": str(row.quote_volume),
                    "trade_count": row.trade_count,
                    "payload_hash": row.payload_hash,
                    "collected_at": row.collected_at.isoformat(),
                }
                for row in rows
            ]
        )
        async with self._engine.begin() as connection:
            result = await connection.execute(
                text(
                    """
                    WITH incoming AS (
                        SELECT *
                        FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS item (
                            open_time timestamptz,
                            close_time timestamptz,
                            open_price numeric,
                            high_price numeric,
                            low_price numeric,
                            close_price numeric,
                            base_volume numeric,
                            quote_volume numeric,
                            trade_count bigint,
                            payload_hash text,
                            collected_at timestamptz
                        )
                    )
                    INSERT INTO market.klines (
                        instrument_id, price_type, interval_seconds, open_time,
                        revision_no, is_current, supersedes_revision, close_time,
                        open_price, high_price, low_price, close_price,
                        base_volume, quote_volume, trade_count, is_closed,
                        source, data_rule_version, source_event_ids, payload_hash,
                        quality_status, collected_at, effective_at
                    )
                    SELECT :instrument_id, 'TRADE', 300, item.open_time,
                           COALESCE(revision.latest_revision, 0) + 1, true,
                           revision.latest_revision, item.close_time,
                           item.open_price, item.high_price, item.low_price,
                           item.close_price, item.base_volume, item.quote_volume,
                           item.trade_count, true, 'BACKFILL',
                           'paper-history-v1', '{}'::uuid[], item.payload_hash,
                           'VALID', item.collected_at, item.collected_at
                    FROM incoming item
                    LEFT JOIN LATERAL (
                        SELECT max(k.revision_no) AS latest_revision
                        FROM market.klines k
                        WHERE k.instrument_id = :instrument_id
                          AND k.price_type = 'TRADE'
                          AND k.interval_seconds = 300
                          AND k.open_time = item.open_time
                    ) revision ON true
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM market.klines current
                        WHERE current.instrument_id = :instrument_id
                          AND current.price_type = 'TRADE'
                          AND current.interval_seconds = 300
                          AND current.open_time = item.open_time
                          AND current.is_current
                          AND current.is_closed
                          AND current.quality_status = 'VALID'
                    )
                    ON CONFLICT (
                        instrument_id, price_type, interval_seconds, open_time
                    ) WHERE is_current DO NOTHING
                    """
                ),
                {"instrument_id": instrument_id, "rows": serialized},
            )
        return result.rowcount

    async def first_missing(
        self, instrument_id: int, range_start: datetime, range_end: datetime
    ) -> datetime | None:
        async with self._engine.begin() as connection:
            await connection.execute(
                text("SELECT set_config('statement_timeout', '300s', true)")
            )
            value: object = (
                await connection.execute(
                    text(
                        """
                        SELECT min(point)
                        FROM generate_series(
                            CAST(:range_start AS timestamptz),
                            CAST(:range_end AS timestamptz) - interval '5 minutes',
                            interval '5 minutes'
                        ) point
                        WHERE NOT EXISTS (
                            SELECT 1
                            FROM market.klines k
                            WHERE k.instrument_id = :instrument_id
                              AND k.price_type = 'TRADE'
                              AND k.interval_seconds = 300
                              AND k.open_time = point
                              AND k.is_current
                              AND k.is_closed
                              AND k.quality_status = 'VALID'
                        )
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "range_start": range_start,
                        "range_end": range_end,
                    },
                )
            ).scalar_one()
        return cast(datetime | None, value)

    async def status(
        self, symbol: str, range_start: datetime, range_end: datetime
    ) -> HistoryStatus:
        instrument_id = await self.instrument_id(symbol)
        async with self._engine.connect() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        SELECT count(DISTINCT open_time) AS valid_count,
                               min(open_time) AS first_open_time,
                               max(open_time) AS last_open_time
                        FROM market.klines
                        WHERE instrument_id = :instrument_id
                          AND price_type = 'TRADE'
                          AND interval_seconds = 300
                          AND open_time >= :range_start
                          AND open_time < :range_end
                          AND is_current
                          AND is_closed
                          AND quality_status = 'VALID'
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "range_start": range_start,
                        "range_end": range_end,
                    },
                )
            ).mappings().one()
        expected_count = int((range_end - range_start) / INTERVAL)
        valid_count = cast(int, row["valid_count"])
        first_missing_at = (
            None
            if valid_count == expected_count
            else await self.first_missing(instrument_id, range_start, range_end)
        )
        return HistoryStatus(
            symbol=symbol,
            range_start=range_start,
            range_end=range_end,
            expected_count=expected_count,
            valid_count=valid_count,
            first_open_time=cast(datetime | None, row["first_open_time"]),
            last_open_time=cast(datetime | None, row["last_open_time"]),
            first_missing_at=first_missing_at,
        )


class PaperHistoryService:
    def __init__(
        self,
        repository: PaperHistoryRepository,
        client: BinanceUsdMClient,
        *,
        request_interval_seconds: float,
    ) -> None:
        self._repository = repository
        self._client = client
        self._request_interval_seconds = request_interval_seconds

    async def backfill_symbol(self, symbol: str, range_end: datetime) -> HistoryStatus:
        instrument_id = await self._repository.instrument_id(symbol)
        checkpoint = await self._repository.load_checkpoint(symbol, range_end)
        cursor = checkpoint.cursor_at
        stop_at = checkpoint.scan_stop_at
        pages = 0
        fetched = 0
        inserted = 0
        logger.info(
            "paper history starting symbol=%s cursor=%s stop=%s resumed=%s",
            symbol,
            cursor.isoformat(),
            stop_at.isoformat(),
            cursor > START_AT,
        )

        while cursor < stop_at:
            next_cursor, page_fetched, page_inserted = await self._fetch_page(
                symbol, instrument_id, cursor, stop_at
            )
            if next_cursor <= cursor:
                raise RuntimeError(f"Binance history cursor did not advance for {symbol}")
            cursor = next_cursor
            pages += 1
            fetched += page_fetched
            inserted += page_inserted
            await self._repository.save_cursor(symbol, cursor, stop_at)
            if pages == 1 or pages % 25 == 0 or cursor >= stop_at:
                logger.info(
                    "paper history progress symbol=%s cursor=%s pages=%d "
                    "fetched=%d inserted=%d",
                    symbol,
                    cursor.isoformat(),
                    pages,
                    fetched,
                    inserted,
                )
            if cursor < stop_at and self._request_interval_seconds > 0:
                await asyncio.sleep(self._request_interval_seconds)

        missing = await self._repository.first_missing(
            instrument_id, START_AT, stop_at
        )
        repaired = 0
        while missing is not None:
            next_cursor, _page_fetched, page_inserted = await self._fetch_page(
                symbol, instrument_id, missing, stop_at
            )
            if next_cursor <= missing or page_inserted == 0:
                raise RuntimeError(
                    f"Binance returned no repairable 5m candle for {symbol} "
                    f"at {missing.isoformat()}"
                )
            repaired += page_inserted
            if self._request_interval_seconds > 0:
                await asyncio.sleep(self._request_interval_seconds)
            missing = await self._repository.first_missing(
                instrument_id, START_AT, stop_at
            )

        await self._repository.mark_complete(symbol, stop_at)
        status = await self._repository.status(symbol, START_AT, stop_at)
        logger.info(
            "paper history complete symbol=%s expected=%d valid=%d "
            "inserted=%d repaired=%d",
            symbol,
            status.expected_count,
            status.valid_count,
            inserted,
            repaired,
        )
        return status

    async def _fetch_page(
        self,
        symbol: str,
        instrument_id: int,
        cursor: datetime,
        stop_at: datetime,
    ) -> tuple[datetime, int, int]:
        result = await self._client.klines(
            symbol,
            "5m",
            limit=PAGE_LIMIT,
            start_time_ms=int(cursor.timestamp() * 1000),
            end_time_ms=int(stop_at.timestamp() * 1000) - 1,
        )
        collected_at = datetime.now(UTC)
        rows = parse_binance_klines(
            symbol,
            result.payload,
            range_start=cursor,
            range_end=stop_at,
            collected_at=collected_at,
        )
        if not rows:
            raise RuntimeError(
                f"Binance returned an empty history page for {symbol} "
                f"at {cursor.isoformat()}"
            )
        inserted = await self._repository.write_klines(instrument_id, rows)
        return rows[-1].open_time + INTERVAL, len(rows), inserted


async def run(settings: Settings, request_interval_seconds: float) -> None:
    engine = create_database_engine(settings)
    range_end = latest_closed_boundary(datetime.now(UTC))
    if range_end <= START_AT:
        raise RuntimeError("historical range is empty")
    try:
        repository = PaperHistoryRepository(engine)
        async with BinanceUsdMClient(
            base_url=settings.binance_usdm_base_url,
            timeout_seconds=settings.binance_request_timeout_seconds,
            max_concurrency=min(2, settings.binance_max_concurrency),
            attempts=settings.binance_request_attempts,
        ) as client:
            service = PaperHistoryService(
                repository,
                client,
                request_interval_seconds=request_interval_seconds,
            )
            results = await asyncio.gather(
                *(service.backfill_symbol(symbol, range_end) for symbol in SYMBOLS)
            )
        if any(item.valid_count != item.expected_count for item in results):
            raise RuntimeError("paper history verification failed")
    finally:
        await engine.dispose()


async def show_status(settings: Settings) -> None:
    engine = create_database_engine(settings)
    range_end = latest_closed_boundary(datetime.now(UTC))
    try:
        repository = PaperHistoryRepository(engine)
        for symbol in SYMBOLS:
            status = await repository.status(symbol, START_AT, range_end)
            completeness = (
                status.valid_count / status.expected_count * 100
                if status.expected_count
                else 100.0
            )
            print(
                f"{symbol}: {status.valid_count}/{status.expected_count} "
                f"({completeness:.4f}%) "
                f"first={status.first_open_time} last={status.last_open_time} "
                f"first_missing={status.first_missing_at}"
            )
    finally:
        await engine.dispose()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Backfill BTCUSDT and ETHUSDT 5-minute Trade OHLCV from 2020-04-01"
        )
    )
    parser.add_argument("command", choices=("run", "status"), nargs="?", default="run")
    parser.add_argument("--request-interval", type=float)
    args = parser.parse_args()
    if args.request_interval is not None and args.request_interval < 0:
        parser.error("--request-interval cannot be negative")
    return args


def main() -> None:
    settings = get_settings()
    configure_logging(settings, "paper-history")
    args = parse_args()
    if args.command == "status":
        asyncio.run(show_status(settings))
    else:
        request_interval = (
            settings.paper_history_request_interval_seconds
            if args.request_interval is None
            else cast(float, args.request_interval)
        )
        asyncio.run(run(settings, request_interval))


if __name__ == "__main__":
    main()
