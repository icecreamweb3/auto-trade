from __future__ import annotations

import asyncio
import json
import logging
from datetime import UTC, datetime
from typing import Any
from uuid import NAMESPACE_URL, uuid5

from nats.js import JetStreamContext
from telethon import TelegramClient, events  # type: ignore[import-untyped]
from telethon.tl.custom.message import Message  # type: ignore[import-untyped]

from auto_trade.collectors.telegram_client import build_telegram_client
from auto_trade.collectors.telegram_repository import (
    TelegramMessageRecord,
    TelegramMessageRepository,
)
from auto_trade.collectors.telegram_signals import (
    ParsedTelegramSignal,
    parse_telegram_message,
    telegram_display_text,
)
from auto_trade.config import Settings, get_settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.infrastructure.nats_streams import connect, ensure_streams
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)


def _message_record(
    channel_id: int,
    channel_username: str,
    message: Message,
    collected_at: datetime,
) -> TelegramMessageRecord:
    reply_to_message_id = getattr(message, "reply_to_msg_id", None)
    media = getattr(message, "media", None)
    media_type = type(media).__name__ if media is not None else None
    raw_text = message.message or ""
    text_value = telegram_display_text(channel_username, raw_text)
    raw_payload: dict[str, object] = {
        "channel_id": channel_id,
        "message_id": message.id,
        "posted_at": message.date.astimezone(UTC).isoformat(),
        "edited_at": (
            message.edit_date.astimezone(UTC).isoformat()
            if message.edit_date is not None
            else None
        ),
        "grouped_id": message.grouped_id,
        "reply_to_message_id": reply_to_message_id,
        "message_text": raw_text,
        "media_type": media_type,
    }
    return TelegramMessageRecord(
        channel_id=channel_id,
        message_id=message.id,
        posted_at=message.date.astimezone(UTC),
        edited_at=(
            message.edit_date.astimezone(UTC)
            if message.edit_date is not None
            else None
        ),
        grouped_id=message.grouped_id,
        reply_to_message_id=reply_to_message_id,
        message_text=text_value,
        media_type=media_type,
        raw_payload=raw_payload,
        collected_at=collected_at,
    )


def _event_payload(
    record: TelegramMessageRecord,
    signal: ParsedTelegramSignal,
    delivery_mode: str,
    strategy_trigger_enabled: bool,
) -> dict[str, object]:
    return {
        "event_id": str(
            uuid5(
                NAMESPACE_URL,
                "auto-trade:telegram:"
                f"{record.channel_id}:{record.message_id}:{record.payload_hash}",
            )
        ),
        "event_type": "telegram_channel_signal",
        "schema_version": 1,
        "source": "TELEGRAM",
        "event_time": record.posted_at.isoformat(),
        "collected_at": record.collected_at.isoformat(),
        "delivery_mode": delivery_mode,
        "strategy_trigger_enabled": strategy_trigger_enabled,
        "payload": {
            "channel_id": record.channel_id,
            "message_id": record.message_id,
            "edited_at": record.edited_at.isoformat() if record.edited_at else None,
            "payload_hash": record.payload_hash,
            **signal.model_dump(mode="json"),
        },
    }


class TelegramChannelProcessor:
    def __init__(
        self,
        repository: TelegramMessageRepository,
        jetstream: JetStreamContext,
        settings: Settings,
        channel_id: int,
        channel_username: str,
    ) -> None:
        self.repository = repository
        self.jetstream = jetstream
        self.channel_id = channel_id
        self.channel_username = channel_username
        self.strategy_trigger_enabled = (
            settings.telegram_strategy_trigger_enabled
            and channel_username.lower().lstrip("@") == "wizzalert"
        )

    async def process(self, message: Message, delivery_mode: str) -> bool:
        collected_at = datetime.now(UTC)
        record = _message_record(
            self.channel_id,
            self.channel_username,
            message,
            collected_at,
        )
        signal = parse_telegram_message(
            self.channel_username,
            str(record.raw_payload["message_text"]),
        )
        changed = await self.repository.store(record, signal)
        if not changed:
            return False
        payload = _event_payload(
            record,
            signal,
            delivery_mode,
            self.strategy_trigger_enabled,
        )
        suffix = "realtime" if delivery_mode != "BACKFILL" else "history"
        await self.jetstream.publish(
            "decision.telegram."
            f"{self.channel_username.lower().lstrip('@')}.{suffix}",
            json.dumps(payload, ensure_ascii=False, sort_keys=True).encode(),
            headers={"Nats-Msg-Id": str(payload["event_id"])},
        )
        if delivery_mode != "BACKFILL":
            await self.repository.mark_realtime(self.channel_id, record.message_id)
        logger.info(
            "Telegram message stored channel_id=%d message_id=%d mode=%s "
            "kind=%s symbol=%s score=%s trigger_enabled=%s",
            self.channel_id,
            record.message_id,
            delivery_mode,
            signal.signal_kind.value,
            signal.symbol,
            signal.score,
            self.strategy_trigger_enabled,
        )
        return True


