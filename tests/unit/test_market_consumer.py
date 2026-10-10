from __future__ import annotations

from typing import cast

from nats.aio.client import Client as NATS
from nats.js import JetStreamContext

from auto_trade.writers.market_consumer import ConsumerDefinition, MarketEventConsumer
from auto_trade.writers.market_repository import MarketRepository


class TimeoutSubscription:
    async def fetch(self, _batch_size: int, **kwargs: float) -> list[object]:
        assert kwargs["timeout"] == 0.01
        raise TimeoutError


class TimeoutJetStream:
    async def pull_subscribe(self, *_args: object, **_kwargs: object) -> TimeoutSubscription:
        return TimeoutSubscription()


async def test_drain_treats_asyncio_timeout_as_idle() -> None:
    consumer = MarketEventConsumer(
        connection=cast(NATS, object()),
        jetstream=cast(JetStreamContext, TimeoutJetStream()),
        repository=cast(MarketRepository, object()),
    )
    result = await consumer.drain(
        ConsumerDefinition("NORMALIZED_MARKET", "market.normalized.>", "test", False),
        idle_timeout=0.01,
    )
    assert result == {"stream": "NORMALIZED_MARKET", "processed": 0, "failed": 0}
