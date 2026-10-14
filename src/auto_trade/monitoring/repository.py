from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine


@dataclass(frozen=True, slots=True)
class CoverageRow:
    key: str
    latest_at: datetime | None
    age_seconds: float | None
    actual_symbols: int
    websocket_symbols: int | None


@dataclass(frozen=True, slots=True)
class WebSocketSyncRow:
    key: str
    expected: int
    succeeded: int
    rest_fallback: int
    other_source: int
    missing: int


@dataclass(frozen=True, slots=True)
class BackfillRows:
    counts: dict[str, int]
    open_gaps: int
    oldest_pending_seconds: float | None
    succeeded_last_hour: int = 0
    created_last_hour: int = 0
    finished_last_hour: int = 0
    last_succeeded_at: datetime | None = None
    pending_range_start: datetime | None = None
    pending_range_end: datetime | None = None
    running_jobs: tuple[BackfillTaskRow, ...] = ()


@dataclass(frozen=True, slots=True)
class BackfillTaskRow:
    symbol: str
    data_type: str
    interval_seconds: int
    range_start: datetime
    range_end: datetime
    started_at: datetime | None
    attempts: int


@dataclass(frozen=True, slots=True)
class RestUsageRow:
    request_rate_1m: int | None
    used_weight_1m: int | None
    observed_at: datetime | None


@dataclass(frozen=True, slots=True)
class TableSizeRow:
    schema_name: str
    table_name: str
    is_hypertable: bool
    estimated_rows: int
    table_bytes: int
    index_bytes: int
    toast_bytes: int
    total_bytes: int
    chunk_count: int | None = None
    compression_enabled: bool | None = None
    columnstore_chunks: int = 0
    columnstore_before_bytes: int = 0
    columnstore_after_bytes: int = 0
    columnstore_policy_enabled: bool = False


@dataclass(frozen=True, slots=True)
class DatabaseSnapshot:
    active_symbols: int
    coverage: tuple[CoverageRow, ...]
    backfill: BackfillRows
    rest_usage: RestUsageRow
    database_size_bytes: int
    database_size_display: str
    cache_hit_percent: float | None = None
    largest_tables: tuple[TableSizeRow, ...] = ()
    websocket_sync: tuple[WebSocketSyncRow, ...] = ()


@dataclass(frozen=True, slots=True)
class RankingEntryRow:
    utc_trade_date: date
    snapshot_at: datetime
    rank_no: int
    symbol: str
    price_change: float
    reference_open_price: float | None
    snapshot_price: float | None
    base_volume: float | None
    quote_volume: float | None
    amplitude: float | None
    period_high_price: float | None
    period_high_at: datetime | None
    period_low_price: float | None
    period_low_at: datetime | None
    open_interest_qty: float | None
    open_interest_value: float | None
    open_interest_status: str
    quality_status: str


@dataclass(frozen=True, slots=True)
class RankingQueryRows:
    available_first_date: date | None
    available_last_date: date | None
    date_from: date | None
    date_to: date | None
    total: int
    matching_days: int
    average_change: float | None
    maximum_change: float | None
    minimum_change: float | None
    items: tuple[RankingEntryRow, ...]


def websocket_sync_range_end(
    now: datetime, interval_seconds: int, safety_delay_seconds: int
) -> datetime:
    """Return the latest stable interval boundary for monitoring."""
    safe_now = now.astimezone(UTC) - timedelta(seconds=safety_delay_seconds)
    timestamp = int(safe_now.timestamp())
    aligned = timestamp // interval_seconds * interval_seconds
    return datetime.fromtimestamp(aligned, tz=UTC)


