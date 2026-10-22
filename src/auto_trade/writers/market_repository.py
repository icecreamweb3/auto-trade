from __future__ import annotations

import hashlib
import json
from datetime import datetime
from typing import cast
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from auto_trade.contracts import (
    InstrumentCatalogPayload,
    InstrumentRulePayload,
    KlinePayload,
    MarketSource,
    OpenInterestPayload,
    RankingSnapshotPayload,
    TickerMinutePayload,
)


class IncomingEvent(BaseModel):
    model_config = ConfigDict(frozen=True)

    event_id: UUID
    event_type: str = Field(min_length=1, max_length=80)
    schema_version: int = Field(ge=1)
    source: MarketSource
    exchange_event_time: datetime | None = None
    collected_at: datetime
    node_id: str
    shard_id: str
    payload: dict[str, object]


def payload_hash(value: object) -> str:
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(canonical.encode()).hexdigest()


def json_text(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


class MarketRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def write_raw(self, event: IncomingEvent) -> None:
        raw = event.payload
        request_params = raw.get("request_params", {})
        symbol: str | None = None
        if isinstance(request_params, dict) and request_params.get("symbol") is not None:
            symbol = str(request_params["symbol"])
        async with self._engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    INSERT INTO market.raw_events (
                        event_id, event_time, exchange, market, symbol, event_type,
                        schema_version, source, exchange_event_time, collected_at,
                        published_at, node_id, shard_id, payload_hash, payload,
                        quality_status
                    ) VALUES (
                        :event_id, :event_time, 'BINANCE', 'USD_M_FUTURES', :symbol,
                        :event_type, :schema_version, :source, :exchange_event_time,
                        :collected_at, :published_at, :node_id, :shard_id,
                        :payload_hash, CAST(:payload AS jsonb), 'VALID'
                    )
                    ON CONFLICT (event_id, event_time) DO NOTHING
                    """
                ),
                {
                    "event_id": event.event_id,
                    "event_time": event.collected_at,
                    "symbol": symbol,
                    "event_type": event.event_type,
                    "schema_version": event.schema_version,
                    "source": event.source.value,
                    "exchange_event_time": event.exchange_event_time,
                    "collected_at": event.collected_at,
                    "published_at": event.collected_at,
                    "node_id": event.node_id,
                    "shard_id": event.shard_id,
                    "payload_hash": payload_hash(raw),
                    "payload": json_text(raw),
                },
            )

    async def write_normalized(self, event: IncomingEvent) -> None:
        if event.event_type == "INSTRUMENT_RULE_SNAPSHOT":
            await self._write_instrument_rule(
                event, InstrumentRulePayload.model_validate(event.payload)
            )
            return
        if event.event_type == "INSTRUMENT_CATALOG_SNAPSHOT":
            await self._write_catalog(
                event, InstrumentCatalogPayload.model_validate(event.payload)
            )
            return
        if event.event_type == "TICKER_MINUTE_SNAPSHOT":
            await self._write_ticker(event, TickerMinutePayload.model_validate(event.payload))
            return
        if event.event_type == "KLINE_CLOSED":
            await self._write_kline(event, KlinePayload.model_validate(event.payload))
            return
        if event.event_type == "OPEN_INTEREST_SNAPSHOT":
            await self._write_open_interest(
                event, OpenInterestPayload.model_validate(event.payload)
            )
            return
        if event.event_type == "RANKING_SNAPSHOT":
            await self._write_ranking(
                event, RankingSnapshotPayload.model_validate(event.payload)
            )
            return
        raise ValueError(f"unsupported normalized event type: {event.event_type}")

    async def _instrument_id(self, connection: AsyncConnection, symbol: str) -> int:
        result = await connection.execute(
            text(
                """
                SELECT instrument_id
                FROM core.instruments
                WHERE exchange = 'BINANCE'
                  AND market = 'USD_M_FUTURES'
                  AND symbol = :symbol
                """
            ),
            {"symbol": symbol},
        )
        instrument_id = result.scalar_one_or_none()
        if instrument_id is None:
            raise LookupError(f"instrument is not registered: {symbol}")
        return cast(int, instrument_id)

    async def _write_instrument_rule(
        self,
        event: IncomingEvent,
        payload: InstrumentRulePayload,
    ) -> None:
        rule_payload = payload.complete_rule_payload
        rule_hash = payload_hash(rule_payload)
        delisted_at = event.collected_at if payload.trading_status != "TRADING" else None
        async with self._engine.begin() as connection:
            instrument_id = cast(
                int,
                (
                    await connection.execute(
                        text(
                            """
                            INSERT INTO core.instruments (
                                exchange, market, symbol, base_asset, quote_asset,
                                contract_type, trading_status, onboard_at, delisted_at,
                                first_seen_at, last_seen_at, status_effective_at
                            ) VALUES (
                                'BINANCE', 'USD_M_FUTURES', :symbol, :base_asset, 'USDT',
                                'PERPETUAL', :trading_status, :onboard_at, :delisted_at,
                                :collected_at, :collected_at, :collected_at
                            )
                            ON CONFLICT (exchange, market, symbol) DO UPDATE SET
                                base_asset = EXCLUDED.base_asset,
                                trading_status = EXCLUDED.trading_status,
                                onboard_at = COALESCE(
                                    core.instruments.onboard_at,
                                    EXCLUDED.onboard_at
                                ),
                                delisted_at = EXCLUDED.delisted_at,
                                last_seen_at = EXCLUDED.last_seen_at,
                                status_effective_at = EXCLUDED.status_effective_at
                            RETURNING instrument_id
                            """
                        ),
                        {
                            "symbol": payload.symbol,
                            "base_asset": payload.base_asset,
                            "trading_status": payload.trading_status,
                            "onboard_at": payload.onboard_at,
                            "delisted_at": delisted_at,
                            "collected_at": event.collected_at,
                        },
                    )
                ).scalar_one(),
            )
            await self._record_status_if_changed(
                connection, event, instrument_id, payload.trading_status, rule_hash
            )
            current = (
                await connection.execute(
                    text(
                        """
                        SELECT payload_hash, effective_from
                        FROM core.instrument_rule_versions
                        WHERE instrument_id = :instrument_id
                        ORDER BY effective_from DESC
                        LIMIT 1
                        FOR UPDATE
                        """
                    ),
                    {"instrument_id": instrument_id},
                )
            ).mappings().one_or_none()
            if current is not None and current["payload_hash"] == rule_hash:
                return
            if current is not None and current["effective_from"] < event.collected_at:
                await connection.execute(
                    text(
                        """
                        UPDATE core.instrument_rule_versions
                        SET effective_to = :effective_to
                        WHERE instrument_id = :instrument_id
                          AND effective_to IS NULL
                          AND effective_from < :effective_to
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "effective_to": event.collected_at,
                    },
                )
            await connection.execute(
                text(
                    """
                    INSERT INTO core.instrument_rule_versions (
                        instrument_id, effective_from, price_precision,
                        quantity_precision, tick_size, step_size, min_quantity,
                        max_quantity, min_notional, market_step_size,
                        market_min_quantity, market_max_quantity, max_open_orders,
                        max_algo_orders, percent_price_rules, leverage_brackets,
                        complete_rule_payload, source_event_id, payload_hash,
                        exchange_data_time, collected_at
                    ) VALUES (
                        :instrument_id, :effective_from, :price_precision,
                        :quantity_precision, :tick_size, :step_size, :min_quantity,
                        :max_quantity, :min_notional, :market_step_size,
                        :market_min_quantity, :market_max_quantity, :max_open_orders,
                        :max_algo_orders, CAST(:percent_price_rules AS jsonb), '[]'::jsonb,
                        CAST(:complete_rule_payload AS jsonb), :source_event_id,
                        :payload_hash, :exchange_data_time, :collected_at
                    )
                    ON CONFLICT (instrument_id, effective_from) DO NOTHING
                    """
                ),
                {
                    "instrument_id": instrument_id,
                    "effective_from": event.collected_at,
                    "price_precision": payload.price_precision,
                    "quantity_precision": payload.quantity_precision,
                    "tick_size": payload.tick_size,
                    "step_size": payload.step_size,
                    "min_quantity": payload.min_quantity,
                    "max_quantity": payload.max_quantity,
                    "min_notional": payload.min_notional,
                    "market_step_size": payload.market_step_size,
                    "market_min_quantity": payload.market_min_quantity,
                    "market_max_quantity": payload.market_max_quantity,
                    "max_open_orders": payload.max_open_orders,
                    "max_algo_orders": payload.max_algo_orders,
                    "percent_price_rules": json_text(payload.percent_price_rules),
                    "complete_rule_payload": json_text(rule_payload),
                    "source_event_id": event.event_id,
                    "payload_hash": rule_hash,
                    "exchange_data_time": event.exchange_event_time,
                    "collected_at": event.collected_at,
                },
            )

    async def _record_status_if_changed(
        self,
        connection: AsyncConnection,
        event: IncomingEvent,
        instrument_id: int,
        exchange_status: str,
        disposition_hash: str,
    ) -> None:
        latest_status = (
            await connection.execute(
                text(
                    """
                    SELECT exchange_status
                    FROM core.instrument_status_history
                    WHERE instrument_id = :instrument_id
                    ORDER BY effective_at DESC
                    LIMIT 1
                    """
                ),
                {"instrument_id": instrument_id},
            )
        ).scalar_one_or_none()
        if latest_status == exchange_status:
            return
        status_hash = payload_hash(
            {"exchange_status": exchange_status, "disposition_hash": disposition_hash}
        )
        await connection.execute(
            text(
                """
                INSERT INTO core.instrument_status_history (
                    instrument_id, exchange_status, system_status, discovered_at,
                    effective_at, disposition, source_event_id, payload_hash
                ) VALUES (
                    :instrument_id, :exchange_status, :system_status, :discovered_at,
                    :effective_at, CAST(:disposition AS jsonb), :source_event_id,
                    :payload_hash
                )
                ON CONFLICT (instrument_id, effective_at, payload_hash) DO NOTHING
                """
            ),
            {
                "instrument_id": instrument_id,
                "exchange_status": exchange_status,
                "system_status": "ACTIVE" if exchange_status == "TRADING" else "INACTIVE",
                "discovered_at": event.collected_at,
                "effective_at": event.collected_at,
                "disposition": json_text({"source": "exchange_info"}),
                "source_event_id": event.event_id,
                "payload_hash": status_hash,
            },
        )

    async def _write_catalog(
        self,
        event: IncomingEvent,
        payload: InstrumentCatalogPayload,
    ) -> None:
        if not payload.is_full_snapshot:
            return
        async with self._engine.begin() as connection:
            missing = (
                await connection.execute(
                    text(
                        """
                        UPDATE core.instruments
                        SET trading_status = 'DELISTED',
                            delisted_at = COALESCE(delisted_at, :snapshot_time),
                            status_effective_at = :snapshot_time
                        WHERE exchange = 'BINANCE'
                          AND market = 'USD_M_FUTURES'
                          AND trading_status <> 'DELISTED'
                          AND NOT (symbol = ANY(CAST(:symbols AS varchar[])))
                        RETURNING instrument_id, symbol
                        """
                    ),
                    {
                        "snapshot_time": payload.snapshot_time,
                        "symbols": list(payload.symbols),
                    },
                )
            ).mappings().all()
            for row in missing:
                await self._record_status_if_changed(
                    connection,
                    event,
                    cast(int, row["instrument_id"]),
                    "DELISTED",
                    payload_hash({"symbol": row["symbol"], "reason": "absent_from_catalog"}),
                )

    async def _write_ticker(
        self,
        event: IncomingEvent,
        payload: TickerMinutePayload,
    ) -> None:
        ticker_hash = payload_hash(payload.model_dump(mode="json"))
        async with self._engine.begin() as connection:
            instrument_id = await self._instrument_id(connection, payload.symbol)
            await connection.execute(
                text(
                    """
                    INSERT INTO market.ticker_minutes (
                        instrument_id, minute_time, last_price, mark_price,
                        index_price, price_change_24h, rolling_window_start,
                        rolling_window_end, rolling_open_price, quote_volume_24h,
                        high_price_24h, low_price_24h, source_event_ids, source,
                        payload_hash, quality_status, exchange_event_time, collected_at
                    ) VALUES (
                        :instrument_id, :minute_time, :last_price, :mark_price,
                        :index_price, :price_change_24h, :rolling_window_start,
                        :rolling_window_end, :rolling_open_price, :quote_volume_24h,
                        :high_price_24h, :low_price_24h,
                        CAST(:source_event_ids AS uuid[]), :source, :payload_hash,
                        :quality_status, :exchange_event_time, :collected_at
                    )
                    ON CONFLICT (instrument_id, minute_time) DO UPDATE SET
                        last_price = EXCLUDED.last_price,
                        mark_price = EXCLUDED.mark_price,
                        index_price = EXCLUDED.index_price,
                        price_change_24h = EXCLUDED.price_change_24h,
                        rolling_window_start = EXCLUDED.rolling_window_start,
                        rolling_window_end = EXCLUDED.rolling_window_end,
                        rolling_open_price = EXCLUDED.rolling_open_price,
                        quote_volume_24h = EXCLUDED.quote_volume_24h,
                        high_price_24h = EXCLUDED.high_price_24h,
                        low_price_24h = EXCLUDED.low_price_24h,
                        source_event_ids = EXCLUDED.source_event_ids,
                        payload_hash = EXCLUDED.payload_hash,
                        quality_status = EXCLUDED.quality_status,
                        exchange_event_time = EXCLUDED.exchange_event_time,
                        collected_at = EXCLUDED.collected_at
                    WHERE EXCLUDED.collected_at >= market.ticker_minutes.collected_at
                    """
                ),
                {
                    "instrument_id": instrument_id,
                    "minute_time": payload.minute_time,
                    "last_price": payload.last_price,
                    "mark_price": payload.mark_price,
                    "index_price": payload.index_price,
                    "price_change_24h": payload.price_change_24h,
                    "rolling_window_start": payload.rolling_window_start,
                    "rolling_window_end": payload.rolling_window_end,
                    "rolling_open_price": payload.rolling_open_price,
                    "quote_volume_24h": payload.quote_volume_24h,
                    "high_price_24h": payload.high_price_24h,
                    "low_price_24h": payload.low_price_24h,
                    "source_event_ids": [event.event_id],
                    "source": event.source.value,
                    "payload_hash": ticker_hash,
                    "quality_status": payload.quality_status.value,
                    "exchange_event_time": event.exchange_event_time,
                    "collected_at": event.collected_at,
                },
            )
            if payload.current_funding_rate is not None:
                await connection.execute(
                    text(
                        """
                        INSERT INTO market.funding_observations (
                            instrument_id, observed_at, current_rate,
                            next_settlement_at, mark_price, source,
                            source_event_id, payload_hash, quality_status,
                            collected_at
                        ) VALUES (
                            :instrument_id, :observed_at, :current_rate,
                            :next_settlement_at, :mark_price, :source,
                            :source_event_id, :payload_hash, :quality_status,
                            :collected_at
                        )
                        ON CONFLICT (instrument_id, observed_at) DO UPDATE SET
                            current_rate = EXCLUDED.current_rate,
                            next_settlement_at = EXCLUDED.next_settlement_at,
                            mark_price = EXCLUDED.mark_price,
                            source_event_id = EXCLUDED.source_event_id,
                            payload_hash = EXCLUDED.payload_hash,
                            quality_status = EXCLUDED.quality_status,
                            collected_at = EXCLUDED.collected_at
                        WHERE EXCLUDED.collected_at >= market.funding_observations.collected_at
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "observed_at": payload.minute_time,
                        "current_rate": payload.current_funding_rate,
                        "next_settlement_at": payload.next_funding_time,
                        "mark_price": payload.mark_price,
                        "source": event.source.value,
                        "source_event_id": event.event_id,
                        "payload_hash": ticker_hash,
                        "quality_status": payload.quality_status.value,
                        "collected_at": event.collected_at,
                    },
                )

    async def _write_kline(self, event: IncomingEvent, payload: KlinePayload) -> None:
        kline_hash = payload_hash(payload.model_dump(mode="json"))
        async with self._engine.begin() as connection:
            # asyncpg prepares repeated statements, and PostgreSQL may eventually
            # switch them to a generic plan.  A generic plan cannot prune the
            # TimescaleDB chunk from the open_time parameter at plan time, so the
            # row lock query can take relation locks on every kline chunk.
            await connection.execute(
                text(
                    "SELECT set_config("
                    "'plan_cache_mode', 'force_custom_plan', true)"
                )
            )
            instrument_id = await self._instrument_id(connection, payload.symbol)
            current = (
                await connection.execute(
                    text(
                        """
                        SELECT revision_no, payload_hash
                        FROM market.klines
                        WHERE instrument_id = :instrument_id
                          AND price_type = :price_type
                          AND interval_seconds = :interval_seconds
                          AND open_time = :open_time
                          AND is_current
                        FOR UPDATE
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "price_type": payload.price_type.value,
                        "interval_seconds": payload.interval_seconds,
                        "open_time": payload.open_time,
                    },
                )
            ).mappings().one_or_none()
            if current is not None and current["payload_hash"] == kline_hash:
                return
            revision_no = 1 if current is None else cast(int, current["revision_no"]) + 1
            supersedes_revision = None if current is None else cast(int, current["revision_no"])
            if current is not None:
                await connection.execute(
                    text(
                        """
                        UPDATE market.klines
                        SET is_current = false
                        WHERE instrument_id = :instrument_id
                          AND price_type = :price_type
                          AND interval_seconds = :interval_seconds
                          AND open_time = :open_time
                          AND revision_no = :revision_no
                        """
                    ),
                    {
                        "instrument_id": instrument_id,
                        "price_type": payload.price_type.value,
                        "interval_seconds": payload.interval_seconds,
                        "open_time": payload.open_time,
                        "revision_no": supersedes_revision,
                    },
                )
            await connection.execute(
                text(
                    """
                    INSERT INTO market.klines (
                        instrument_id, price_type, interval_seconds, open_time,
                        revision_no, is_current, supersedes_revision, close_time,
                        open_price, high_price, low_price, close_price, base_volume,
                        quote_volume, trade_count, is_closed, source,
                        data_rule_version, source_event_ids, payload_hash,
                        quality_status, collected_at, effective_at
                    ) VALUES (
                        :instrument_id, :price_type, :interval_seconds, :open_time,
                        :revision_no, true, :supersedes_revision, :close_time,
                        :open_price, :high_price, :low_price, :close_price,
                        :base_volume, :quote_volume, :trade_count, :is_closed,
                        :source, 'collector-v1', CAST(:source_event_ids AS uuid[]),
                        :payload_hash, :quality_status, :collected_at, :effective_at
                    )
                    """
                ),
                {
                    "instrument_id": instrument_id,
                    "price_type": payload.price_type.value,
                    "interval_seconds": payload.interval_seconds,
                    "open_time": payload.open_time,
                    "revision_no": revision_no,
                    "supersedes_revision": supersedes_revision,
                    "close_time": payload.close_time,
                    "open_price": payload.open_price,
                    "high_price": payload.high_price,
                    "low_price": payload.low_price,
                    "close_price": payload.close_price,
                    "base_volume": payload.base_volume,
                    "quote_volume": payload.quote_volume,
                    "trade_count": payload.trade_count,
                    "is_closed": payload.is_closed,
                    "source": event.source.value,
                    "source_event_ids": [event.event_id],
                    "payload_hash": kline_hash,
                    "quality_status": payload.quality_status.value,
                    "collected_at": event.collected_at,
                    "effective_at": event.collected_at,
                },
            )

    async def _write_open_interest(
        self,
        event: IncomingEvent,
        payload: OpenInterestPayload,
    ) -> None:
        observation_hash = payload_hash(payload.model_dump(mode="json"))
        async with self._engine.begin() as connection:
            instrument_id = await self._instrument_id(connection, payload.symbol)
            await connection.execute(
                text(
                    """
                    INSERT INTO market.open_interest_observations (
                        instrument_id, observed_at, open_interest_qty,
                        open_interest_value, source, source_event_id,
                        payload_hash, quality_status, collected_at
                    ) VALUES (
                        :instrument_id, :observed_at, :open_interest_qty,
                        :open_interest_value, :source, :source_event_id,
                        :payload_hash, :quality_status, :collected_at
                    )
                    ON CONFLICT (instrument_id, observed_at) DO NOTHING
                    """
                ),
                {
                    "instrument_id": instrument_id,
                    "observed_at": payload.observed_at,
                    "open_interest_qty": payload.open_interest_qty,
                    "open_interest_value": payload.open_interest_value,
                    "source": event.source.value,
                    "source_event_id": event.event_id,
                    "payload_hash": observation_hash,
                    "quality_status": payload.quality_status.value,
                    "collected_at": event.collected_at,
                },
            )

    async def _write_ranking(
        self,
        event: IncomingEvent,
        payload: RankingSnapshotPayload,
    ) -> None:
        snapshot_hash = payload_hash(payload.model_dump(mode="json"))
        async with self._engine.begin() as connection:
            ranking_snapshot_id = cast(
                UUID,
                (
                    await connection.execute(
                        text(
                            """
                            INSERT INTO market.ranking_snapshots (
                                ranking_snapshot_id, ranking_type, snapshot_at,
                                utc_trade_date, scheduled_at, generated_at,
                                generation_mode, source_kline_time, window_start,
                                window_end, item_count, source_event_ids,
                                snapshot_hash, quality_status
                            ) VALUES (
                                :ranking_snapshot_id, :ranking_type, :snapshot_at,
                                :utc_trade_date, :scheduled_at, :generated_at,
                                :generation_mode, NULL, :window_start, :window_end,
                                :item_count, CAST(:source_event_ids AS uuid[]),
                                :snapshot_hash, :quality_status
                            )
                            ON CONFLICT (ranking_type, snapshot_at) DO UPDATE SET
                                scheduled_at = EXCLUDED.scheduled_at,
                                generated_at = EXCLUDED.generated_at,
                                generation_mode = EXCLUDED.generation_mode,
                                window_start = EXCLUDED.window_start,
                                window_end = EXCLUDED.window_end,
                                item_count = EXCLUDED.item_count,
                                source_event_ids = EXCLUDED.source_event_ids,
                                snapshot_hash = EXCLUDED.snapshot_hash,
                                quality_status = EXCLUDED.quality_status
                            RETURNING ranking_snapshot_id
                            """
                        ),
                        {
                            "ranking_snapshot_id": event.event_id,
                            "ranking_type": payload.ranking_type,
                            "snapshot_at": payload.snapshot_at,
                            "utc_trade_date": (
                                payload.snapshot_at.date()
                                if payload.ranking_type == "UTC_DAILY_2355"
                                else None
                            ),
                            "scheduled_at": payload.scheduled_at,
                            "generated_at": payload.generated_at,
                            "generation_mode": payload.generation_mode,
                            "window_start": payload.window_start,
                            "window_end": payload.window_end,
                            "item_count": len(payload.entries),
                            "source_event_ids": [event.event_id],
                            "snapshot_hash": snapshot_hash,
                            "quality_status": payload.quality_status.value,
                        },
                    )
                ).scalar_one(),
            )
            await connection.execute(
                text(
                    "DELETE FROM market.ranking_entries "
                    "WHERE ranking_snapshot_id = :ranking_snapshot_id"
                ),
                {"ranking_snapshot_id": ranking_snapshot_id},
            )
            for entry in payload.entries:
                instrument_id = await self._instrument_id(connection, entry.symbol)
                await connection.execute(
                    text(
                        """
                        INSERT INTO market.ranking_entries (
                            ranking_snapshot_id, rank_no, instrument_id,
                            price_change, reference_open_price, snapshot_price,
                            base_volume, quote_volume, amplitude,
                            period_high_price, period_low_price, metrics
                        ) VALUES (
                            :ranking_snapshot_id, :rank_no, :instrument_id,
                            :price_change, :reference_open_price, :snapshot_price,
                            :base_volume, :quote_volume, :amplitude,
                            :period_high_price, :period_low_price,
                            CAST(:metrics AS jsonb)
                        )
                        """
                    ),
                    {
                        "ranking_snapshot_id": ranking_snapshot_id,
                        "rank_no": entry.rank_no,
                        "instrument_id": instrument_id,
                        "price_change": entry.price_change,
                        "reference_open_price": entry.reference_open_price,
                        "snapshot_price": entry.snapshot_price,
                        "base_volume": entry.base_volume,
                        "quote_volume": entry.quote_volume,
                        "amplitude": entry.amplitude,
                        "period_high_price": entry.period_high_price,
                        "period_low_price": entry.period_low_price,
                        "metrics": json_text(entry.metrics),
                    },
                )
