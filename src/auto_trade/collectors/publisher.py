from __future__ import annotations

from typing import Protocol

from nats.js import JetStreamContext
from pydantic import BaseModel

from auto_trade.contracts import EventEnvelope


class EventPublisher(Protocol):
    async def publish(self, subject: str, event: EventEnvelope[BaseModel]) -> None: ...


class JetStreamEventPublisher:
    def __init__(self, jetstream: JetStreamContext) -> None:
        self._jetstream = jetstream

    async def publish(self, subject: str, event: EventEnvelope[BaseModel]) -> None:
        await self._jetstream.publish(
            subject,
            event.model_dump_json().encode(),
            headers={"Nats-Msg-Id": str(event.event_id)},
        )