async def _backfill(
    client: TelegramClient,
    entity: Any,
    processor: TelegramChannelProcessor,
    repository: TelegramMessageRepository,
    settings: Settings,
    initial_start_at: datetime | None,
) -> int:
    latest_message_id = await repository.latest_message_id(processor.channel_id)
    processed = 0
    if latest_message_id is None:
        iterator = client.iter_messages(
            entity,
            reverse=True,
            offset_date=initial_start_at,
        )
        async for message in iterator:
            processed += int(await processor.process(message, "BACKFILL"))
        await repository.mark_history_complete(processor.channel_id)
        return processed

    if settings.telegram_recent_rescan_messages:
        async for message in client.iter_messages(
            entity,
            limit=settings.telegram_recent_rescan_messages,
        ):
            processed += int(await processor.process(message, "BACKFILL"))
    async for message in client.iter_messages(
        entity,
        min_id=latest_message_id,
        reverse=True,
    ):
        processed += int(await processor.process(message, "BACKFILL"))
    await repository.mark_history_complete(processor.channel_id)
    return processed


async def run(settings: Settings) -> None:
    engine = create_database_engine(settings)
    nats_connection = await connect(settings)
    client = build_telegram_client(settings)
    try:
        jetstream = nats_connection.jetstream()
        await ensure_streams(jetstream)
        await client.connect()
        if not await client.is_user_authorized():
            raise RuntimeError(
                "Telegram session is not authorized; run the telegram-auth service first"
            )
        repository = TelegramMessageRepository(engine)
        for configured_channel in settings.telegram_channel_names:
            entity = await client.get_entity(configured_channel)
            channel_id = int(entity.id)
            username = str(
                getattr(entity, "username", None) or configured_channel
            ).lstrip("@")
            title = str(getattr(entity, "title", None) or username)
            await repository.register_channel(channel_id, username, title)
            processor = TelegramChannelProcessor(
                repository,
                jetstream,
                settings,
                channel_id,
                username,
            )

            async def handle_new(
                event: events.NewMessage.Event,
                channel_processor: TelegramChannelProcessor = processor,
            ) -> None:
                await channel_processor.process(event.message, "REALTIME")

            async def handle_edit(
                event: events.MessageEdited.Event,
                channel_processor: TelegramChannelProcessor = processor,
            ) -> None:
                await channel_processor.process(event.message, "EDIT")

            client.add_event_handler(handle_new, events.NewMessage(chats=entity))
            client.add_event_handler(handle_edit, events.MessageEdited(chats=entity))
            initial_start_at = settings.telegram_backfill_start(username)
            backfilled = await _backfill(
                client,
                entity,
                processor,
                repository,
                settings,
                initial_start_at,
            )
            logger.info(
                "Telegram history synchronized channel=@%s "
                "start_at=%s changed_messages=%d",
                username,
                initial_start_at.isoformat() if initial_start_at else "all",
                backfilled,
            )
        await client.run_until_disconnected()
    finally:
        await client.disconnect()
        await nats_connection.drain()
        await engine.dispose()


def main() -> None:
    settings = get_settings()
    configure_logging(settings, "telegram-subscriber")
    asyncio.run(run(settings))


if __name__ == "__main__":
    main()
