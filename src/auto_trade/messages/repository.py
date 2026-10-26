from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.messages.models import (
    ChannelMessage,
    ChannelMessagePage,
    MessageChannelSummary,
)


@dataclass(frozen=True, slots=True)
class MessagePageRows:
    channel: MessageChannelSummary
    total: int
    items: tuple[ChannelMessage, ...]


def message_title(message_text: str, message_id: int) -> str:
    first_line = next(
        (line.strip() for line in message_text.splitlines() if line.strip()),
        "",
    )
    return first_line or f"消息 #{message_id}"


class MessageRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def channels(self) -> tuple[MessageChannelSummary, ...]:
        async with self._engine.connect() as connection:
            rows = (
                await connection.execute(
                    text(
                        """
                        SELECT c.channel_id, c.username, c.title,
                               c.history_complete, c.last_realtime_at,
                               count(m.message_id) AS message_count,
                               min(m.posted_at) AS earliest_message_at,
                               max(m.posted_at) AS latest_message_at
                        FROM market.telegram_channels c
                        LEFT JOIN market.telegram_messages m
                          ON m.channel_id = c.channel_id
                         AND m.deleted_at IS NULL
                        GROUP BY c.channel_id, c.username, c.title,
                                 c.history_complete, c.last_realtime_at
                        ORDER BY max(m.posted_at) DESC NULLS LAST, c.title
                        """
                    )
                )
            ).mappings().all()
        return tuple(MessageChannelSummary.model_validate(row) for row in rows)

    async def messages(
        self,
        *,
        channel_id: int,
        page: int,
        page_size: int,
        signal_kind: str | None = None,
    ) -> ChannelMessagePage | None:
        async with self._engine.connect() as connection:
            channel_row = (
                await connection.execute(
                    text(
                        """
                        SELECT c.channel_id, c.username, c.title,
                               c.history_complete, c.last_realtime_at,
                               count(m.message_id) AS message_count,
                               min(m.posted_at) AS earliest_message_at,
                               max(m.posted_at) AS latest_message_at
                        FROM market.telegram_channels c
                        LEFT JOIN market.telegram_messages m
                          ON m.channel_id = c.channel_id
                         AND m.deleted_at IS NULL
                        WHERE c.channel_id = :channel_id
                        GROUP BY c.channel_id, c.username, c.title,
                                 c.history_complete, c.last_realtime_at
                        """
                    ),
                    {"channel_id": channel_id},
                )
            ).mappings().one_or_none()
            if channel_row is None:
                return None
            channel = MessageChannelSummary.model_validate(channel_row)
            total = channel.message_count
            if signal_kind is not None:
                total = cast(
                    int,
                    (
                        await connection.execute(
                            text(
                                """
                                SELECT count(*)
                                FROM market.telegram_messages m
                                JOIN LATERAL (
                                    SELECT s.signal_kind
                                    FROM market.telegram_signals s
                                    WHERE s.channel_id = m.channel_id
                                      AND s.message_id = m.message_id
                                    ORDER BY s.parsed_at DESC,
                                             s.parser_version DESC
                                    LIMIT 1
                                ) signal ON true
                                WHERE m.channel_id = :channel_id
                                  AND m.deleted_at IS NULL
                                  AND signal.signal_kind = :signal_kind
                                """
                            ),
                            {
                                "channel_id": channel_id,
                                "signal_kind": signal_kind,
                            },
                        )
                    ).scalar_one(),
                )
            rows = (
                await connection.execute(
                    text(
                        """
                        SELECT m.channel_id, m.message_id, m.posted_at,
                               m.edited_at, m.message_text, m.media_type,
                               signal.symbol, signal.signal_kind,
                               signal.direction, signal.score,
                               signal.change_24h_percent,
                               coalesce(signal.is_actionable, false)
                                   AS is_actionable
                        FROM market.telegram_messages m
                        LEFT JOIN LATERAL (
                            SELECT s.symbol, s.signal_kind, s.direction,
                                   s.score, s.is_actionable,
                                   CAST(
                                       s.metrics->>'change_24h_percent'
                                       AS double precision
                                   ) AS change_24h_percent
                            FROM market.telegram_signals s
                            WHERE s.channel_id = m.channel_id
                              AND s.message_id = m.message_id
                            ORDER BY s.parsed_at DESC, s.parser_version DESC
                            LIMIT 1
                        ) signal ON true
                        WHERE m.channel_id = :channel_id
                          AND m.deleted_at IS NULL
                          AND (
                              CAST(:signal_kind AS text) IS NULL
                              OR signal.signal_kind = CAST(:signal_kind AS text)
                          )
                        ORDER BY m.posted_at DESC, m.message_id DESC
                        LIMIT :limit OFFSET :offset
                        """
                    ),
                    {
                        "channel_id": channel_id,
                        "signal_kind": signal_kind,
                        "limit": page_size,
                        "offset": (page - 1) * page_size,
                    },
                )
            ).mappings().all()
        items = tuple(
            ChannelMessage(
                channel_id=cast(int, row["channel_id"]),
                message_id=cast(int, row["message_id"]),
                title=message_title(
                    cast(str, row["message_text"]),
                    cast(int, row["message_id"]),
                ),
                posted_at=cast(datetime, row["posted_at"]),
                edited_at=cast(datetime | None, row["edited_at"]),
                message_text=cast(str, row["message_text"]),
                media_type=cast(str | None, row["media_type"]),
                symbol=cast(str | None, row["symbol"]),
                signal_kind=cast(str | None, row["signal_kind"]),
                direction=cast(str | None, row["direction"]),
                score=cast(int | None, row["score"]),
                change_24h_percent=cast(
                    float | None,
                    row["change_24h_percent"],
                ),
                is_actionable=cast(bool, row["is_actionable"]),
            )
            for row in rows
        )
        return ChannelMessagePage(
            channel=channel,
            page=page,
            page_size=page_size,
            total=total,
            signal_kind=signal_kind,
            items=items,
        )
