from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.collectors.telegram_signals import ParsedTelegramSignal


@dataclass(frozen=True, slots=True)
class TelegramMessageRecord:
    channel_id: int
    message_id: int
    posted_at: datetime
    edited_at: datetime | None
    grouped_id: int | None
    reply_to_message_id: int | None
    message_text: str
    media_type: str | None
    raw_payload: dict[str, object]
    collected_at: datetime

    @property
    def payload_hash(self) -> str:
        canonical = json.dumps(
            self.raw_payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(canonical.encode()).hexdigest()


class TelegramMessageRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self.engine = engine

    async def register_channel(self, channel_id: int, username: str, title: str) -> None:
        async with self.engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    INSERT INTO market.telegram_channels (channel_id, username, title)
                    VALUES (:channel_id, :username, :title)
                    ON CONFLICT (channel_id) DO UPDATE
                    SET username = EXCLUDED.username,
                        title = EXCLUDED.title
                    """
                ),
                {"channel_id": channel_id, "username": username, "title": title},
            )

    async def latest_message_id(self, channel_id: int) -> int | None:
        async with self.engine.connect() as connection:
            value = await connection.scalar(
                text(
                    """
                    SELECT max(message_id)
                    FROM market.telegram_messages
                    WHERE channel_id = :channel_id
                    """
                ),
                {"channel_id": channel_id},
            )
        return int(value) if value is not None else None

    async def store(
        self,
        record: TelegramMessageRecord,
        signal: ParsedTelegramSignal,
    ) -> bool:
        payload_json = json.dumps(record.raw_payload, ensure_ascii=False, sort_keys=True)
        signal_metrics_json = json.dumps(signal.metrics, sort_keys=True)
        parameters = {
            "channel_id": record.channel_id,
            "message_id": record.message_id,
            "posted_at": record.posted_at,
            "edited_at": record.edited_at,
            "grouped_id": record.grouped_id,
            "reply_to_message_id": record.reply_to_message_id,
            "message_text": record.message_text,
            "media_type": record.media_type,
            "raw_payload": payload_json,
            "payload_hash": record.payload_hash,
            "collected_at": record.collected_at,
        }
        async with self.engine.begin() as connection:
            changed_row = (
                await connection.execute(
                    text(
                        """
                        INSERT INTO market.telegram_messages (
                            channel_id, message_id, posted_at, edited_at,
                            grouped_id, reply_to_message_id, message_text,
                            media_type, raw_payload, payload_hash, collected_at
                        ) VALUES (
                            :channel_id, :message_id, :posted_at, :edited_at,
                            :grouped_id, :reply_to_message_id, :message_text,
                            :media_type, CAST(:raw_payload AS jsonb),
                            :payload_hash, :collected_at
                        )
                        ON CONFLICT (channel_id, message_id) DO UPDATE
                        SET posted_at = EXCLUDED.posted_at,
                            edited_at = EXCLUDED.edited_at,
                            grouped_id = EXCLUDED.grouped_id,
                            reply_to_message_id = EXCLUDED.reply_to_message_id,
                            message_text = EXCLUDED.message_text,
                            media_type = EXCLUDED.media_type,
                            raw_payload = EXCLUDED.raw_payload,
                            payload_hash = EXCLUDED.payload_hash,
                            collected_at = EXCLUDED.collected_at,
                            deleted_at = NULL,
                            updated_at = clock_timestamp()
                        WHERE market.telegram_messages.payload_hash <> EXCLUDED.payload_hash
                        RETURNING 1
                        """
                    ),
                    parameters,
                )
            ).scalar_one_or_none()
            if changed_row is not None:
                await connection.execute(
                    text(
                        """
                        INSERT INTO market.telegram_message_revisions (
                            channel_id, message_id, payload_hash, posted_at,
                            edited_at, message_text, raw_payload, collected_at
                        ) VALUES (
                            :channel_id, :message_id, :payload_hash, :posted_at,
                            :edited_at, :message_text, CAST(:raw_payload AS jsonb),
                            :collected_at
                        )
                        ON CONFLICT DO NOTHING
                        """
                    ),
                    parameters,
                )
            await connection.execute(
                text(
                    """
                    INSERT INTO market.telegram_signals (
                        channel_id, message_id, parser_version, symbol_raw,
                        symbol, signal_kind, direction, score, action_text,
                        metrics, is_actionable, parsed_at
                    ) VALUES (
                        :channel_id, :message_id, :parser_version, :symbol_raw,
                        :symbol, :signal_kind, :direction, :score, :action_text,
                        CAST(:metrics AS jsonb), :is_actionable, :parsed_at
                    )
                    ON CONFLICT (channel_id, message_id, parser_version) DO UPDATE
                    SET symbol_raw = EXCLUDED.symbol_raw,
                        symbol = EXCLUDED.symbol,
                        signal_kind = EXCLUDED.signal_kind,
                        direction = EXCLUDED.direction,
                        score = EXCLUDED.score,
                        action_text = EXCLUDED.action_text,
                        metrics = EXCLUDED.metrics,
                        is_actionable = EXCLUDED.is_actionable,
                        parsed_at = EXCLUDED.parsed_at
                    """
                ),
                {
                    "channel_id": record.channel_id,
                    "message_id": record.message_id,
                    "parser_version": signal.parser_version,
                    "symbol_raw": signal.symbol_raw,
                    "symbol": signal.symbol,
                    "signal_kind": signal.signal_kind.value,
                    "direction": signal.direction.value,
                    "score": signal.score,
                    "action_text": signal.action_text,
                    "metrics": signal_metrics_json,
                    "is_actionable": signal.is_actionable,
                    "parsed_at": record.collected_at,
                },
            )
        return changed_row is not None

    async def mark_history_complete(self, channel_id: int) -> None:
        async with self.engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.telegram_channels channel
                    SET history_complete = true,
                        earliest_message_id = source.earliest_message_id,
                        latest_message_id = source.latest_message_id,
                        last_history_at = clock_timestamp()
                    FROM (
                        SELECT min(message_id) AS earliest_message_id,
                               max(message_id) AS latest_message_id
                        FROM market.telegram_messages
                        WHERE channel_id = :channel_id
                    ) source
                    WHERE channel.channel_id = :channel_id
                    """
                ),
                {"channel_id": channel_id},
            )

    async def mark_realtime(self, channel_id: int, message_id: int) -> None:
        async with self.engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE market.telegram_channels
                    SET latest_message_id = greatest(
                            coalesce(latest_message_id, :message_id), :message_id
                        ),
                        last_realtime_at = clock_timestamp()
                    WHERE channel_id = :channel_id
                    """
                ),
                {"channel_id": channel_id, "message_id": message_id},
            )
