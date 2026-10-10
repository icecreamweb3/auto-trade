from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.config import get_settings
from auto_trade.infrastructure.database import check_database, create_database_engine
from auto_trade.monitoring.models import MonitoringSnapshot
from auto_trade.monitoring.nats_probe import NatsProbe
from auto_trade.monitoring.repository import MonitoringRepository
from auto_trade.monitoring.service import MonitoringService


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    engine = create_database_engine(settings)
    app.state.database_engine = engine
    app.state.monitoring_service = MonitoringService(
        MonitoringRepository(engine),
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