class MonitoringRepository:
    def __init__(
        self, engine: AsyncEngine, *, data_safety_delay_seconds: int = 30
    ) -> None:
        self._engine = engine
        self._data_safety_delay_seconds = data_safety_delay_seconds

    async def snapshot(self) -> DatabaseSnapshot:
        async with self._engine.connect() as connection:
            active_symbols = cast(
                int,
                (
                    await connection.execute(
                        text(
                            """
                            SELECT count(*)
                            FROM core.instruments
                            WHERE exchange = 'BINANCE'
                              AND market = 'USD_M_FUTURES'
                              AND quote_asset = 'USDT'
                              AND contract_type = 'PERPETUAL'
                              AND trading_status = 'TRADING'
                            """
                        )
                    )
                ).scalar_one(),
            )

            coverage = list(await self._kline_coverage(connection))
            coverage.append(await self._ticker_coverage(connection))
            coverage.append(await self._open_interest_coverage(connection))
            websocket_sync = await self._websocket_sync(connection, active_symbols)

            backfill = await self._backfill(connection)
            rest_usage = await self._rest_usage(connection)
            database_row = (
                await connection.execute(
                    text(
                        """
                        SELECT pg_database_size(current_database()) AS size_bytes,
                               pg_size_pretty(
                                   pg_database_size(current_database())
                               ) AS size_display
                        """
                    )
                )
            ).mappings().one()
            cache_row = (
                await connection.execute(
                    text(
                        """
                        SELECT 100.0 * blks_hit /
                                   NULLIF(blks_hit + blks_read, 0)
                                   AS cache_hit_percent
                        FROM pg_stat_database
                        WHERE datname = current_database()
                        """
                    )
                )
            ).mappings().one()
            table_rows = (
                await connection.execute(
                    text(
                        """
                        WITH columnstore_policies AS (
                            SELECT
                                hypertable_schema AS schema_name,
                                hypertable_name AS table_name,
                                bool_or(scheduled) AS policy_enabled
                            FROM timescaledb_information.jobs
                            WHERE proc_name = 'policy_compression'
                            GROUP BY 1, 2
                        ), hypertable_sizes AS (
                            SELECT
                                h.hypertable_schema AS schema_name,
                                h.hypertable_name AS table_name,
                                true AS is_hypertable,
                                approximate_row_count(
                                    format(
                                        '%I.%I',
                                        h.hypertable_schema,
                                        h.hypertable_name
                                    )::regclass
                                ) AS estimated_rows,
                                sizes.table_bytes,
                                sizes.index_bytes,
                                sizes.toast_bytes,
                                sizes.total_bytes,
                                h.num_chunks AS chunk_count,
                                h.compression_enabled,
                                coalesce(
                                    columnstore.number_compressed_chunks, 0
                                ) AS columnstore_chunks,
                                coalesce(
                                    columnstore.before_compression_total_bytes, 0
                                ) AS columnstore_before_bytes,
                                coalesce(
                                    columnstore.after_compression_total_bytes, 0
                                ) AS columnstore_after_bytes,
                                coalesce(policy.policy_enabled, false)
                                    AS columnstore_policy_enabled
                            FROM timescaledb_information.hypertables h
                            CROSS JOIN LATERAL hypertable_detailed_size(
                                format(
                                    '%I.%I',
                                    h.hypertable_schema,
                                    h.hypertable_name
                                )::regclass
                            ) sizes
                            LEFT JOIN LATERAL hypertable_columnstore_stats(
                                format(
                                    '%I.%I',
                                    h.hypertable_schema,
                                    h.hypertable_name
                                )::regclass
                            ) columnstore ON true
                            LEFT JOIN columnstore_policies policy
                              ON policy.schema_name = h.hypertable_schema
                             AND policy.table_name = h.hypertable_name
                        ), regular_sizes AS (
                            SELECT
                                stats.schemaname AS schema_name,
                                stats.relname AS table_name,
                                false AS is_hypertable,
                                stats.n_live_tup::bigint AS estimated_rows,
                                pg_relation_size(stats.relid) AS table_bytes,
                                pg_indexes_size(stats.relid) AS index_bytes,
                                greatest(
                                    pg_total_relation_size(stats.relid)
                                    - pg_relation_size(stats.relid)
                                    - pg_indexes_size(stats.relid),
                                    0
                                ) AS toast_bytes,
                                pg_total_relation_size(stats.relid) AS total_bytes,
                                NULL::integer AS chunk_count,
                                NULL::boolean AS compression_enabled,
                                0::bigint AS columnstore_chunks,
                                0::bigint AS columnstore_before_bytes,
                                0::bigint AS columnstore_after_bytes,
                                false AS columnstore_policy_enabled
                            FROM pg_stat_user_tables stats
                            WHERE stats.schemaname !~ '^_timescaledb_'
                              AND NOT EXISTS (
                                SELECT 1
                                FROM timescaledb_information.hypertables h
                                WHERE h.hypertable_schema = stats.schemaname
                                  AND h.hypertable_name = stats.relname
                            )
                        )
                        SELECT * FROM (
                            SELECT * FROM hypertable_sizes
                            UNION ALL
                            SELECT * FROM regular_sizes
                        ) relation_sizes
                        ORDER BY total_bytes DESC
                        LIMIT 12
                        """
                    )
                )
            ).mappings().all()

        return DatabaseSnapshot(
            active_symbols=active_symbols,
            coverage=tuple(coverage),
            backfill=backfill,
            rest_usage=rest_usage,
            database_size_bytes=cast(int, database_row["size_bytes"]),
            database_size_display=cast(str, database_row["size_display"]),
            cache_hit_percent=(
                float(cache_row["cache_hit_percent"])
                if cache_row["cache_hit_percent"] is not None
                else None
            ),
            largest_tables=tuple(
                TableSizeRow(
                    schema_name=cast(str, row["schema_name"]),
                    table_name=cast(str, row["table_name"]),
                    is_hypertable=cast(bool, row["is_hypertable"]),
                    estimated_rows=cast(int, row["estimated_rows"] or 0),
                    table_bytes=cast(int, row["table_bytes"] or 0),
                    index_bytes=cast(int, row["index_bytes"] or 0),
                    toast_bytes=cast(int, row["toast_bytes"] or 0),
                    total_bytes=cast(int, row["total_bytes"] or 0),
                    chunk_count=cast(int | None, row["chunk_count"]),
                    compression_enabled=cast(
                        bool | None, row["compression_enabled"]
                    ),
                    columnstore_chunks=cast(
                        int, row["columnstore_chunks"] or 0
                    ),
                    columnstore_before_bytes=cast(
                        int, row["columnstore_before_bytes"] or 0
                    ),
                    columnstore_after_bytes=cast(
                        int, row["columnstore_after_bytes"] or 0
                    ),
                    columnstore_policy_enabled=cast(
                        bool, row["columnstore_policy_enabled"]
                    ),
                )
                for row in table_rows
            ),
            websocket_sync=websocket_sync,
        )

    async def _websocket_sync(
        self, connection: AsyncConnection, active_symbols: int
    ) -> tuple[WebSocketSyncRow, ...]:
        now = datetime.now(UTC)
        range_end_60 = websocket_sync_range_end(
            now, 60, self._data_safety_delay_seconds
        )
        range_end_300 = websocket_sync_range_end(
            now, 300, self._data_safety_delay_seconds
        )
        rows = (
            await connection.execute(
                text(
                    """
                    WITH series(key, price_type, interval_seconds, range_end) AS (
                        VALUES
                            ('trade_60', 'TRADE', 60,
                             CAST(:range_end_60 AS timestamptz)),
                            ('mark_60', 'MARK', 60,
                             CAST(:range_end_60 AS timestamptz)),
                            ('trade_300', 'TRADE', 300,
                             CAST(:range_end_300 AS timestamptz))
                    ), bounds AS (
                        SELECT
                            key, price_type, interval_seconds,
                            range_end - interval '1 hour' AS range_start,
                            range_end
                        FROM series
                    )
                    SELECT
                        b.key,
                        :active_symbols *
                            floor(extract(epoch FROM (b.range_end - b.range_start)) /
                                  b.interval_seconds)::bigint AS expected,
                        count(*) FILTER (WHERE k.source = 'WEBSOCKET') AS succeeded,
                        count(*) FILTER (WHERE k.source = 'REST') AS rest_fallback,
                        count(*) FILTER (
                            WHERE k.source NOT IN ('WEBSOCKET', 'REST')
                        ) AS other_source,
                        greatest(
                            :active_symbols *
                                floor(extract(epoch FROM (
                                    b.range_end - b.range_start
                                )) / b.interval_seconds)::bigint
                                - count(k.instrument_id),
                            0
                        ) AS missing
                    FROM bounds b
                    LEFT JOIN market.klines k
                      ON k.price_type = b.price_type
                     AND k.interval_seconds = b.interval_seconds
                     AND k.open_time >= b.range_start
                     AND k.open_time < b.range_end
                     AND k.is_current
                    GROUP BY b.key, b.interval_seconds, b.range_start, b.range_end
                    ORDER BY b.key
                    """
                ),
                {
                    "active_symbols": active_symbols,
                    "range_end_60": range_end_60,
                    "range_end_300": range_end_300,
                },
            )
        ).mappings().all()
        return tuple(
            WebSocketSyncRow(
                key=cast(str, row["key"]),
                expected=cast(int, row["expected"] or 0),
                succeeded=cast(int, row["succeeded"] or 0),
                rest_fallback=cast(int, row["rest_fallback"] or 0),
                other_source=cast(int, row["other_source"] or 0),
                missing=cast(int, row["missing"] or 0),
            )
            for row in rows
        )

    async def daily_rankings(
        self,
        *,
        date_from: date | None,
        date_to: date | None,
        symbol: str | None,
        rank_from: int,
        rank_to: int,
        page: int,
        page_size: int,
    ) -> RankingQueryRows:
        normalized_symbol = symbol.strip().upper() if symbol else None
        async with self._engine.connect() as connection:
            availability = (
                await connection.execute(
                    text(
                        """
                        SELECT min(utc_trade_date) AS first_date,
                               max(utc_trade_date) AS last_date
                        FROM market.ranking_snapshots
                        WHERE ranking_type = 'UTC_DAILY_2355'
                          AND quality_status = 'VALID'
                        """
                    )
                )
            ).mappings().one()
            available_first = cast(date | None, availability["first_date"])
            available_last = cast(date | None, availability["last_date"])
            effective_from = date_from
            effective_to = date_to
            if available_last is not None and effective_from is None and effective_to is None:
                effective_from = available_last
                effective_to = available_last
            elif effective_from is None:
                effective_from = available_first
            elif effective_to is None:
                effective_to = available_last

            parameters = {
                "date_from": effective_from,
                "date_to": effective_to,
                "symbol": normalized_symbol,
                "rank_from": rank_from,
                "rank_to": rank_to,
            }
            filtered_sql = """
                FROM market.ranking_snapshots s
                JOIN market.ranking_entries e USING (ranking_snapshot_id)
                JOIN core.instruments i USING (instrument_id)
                WHERE s.ranking_type = 'UTC_DAILY_2355'
                  AND s.quality_status = 'VALID'
                  AND (
                      CAST(:date_from AS date) IS NULL
                      OR s.utc_trade_date >= CAST(:date_from AS date)
                  )
                  AND (
                      CAST(:date_to AS date) IS NULL
                      OR s.utc_trade_date <= CAST(:date_to AS date)
                  )
                  AND (
                      CAST(:symbol AS text) IS NULL
                      OR upper(i.symbol) LIKE '%' || CAST(:symbol AS text) || '%'
                  )
                  AND e.rank_no BETWEEN :rank_from AND :rank_to
            """
            summary = (
                await connection.execute(
                    text(
                        """
                        SELECT count(*) AS total,
                               count(DISTINCT s.utc_trade_date) AS matching_days,
                               avg(e.price_change) AS average_change,
                               max(e.price_change) AS maximum_change,
                               min(e.price_change) AS minimum_change
                        """
                        + filtered_sql
                    ),
                    parameters,
                )
            ).mappings().one()
            rows = (
                await connection.execute(
                    text(
                        """
                        SELECT s.utc_trade_date, s.snapshot_at, s.quality_status,
                               e.rank_no, i.symbol, e.price_change,
                               e.reference_open_price, e.snapshot_price,
                               e.base_volume, e.quote_volume, e.amplitude,
                               e.period_high_price, e.period_high_at,
                               e.period_low_price, e.period_low_at,
                               e.open_interest_qty, e.open_interest_value,
                               coalesce(
                                   e.metrics->>'open_interest_status', 'UNAVAILABLE'
                               ) AS open_interest_status
                        """
                        + filtered_sql
                        + """
                        ORDER BY s.utc_trade_date DESC, e.rank_no ASC
                        LIMIT :limit OFFSET :offset
                        """
                    ),
                    parameters | {
                        "limit": page_size,
                        "offset": (page - 1) * page_size,
                    },
                )
            ).mappings().all()

        def optional_float(value: object) -> float | None:
            return float(str(value)) if value is not None else None

        return RankingQueryRows(
            available_first_date=available_first,
            available_last_date=available_last,
            date_from=effective_from,
            date_to=effective_to,
            total=cast(int, summary["total"]),
            matching_days=cast(int, summary["matching_days"]),
            average_change=optional_float(summary["average_change"]),
            maximum_change=optional_float(summary["maximum_change"]),
            minimum_change=optional_float(summary["minimum_change"]),
            items=tuple(
                RankingEntryRow(
                    utc_trade_date=cast(date, row["utc_trade_date"]),
                    snapshot_at=cast(datetime, row["snapshot_at"]),
                    rank_no=cast(int, row["rank_no"]),
                    symbol=cast(str, row["symbol"]),
                    price_change=float(row["price_change"]),
                    reference_open_price=optional_float(row["reference_open_price"]),
                    snapshot_price=optional_float(row["snapshot_price"]),
                    base_volume=optional_float(row["base_volume"]),
                    quote_volume=optional_float(row["quote_volume"]),
                    amplitude=optional_float(row["amplitude"]),
                    period_high_price=optional_float(row["period_high_price"]),
                    period_high_at=cast(datetime | None, row["period_high_at"]),
                    period_low_price=optional_float(row["period_low_price"]),
                    period_low_at=cast(datetime | None, row["period_low_at"]),
                    open_interest_qty=optional_float(row["open_interest_qty"]),
                    open_interest_value=optional_float(row["open_interest_value"]),
                    open_interest_status=cast(str, row["open_interest_status"]),
                    quality_status=cast(str, row["quality_status"]),
                )
                for row in rows
            ),
        )

    async def _kline_coverage(
        self, connection: AsyncConnection
    ) -> tuple[CoverageRow, ...]:
        rows = (
            await connection.execute(
                text(
                    """
                    WITH latest AS (
                        SELECT price_type, interval_seconds, max(open_time) AS open_time
                        FROM market.klines
                        WHERE is_current
                          AND (price_type, interval_seconds) IN (
                              ('TRADE', 60), ('MARK', 60), ('TRADE', 300)
                          )
                        GROUP BY 1, 2
                    )
                    SELECT
                        lower(k.price_type) || '_' || k.interval_seconds::text AS key,
                        l.open_time AS latest_at,
                        extract(epoch FROM clock_timestamp() - l.open_time) AS age_seconds,
                        count(DISTINCT k.instrument_id) AS actual_symbols,
                        count(DISTINCT k.instrument_id)
                            FILTER (WHERE k.source = 'WEBSOCKET') AS websocket_symbols
                    FROM market.klines k
                    JOIN latest l USING (price_type, interval_seconds, open_time)
                    WHERE k.is_current
                    GROUP BY 1, 2
                    ORDER BY 1
                    """
                )
            )
        ).mappings().all()
        return tuple(
            CoverageRow(
                key=cast(str, row["key"]),
                latest_at=cast(datetime, row["latest_at"]),
                age_seconds=float(row["age_seconds"]),
                actual_symbols=cast(int, row["actual_symbols"]),
                websocket_symbols=cast(int, row["websocket_symbols"]),
            )
            for row in rows
        )

    async def _ticker_coverage(self, connection: AsyncConnection) -> CoverageRow:
        row = (
            await connection.execute(
                text(
                    """
                    WITH latest AS (
                        SELECT max(minute_time) AS minute_time
                        FROM market.ticker_minutes
                    )
                    SELECT
                        l.minute_time AS latest_at,
                        extract(epoch FROM clock_timestamp() - l.minute_time) AS age_seconds,
                        count(t.instrument_id) FILTER (
                            WHERE t.mark_price IS NOT NULL
                              AND t.price_change_24h IS NOT NULL
                        ) AS actual_symbols,
                        count(t.instrument_id) FILTER (
                            WHERE t.source = 'WEBSOCKET'
                              AND t.mark_price IS NOT NULL
                              AND t.price_change_24h IS NOT NULL
                        ) AS websocket_symbols
                    FROM latest l
                    LEFT JOIN market.ticker_minutes t
                      ON t.minute_time = l.minute_time
                    GROUP BY l.minute_time
                    """
                )
            )
        ).mappings().one()
        latest_at = cast(datetime | None, row["latest_at"])
        return CoverageRow(
            key="ticker_60",
            latest_at=latest_at,
            age_seconds=(
                float(row["age_seconds"])
                if row["age_seconds"] is not None
                else None
            ),
            actual_symbols=cast(int, row["actual_symbols"] or 0),
            websocket_symbols=cast(int, row["websocket_symbols"] or 0),
        )

    async def _open_interest_coverage(
        self, connection: AsyncConnection
    ) -> CoverageRow:
        row = (
            await connection.execute(
                text(
                    """
                    WITH latest AS (
                        SELECT max(observed_at) AS observed_at
                        FROM market.open_interest_observations
                    )
                    SELECT
                        l.observed_at AS latest_at,
                        extract(epoch FROM clock_timestamp() - l.observed_at) AS age_seconds,
                        count(DISTINCT o.instrument_id) AS actual_symbols
                    FROM latest l
                    LEFT JOIN market.open_interest_observations o
                      ON o.observed_at >= l.observed_at - interval '10 minutes'
                     AND o.observed_at <= l.observed_at
                    GROUP BY l.observed_at
                    """
                )
            )
        ).mappings().one()
        latest_at = cast(datetime | None, row["latest_at"])
        return CoverageRow(
            key="open_interest_300",
            latest_at=latest_at,
            age_seconds=(
                float(row["age_seconds"])
                if row["age_seconds"] is not None
                else None
            ),
            actual_symbols=cast(int, row["actual_symbols"] or 0),
            websocket_symbols=None,
        )

    async def _backfill(self, connection: AsyncConnection) -> BackfillRows:
        status_rows = (
            await connection.execute(
                text(
                    """
                    SELECT status, count(*) AS count
                    FROM market.backfill_jobs
                    GROUP BY status
                    """
                )
            )
        ).mappings().all()
        running_rows = (
            await connection.execute(
                text(
                    """
                    SELECT
                        i.symbol,
                        j.data_type,
                        g.interval_seconds,
                        j.range_start,
                        j.range_end,
                        j.started_at,
                        j.attempts
                    FROM market.backfill_jobs j
                    JOIN core.instruments i USING (instrument_id)
                    JOIN market.data_gaps g USING (gap_id)
                    WHERE j.status = 'RUNNING'
                    ORDER BY j.started_at, j.created_at
                    LIMIT 3
                    """
                )
            )
        ).mappings().all()
        summary = (
            await connection.execute(
                text(
                    """
                    WITH job_stats AS (
                        SELECT
                            min(created_at) FILTER (WHERE status = 'PENDING')
                                AS oldest_pending_at,
                            min(range_start) FILTER (WHERE status = 'PENDING')
                                AS pending_range_start,
                            max(range_end) FILTER (WHERE status = 'PENDING')
                                AS pending_range_end,
                            count(*) FILTER (
                                WHERE status = 'SUCCEEDED'
                                  AND finished_at >= clock_timestamp() - interval '1 hour'
                            ) AS succeeded_last_hour,
                            count(*) FILTER (
                                WHERE created_at >= clock_timestamp() - interval '1 hour'
                            ) AS created_last_hour,
                            count(*) FILTER (
                                WHERE status IN (
                                    'SUCCEEDED', 'PARTIAL', 'FAILED', 'CANCELLED'
                                )
                                  AND finished_at >= clock_timestamp() - interval '1 hour'
                            ) AS finished_last_hour,
                            max(finished_at) FILTER (WHERE status = 'SUCCEEDED')
                                AS last_succeeded_at
                        FROM market.backfill_jobs
                    ), gap_stats AS (
                        SELECT count(*) FILTER (
                            WHERE status IN ('OPEN', 'QUEUED', 'BACKFILLING')
                        ) AS open_gaps
                        FROM market.data_gaps
                    )
                    SELECT
                        job_stats.*,
                        extract(
                            epoch FROM clock_timestamp() - job_stats.oldest_pending_at
                        ) AS oldest_pending_seconds,
                        gap_stats.open_gaps
                    FROM job_stats CROSS JOIN gap_stats
                    """
                )
            )
        ).mappings().one()
        return BackfillRows(
            counts={
                cast(str, row["status"]): cast(int, row["count"])
                for row in status_rows
            },
            open_gaps=cast(int, summary["open_gaps"] or 0),
            oldest_pending_seconds=(
                float(summary["oldest_pending_seconds"])
                if summary["oldest_pending_seconds"] is not None
                else None
            ),
            succeeded_last_hour=cast(int, summary["succeeded_last_hour"] or 0),
            created_last_hour=cast(int, summary["created_last_hour"] or 0),
            finished_last_hour=cast(int, summary["finished_last_hour"] or 0),
            last_succeeded_at=cast(datetime | None, summary["last_succeeded_at"]),
            pending_range_start=cast(
                datetime | None, summary["pending_range_start"]
            ),
            pending_range_end=cast(datetime | None, summary["pending_range_end"]),
            running_jobs=tuple(
                BackfillTaskRow(
                    symbol=cast(str, row["symbol"]),
                    data_type=cast(str, row["data_type"]),
                    interval_seconds=cast(int, row["interval_seconds"]),
                    range_start=cast(datetime, row["range_start"]),
                    range_end=cast(datetime, row["range_end"]),
                    started_at=cast(datetime | None, row["started_at"]),
                    attempts=cast(int, row["attempts"]),
                )
                for row in running_rows
            ),
        )

    async def _rest_usage(self, connection: AsyncConnection) -> RestUsageRow:
        row = (
            await connection.execute(
                text(
                    """
                    SELECT
                        max((payload ->> 'request_rate_1m')::integer) AS request_rate_1m,
                        max((payload ->> 'used_weight_1m')::integer) AS used_weight_1m,
                        max(collected_at) AS observed_at
                    FROM market.raw_events
                    WHERE collected_at >= clock_timestamp() - interval '10 minutes'
                      AND payload ? 'used_weight_1m'
                      AND payload ->> 'used_weight_1m' IS NOT NULL
                    """
                )
            )
        ).mappings().one()
        return RestUsageRow(
            request_rate_1m=cast(int | None, row["request_rate_1m"]),
            used_weight_1m=cast(int | None, row["used_weight_1m"]),
            observed_at=cast(datetime | None, row["observed_at"]),
        )
