from collections.abc import AsyncIterator

from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from auto_trade.config import Settings


def create_database_engine(
    settings: Settings, *, minimum_pool_size: int = 1
) -> AsyncEngine:
    if minimum_pool_size < 1:
        raise ValueError("minimum_pool_size must be positive")
    return create_async_engine(
        settings.database_dsn,
        pool_pre_ping=True,
        pool_size=max(settings.postgres_pool_size, minimum_pool_size),
        max_overflow=settings.postgres_max_overflow,
        connect_args={
            "server_settings": {
                "timezone": "UTC",
                "application_name": settings.database_application_name,
            }
        },
    )


def create_session_factory(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False)


async def check_database(engine: AsyncEngine) -> dict[str, str]:
    async with engine.connect() as connection:
        row = (
            await connection.execute(
                text(
                    """
                    SELECT current_setting('server_version') AS postgres_version,
                           extversion AS timescaledb_version
                    FROM pg_extension
                    WHERE extname = 'timescaledb'
                    """
                )
            )
        ).one()
    return {"postgres": row.postgres_version, "timescaledb": row.timescaledb_version}


async def session_scope(
    factory: async_sessionmaker[AsyncSession],
) -> AsyncIterator[AsyncSession]:
    async with factory() as session:
        yield session
