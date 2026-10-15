from __future__ import annotations

import asyncio
import logging
from collections.abc import Sequence
from datetime import UTC, date, datetime, timedelta
from typing import cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.collectors.historical_rankings import (
    build_rankings,
    materialize_local_daily_metrics,
)
from auto_trade.config import Settings, get_settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.logging_config import configure_logging

logger = logging.getLogger(__name__)


def latest_completed_utc_day(now: datetime) -> date:
    return now.astimezone(UTC).date() - timedelta(days=1)


async def pending_days(
    engine: AsyncEngine,
    *,
    last_day: date,
    lookback_days: int,
    limit: int,
) -> tuple[date, ...]:
    first_day = last_day - timedelta(days=lookback_days - 1)
    async with engine.connect() as connection:
        result = await connection.execute(
            text(
                """
                    SELECT candidate.day::date AS day
                    FROM generate_series(
                        CAST(:first_day AS date),
                        CAST(:last_day AS date),
                        INTERVAL '1 day'
                    ) AS candidate(day)
                    LEFT JOIN market.ranking_snapshots snapshot
                      ON snapshot.ranking_type = 'UTC_DAILY_2355'
                     AND snapshot.utc_trade_date = candidate.day::date
                     AND snapshot.quality_status = 'VALID'
                    WHERE snapshot.ranking_snapshot_id IS NULL
                    ORDER BY candidate.day DESC
                    LIMIT :limit
                """
            ),
            {"first_day": first_day, "last_day": last_day, "limit": limit},
        )
        rows = cast(Sequence[date], result.scalars().all())
    return tuple(reversed(rows))


async def update_pending_daily_rankings(
    engine: AsyncEngine,
    settings: Settings,
    *,
    now: datetime | None = None,
) -> tuple[date, ...]:
    current = now or datetime.now(UTC)
    days = await pending_days(
        engine,
        last_day=latest_completed_utc_day(current),
        lookback_days=settings.daily_ranking_lookback_days,
        limit=settings.daily_ranking_max_days_per_cycle,
    )
    for day in days:
        total, valid = await materialize_local_daily_metrics(engine, day)
        await build_rankings(engine, day, day)
        logger.info(
            "UTC daily ranking updated day=%s eligible_instruments=%d "
            "complete_instruments=%d",
            day,
            total,
            valid,
        )
    return days


async def run_forever(settings: Settings) -> None:
    engine = create_database_engine(settings)
    try:
        while True:
            try:
                days = await update_pending_daily_rankings(engine, settings)
                if not days:
                    logger.info("UTC daily rankings are up to date")
            except Exception:
                logger.exception("UTC daily ranking update cycle failed")
            await asyncio.sleep(settings.daily_ranking_scan_interval_seconds)
    finally:
        await engine.dispose()


def main() -> None:
    settings = get_settings()
    configure_logging(settings, "daily-rankings")
    asyncio.run(run_forever(settings))


if __name__ == "__main__":
    main()
