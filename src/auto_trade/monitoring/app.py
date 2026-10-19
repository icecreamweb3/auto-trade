from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import date

from fastapi import FastAPI, HTTPException, Query, Request
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.config import get_settings
from auto_trade.infrastructure.database import check_database, create_database_engine
from auto_trade.logging_config import configure_logging
from auto_trade.monitoring.models import (
    DailyKlineResult,
    DailyRankingEntry,
    DailyRankingResult,
    KlinePoint,
    MonitoringSnapshot,
)
from auto_trade.monitoring.nats_probe import NatsProbe
from auto_trade.monitoring.repository import MonitoringRepository
from auto_trade.monitoring.service import MonitoringService


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    configure_logging(settings, "monitor-api")
    engine = create_database_engine(settings)
    app.state.database_engine = engine
    app.state.monitoring_service = MonitoringService(
        MonitoringRepository(
            engine,
            data_safety_delay_seconds=(
                settings.monitoring_data_safety_delay_seconds
            ),
        ),
        settings,
        NatsProbe(settings),
    )
    yield
    await engine.dispose()


app = FastAPI(
    title="Auto Trade Collection Monitor",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/health/live")
async def live() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/ready")
async def ready(request: Request) -> dict[str, object]:
    engine: AsyncEngine = request.app.state.database_engine
    try:
        versions = await check_database(engine)
    except Exception as error:
        raise HTTPException(status_code=503, detail="database unavailable") from error
    return {"status": "ready", "database": versions}


@app.get("/api/monitoring/overview", response_model=MonitoringSnapshot)
async def overview(request: Request) -> MonitoringSnapshot:
    service: MonitoringService = request.app.state.monitoring_service
    try:
        return await service.snapshot()
    except Exception as error:
        raise HTTPException(status_code=503, detail="monitoring data unavailable") from error


@app.get("/api/rankings/daily", response_model=DailyRankingResult)
async def daily_rankings(
    request: Request,
    date_from: date | None = None,
    date_to: date | None = None,
    symbol: str | None = Query(default=None, max_length=32),
    rank_from: int = Query(default=1, ge=1, le=50),
    rank_to: int = Query(default=50, ge=1, le=50),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=100, ge=1, le=500),
) -> DailyRankingResult:
    if date_from is not None and date_to is not None and date_from > date_to:
        raise HTTPException(status_code=422, detail="date_from must not exceed date_to")
    if rank_from > rank_to:
        raise HTTPException(status_code=422, detail="rank_from must not exceed rank_to")
    repository = MonitoringRepository(request.app.state.database_engine)
    try:
        result = await repository.daily_rankings(
            date_from=date_from,
            date_to=date_to,
            symbol=symbol,
            rank_from=rank_from,
            rank_to=rank_to,
            page=page,
            page_size=page_size,
        )
    except Exception as error:
        raise HTTPException(status_code=503, detail="ranking data unavailable") from error
    return DailyRankingResult(
        available_first_date=result.available_first_date,
        available_last_date=result.available_last_date,
        date_from=result.date_from,
        date_to=result.date_to,
        symbol=symbol.strip().upper() if symbol and symbol.strip() else None,
        rank_from=rank_from,
        rank_to=rank_to,
        page=page,
        page_size=page_size,
        total=result.total,
        matching_days=result.matching_days,
        average_change=result.average_change,
        maximum_change=result.maximum_change,
        minimum_change=result.minimum_change,
        items=tuple(DailyRankingEntry.model_validate(item) for item in result.items),
    )


@app.get("/api/market/klines/day", response_model=DailyKlineResult)
async def daily_klines(
    request: Request,
    utc_trade_date: date,
    symbol: str = Query(min_length=1, max_length=32),
    interval_seconds: int = Query(default=300),
) -> DailyKlineResult:
    if interval_seconds not in (300, 900):
        raise HTTPException(status_code=422, detail="interval_seconds must be 300 or 900")
    normalized_symbol = symbol.strip().upper()
    if not normalized_symbol:
        raise HTTPException(status_code=422, detail="symbol must not be blank")
    repository = MonitoringRepository(request.app.state.database_engine)
    try:
        rows = await repository.daily_klines(
            symbol=normalized_symbol,
            utc_trade_date=utc_trade_date,
            interval_seconds=interval_seconds,
        )
    except Exception as error:
        raise HTTPException(status_code=503, detail="kline data unavailable") from error
    if not rows:
        raise HTTPException(status_code=404, detail="no kline data for symbol and date")
    return DailyKlineResult(
        symbol=normalized_symbol,
        utc_trade_date=utc_trade_date,
        interval_seconds=interval_seconds,
        items=tuple(KlinePoint.model_validate(row) for row in rows),
    )
