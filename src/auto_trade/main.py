from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.config import get_settings
from auto_trade.infrastructure.database import check_database, create_database_engine


@asynccontextmanager
async def lifespan(app: FastAPI) -> Any:
    settings = get_settings()
    engine = create_database_engine(settings)
    app.state.database_engine = engine
    yield
    await engine.dispose()


app = FastAPI(title="Auto Trade 2.0", version="0.1.0", lifespan=lifespan)


@app.get("/health/live")
async def live() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/ready")
async def ready() -> dict[str, object]:
    engine: AsyncEngine = app.state.database_engine
    versions = await check_database(engine)
    return {"status": "ready", "database": versions}

