from __future__ import annotations

import argparse
import asyncio
import json
from dataclasses import dataclass
from datetime import timedelta
from uuid import uuid4

import nats
from nats.aio.client import Client as NATS
from nats.js import JetStreamContext
from nats.js.api import DiscardPolicy, RetentionPolicy, StorageType, StreamConfig
from nats.js.errors import NotFoundError

from auto_trade.config import Settings, get_settings

GIB = 1024**3


@dataclass(frozen=True, slots=True)
class StreamDefinition:
    name: str
    subjects: tuple[str, ...]
    max_age: timedelta
    max_bytes: int
    description: str

    def config(self) -> StreamConfig:
        return StreamConfig(
            name=self.name,
            subjects=list(self.subjects),
            description=self.description,
            retention=RetentionPolicy.LIMITS,
            storage=StorageType.FILE,
            discard=DiscardPolicy.OLD,
            max_age=self.max_age.total_seconds(),
            max_bytes=self.max_bytes,
            num_replicas=1,
            allow_direct=True,
        )


STREAMS = (
    StreamDefinition(
        "RAW_MARKET",
        ("raw.market.>",),
        timedelta(hours=72),
        10 * GIB,
        "Raw immutable exchange observations; short replay buffer.",
    ),
    StreamDefinition(
        "NORMALIZED_MARKET",
        ("market.normalized.>",),
        timedelta(days=7),
        40 * GIB,
        "Validated canonical market events consumed by writers and strategies.",
    ),
    StreamDefinition(
        "DECISIONS",
        ("decision.>",),
        timedelta(days=30),
        6 * GIB,
        "Signal, risk and decision snapshots.",
    ),
    StreamDefinition(
        "TRADE_EVENTS",
        ("trade.>",),
        timedelta(days=30),
        4 * GIB,
        "Order and position lifecycle events.",
    ),
    StreamDefinition(
        "DLQ",
        ("dlq.>",),
        timedelta(days=30),
        2 * GIB,
        "Events rejected after bounded retries.",
    ),
)


async def connect(settings: Settings) -> NATS:
    return await nats.connect(
        servers=[settings.nats_url],
        name=f"{settings.service_name}-{settings.node_id}",
        connect_timeout=5,
        max_reconnect_attempts=-1,
        reconnect_time_wait=2,
    )


async def ensure_streams(js: JetStreamContext) -> None:
    for definition in STREAMS:
        config = definition.config()
        try:
            await js.stream_info(definition.name)
        except NotFoundError:
            await js.add_stream(config=config)
        else:
            await js.update_stream(config=config)


async def verify_streams(js: JetStreamContext) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for definition in STREAMS:
        info = await js.stream_info(definition.name)
        actual_subjects = tuple(info.config.subjects or [])
        if actual_subjects != definition.subjects:
            raise RuntimeError(
                f"{definition.name} subjects {actual_subjects!r} != {definition.subjects!r}"
            )
        expected_max_age = definition.max_age.total_seconds()
        if info.config.max_age != expected_max_age:
            raise RuntimeError(
                f"{definition.name} max_age {info.config.max_age!r} != {expected_max_age!r}"
            )
        if info.config.max_bytes != definition.max_bytes:
            raise RuntimeError(
                f"{definition.name} max_bytes {info.config.max_bytes!r} "
                f"!= {definition.max_bytes!r}"
            )
        results.append(
            {
                "name": definition.name,
                "subjects": actual_subjects,
                "max_age_seconds": int(definition.max_age.total_seconds()),
                "max_bytes": definition.max_bytes,
                "messages": info.state.messages,
            }
        )
    return results


async def smoke(js: JetStreamContext) -> dict[str, object]:
    event_id = str(uuid4())
    payload = json.dumps({"event_id": event_id, "kind": "nats-smoke"}).encode()
    ack = await js.publish(
        "dlq.system.smoke",
        payload,
        headers={"Nats-Msg-Id": event_id},
    )
    stored = await js.get_msg("DLQ", seq=ack.seq)
    if stored.data != payload:
        raise RuntimeError("JetStream smoke payload did not round-trip")
    await js.delete_msg("DLQ", ack.seq)
    return {"stream": ack.stream, "sequence": ack.seq, "round_trip": True}


async def run(command: str, settings: Settings) -> object:
    connection = await connect(settings)
    try:
        jetstream = connection.jetstream()
        if command == "init":
            await ensure_streams(jetstream)
            return await verify_streams(jetstream)
        if command == "verify":
            return await verify_streams(jetstream)
        if command == "smoke":
            return await smoke(jetstream)
        raise ValueError(f"unsupported command: {command}")
    finally:
        await connection.drain()


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage local Auto Trade JetStream streams")
    parser.add_argument("command", choices=("init", "verify", "smoke"))
    args = parser.parse_args()
    result = asyncio.run(run(args.command, get_settings()))
    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    main()
