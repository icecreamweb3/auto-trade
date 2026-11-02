"""Fail-closed database task service entrypoint.

This process owns only the database task lease boundary. Domain handlers are
registered separately; until a handler is registered the service refuses to
claim work, so deploying the process cannot silently mark training as done.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
from dataclasses import dataclass

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.config import Settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.training.orchestrator import ExecutorKind

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class ServiceRole:
    name: str
    executor_kind: ExecutorKind | None
    schema: str


SERVICE_ROLES: dict[str, ServiceRole] = {
    "orchestrator": ServiceRole("orchestrator", None, "strategy_training"),
    "worker": ServiceRole("worker", ExecutorKind.WORKER, "strategy_training"),
    "optimizer": ServiceRole("optimizer", ExecutorKind.OPTIMIZER, "strategy_training"),
    "evaluator": ServiceRole("evaluator", ExecutorKind.EVALUATOR, "strategy_training"),
    "model-b": ServiceRole("model-b", ExecutorKind.MODEL_B, "strategy_training"),
    "weak-holdout": ServiceRole(
        "weak-holdout", None, "strategy_training_weak_holdout"
    ),
    "test-executor": ServiceRole("test-executor", None, "strategy_training_test"),
    "test-auditor": ServiceRole("test-auditor", None, "strategy_training_test"),
}


async def verify_identity(engine: AsyncEngine, role: ServiceRole, expected_user: str) -> None:
    async with engine.connect() as connection:
        row = (
            await connection.execute(
                text(
                    """
                    SELECT current_user AS db_user,
                           current_setting('application_name') AS application_name,
                           has_schema_privilege(current_user, :schema, 'USAGE') AS has_usage
                    """
                ),
                {"schema": role.schema},
            )
        ).mappings().one()
    if row["db_user"] != expected_user:
        raise RuntimeError(f"database identity mismatch: {row['db_user']} != {expected_user}")
    if not row["application_name"]:
        raise RuntimeError("database application_name must not be blank")
    if not row["has_usage"]:
        raise RuntimeError(f"database role has no USAGE on {role.schema}")


async def run_service(role: ServiceRole, *, expected_user: str, once: bool) -> None:
    settings = Settings()
    engine = create_database_engine(settings)
    try:
        await verify_identity(engine, role, expected_user)
        LOGGER.info("training service identity verified role=%s", role.name)
        if role.executor_kind is None:
            return
        if not once:
            # Task handlers are deliberately not implicit. A later slice will
            # register DATASET_BUILD/OPTIMIZER_TRIAL/etc. handlers here.
            raise RuntimeError(
                "task execution is not enabled until a domain handler registry is installed"
            )
    finally:
        await engine.dispose()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Training service identity/lease entrypoint")
    parser.add_argument("--role", choices=tuple(SERVICE_ROLES), required=True)
    parser.add_argument("--expected-user", required=True)
    parser.add_argument("--once", action="store_true", help="verify identity and exit")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.INFO)
    asyncio.run(
        run_service(
            SERVICE_ROLES[args.role], expected_user=args.expected_user, once=args.once
        )
    )


if __name__ == "__main__":
    main()
