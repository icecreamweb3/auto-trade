from __future__ import annotations

import nats

from auto_trade.config import Settings
from auto_trade.infrastructure.nats_streams import STREAMS
from auto_trade.monitoring.models import (
    HealthStatus,
    NatsMetric,
    NatsStreamMetric,
)


class NatsProbe:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    async def snapshot(self) -> NatsMetric:
        connection = None
        try:
            connection = await nats.connect(
                servers=[self._settings.nats_url],
                name=f"monitor-{self._settings.node_id}",
                connect_timeout=2,
                allow_reconnect=False,
                max_reconnect_attempts=0,
            )
            jetstream = connection.jetstream()
            streams: list[NatsStreamMetric] = []
            for definition in STREAMS:
                info = await jetstream.stream_info(definition.name)
                streams.append(
                    NatsStreamMetric(
                        name=definition.name,
                        messages=info.state.messages,
                        bytes=info.state.bytes,
                        consumers=info.state.consumer_count,
                    )
                )
            return NatsMetric(
                status=HealthStatus.HEALTHY,
                connected=True,
                streams=tuple(streams),
                message="JetStream连接正常",
            )
        except Exception as error:
            return NatsMetric(
                status=HealthStatus.CRITICAL,
                connected=False,
                message=f"JetStream不可用: {type(error).__name__}",
            )
        finally:
            if connection is not None:
                await connection.close()
