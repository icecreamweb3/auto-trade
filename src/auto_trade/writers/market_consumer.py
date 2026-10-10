from __future__ import annotations

import argparse
import asyncio
import json
import logging
from dataclasses import dataclass

from nats.aio.client import Client as NATS
from nats.aio.msg import Msg
from nats.errors import TimeoutError as NatsTimeoutError
from nats.js import JetStreamContext
from nats.js.api import AckPolicy, ConsumerConfig, DeliverPolicy, ReplayPolicy

from auto_trade.config import Settings, get_settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.infrastructure.nats_streams import connect, ensure_streams
from auto_trade.writers.market_repository import IncomingEvent, MarketRepository


@dataclass(frozen=True, slots=True)
class ConsumerDefinition:
    stream: str
    subject: str
    durable: str
    raw: bool


CONSUMERS = (
    ConsumerDefinition("RAW_MARKET", "raw.market.>", "market-db-raw-v1", True),
    ConsumerDefinition(
        "NORMALIZED_MARKET",
        "market.normalized.>",
        "market-db-normalized-v1",
        False,
    ),
)

logger = logging.getLogger(__name__)


class MarketEventConsumer:
    def __init__(
        self,
        *,
        connection: NATS,
        jetstream: JetStreamContext,
        repository: MarketRepository,
    ) -> None:
        self._connection = connection
        self._jetstream = jetstream
        self._repository = repository

    async def _subscription(
        self, definition: ConsumerDefinition
    ) -> JetStreamContext.PullSubscription:
        config = ConsumerConfig(
            durable_name=definition.durable,
            deliver_policy=DeliverPolicy.ALL,
            ack_policy=AckPolicy.EXPLICIT,
            ack_wait=30.0,
            max_deliver=5,
            max_ack_pending=500,
            replay_policy=ReplayPolicy.INSTANT,
            filter_subject=definition.subject,
        )
        return await self._jetstream.pull_subscribe(
            definition.subject,
            durable=definition.durable,
            stream=definition.stream,
            config=config,
        )

    async def _write(self, definition: ConsumerDefinition, message: Msg) -> None:
        event = IncomingEvent.model_validate_json(message.data)
        if definition.raw:
            await self._repository.write_raw(event)
        else:
            await self._repository.write_normalized(event)

    async def _dead_letter(
        self,
        definition: ConsumerDefinition,
        message: Msg,
        error: Exception,
    ) -> None:
        metadata = message.metadata
        event_id = "unknown"
        try:
            event_id = str(IncomingEvent.model_validate_json(message.data).event_id)
        except Exception:
            pass
        body = json.dumps(
            {
                "source_stream": definition.stream,
                "source_subject": message.subject,
                "durable": definition.durable,
                "event_id": event_id,
                "deliveries": metadata.num_delivered if metadata else None,
                "error_type": type(error).__name__,
                "error": str(error)[:1000],
                "original_payload": message.data.decode(errors="replace"),
            },
            separators=(",", ":"),
        ).encode()
        await self._jetstream.publish(
            f"dlq.market_db.{definition.stream.lower()}",
            body,
            headers={"Nats-Msg-Id": f"market-db:{definition.stream}:{event_id}"},
        )

    async def _process_message(self, definition: ConsumerDefinition, message: Msg) -> bool:
        try:
            await self._write(definition, message)
        except Exception as error:
            logger.exception(
                "market event persistence failed stream=%s subject=%s",
                definition.stream,
                message.subject,
            )
            metadata = message.metadata
            deliveries = metadata.num_delivered if metadata else 1
            if deliveries >= 5:
                await self._dead_letter(definition, message, error)
                await message.term()
            else:
                await message.nak(delay=5)
            return False
        await message.ack_sync(timeout=5)
        return True

    async def drain(
        self,
        definition: ConsumerDefinition,
        *,
        batch_size: int = 100,
        idle_timeout: float = 2.0,
    ) -> dict[str, int | str]:
        subscription = await self._subscription(definition)
        processed = 0
        failed = 0
        while True:
            try:
                messages = await subscription.fetch(batch_size, timeout=idle_timeout)
            except (TimeoutError, NatsTimeoutError):
                break
            for message in messages:
                if await self._process_message(definition, message):
                    processed += 1
                else:
                    failed += 1
                    return {
                        "stream": definition.stream,
                        "processed": processed,
                        "failed": failed,
                    }
        return {"stream": definition.stream, "processed": processed, "failed": failed}

    async def run_forever(
        self,
        definition: ConsumerDefinition,
        *,
        batch_size: int = 100,
    ) -> None:
        subscription = await self._subscription(definition)
        while not self._connection.is_closed:
            try:
                messages = await subscription.fetch(batch_size, timeout=5)
            except (TimeoutError, NatsTimeoutError):
                continue
            for message in messages:
                await self._process_message(definition, message)


async def run(command: str, settings: Settings) -> object:
    engine = create_database_engine(settings)
    connection = await connect(settings)
    try:
        jetstream = connection.jetstream()
        await ensure_streams(jetstream)
        consumer = MarketEventConsumer(
            connection=connection,
            jetstream=jetstream,
            repository=MarketRepository(engine),
        )
        if command == "drain":
            results = []
            for definition in CONSUMERS:
                results.append(await consumer.drain(definition))
            return results
        if command == "run":
            await asyncio.gather(
                *(consumer.run_forever(definition) for definition in CONSUMERS)
            )
            return {"stopped": True}
        raise ValueError(f"unsupported command: {command}")
    finally:
        await connection.close()
        await engine.dispose()


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(description="Persist market events from JetStream")
    parser.add_argument("command", choices=("drain", "run"))
    args = parser.parse_args()
    result = asyncio.run(run(args.command, get_settings()))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
