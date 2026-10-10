from __future__ import annotations

import argparse
import asyncio
import json
from dataclasses import asdict

from auto_trade.collectors.binance_usdm import BinanceUsdMClient
from auto_trade.collectors.publisher import JetStreamEventPublisher
from auto_trade.collectors.service import BinanceCollectionService
from auto_trade.config import get_settings
from auto_trade.infrastructure.nats_streams import connect, ensure_streams


async def collect(symbols: set[str] | None) -> dict[str, object]:
    settings = get_settings()
    connection = await connect(settings)
    try:
        jetstream = connection.jetstream()
        await ensure_streams(jetstream)
        publisher = JetStreamEventPublisher(jetstream)
        async with BinanceUsdMClient(
            base_url=settings.binance_usdm_base_url,
            timeout_seconds=settings.binance_request_timeout_seconds,
            max_concurrency=settings.binance_max_concurrency,
            attempts=settings.binance_request_attempts,
        ) as client:
            service = BinanceCollectionService(
                client=client,
                publisher=publisher,
                node_id=settings.node_id,
                shard_id=settings.shard_id,
            )
            return asdict(await service.collect_once(symbols))
    finally:
        await connection.drain()


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect one Binance USD-M market-data cycle")
    parser.add_argument(
        "--symbols",
        nargs="*",
        help="Optional symbol subset for ticker and 5m kline collection; rules always sync fully.",
    )
    args = parser.parse_args()
    symbols = {symbol.upper() for symbol in args.symbols} if args.symbols else None
    print(json.dumps(asyncio.run(collect(symbols)), indent=2, default=str))


if __name__ == "__main__":
    main()
