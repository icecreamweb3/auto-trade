"""Fail-closed database task service entrypoint.

This process owns only the database task lease boundary. Domain handlers are
registered separately; until a handler is registered the service refuses to
claim work, so deploying the process cannot silently mark training as done.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import socket
from dataclasses import dataclass

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.config import get_settings
from auto_trade.infrastructure.database import create_database_engine
from auto_trade.training.database_task_runtime import DatabaseTaskRuntimeBackend
from auto_trade.training.orchestrator import ExecutorKind
from auto_trade.training.task_runtime import TaskExecutor

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


async def run_service(
    role: ServiceRole,
    *,
    expected_user: str,
    identity_only: bool,
    execute_once: bool,
    worker_identity: str,
    lease_seconds: int,
    heartbeat_interval_seconds: float,
    poll_interval_seconds: float,
) -> None:
    if not worker_identity.strip():
        raise ValueError("worker_identity cannot be blank")
    if poll_interval_seconds <= 0:
        raise ValueError("poll_interval_seconds must be positive")
    settings = get_settings()
    engine = create_database_engine(settings)
    try:
        await verify_identity(engine, role, expected_user)
        LOGGER.info("training service identity verified role=%s", role.name)
        if identity_only or role.executor_kind is None:
            return
        if role.executor_kind not in {
            ExecutorKind.WORKER,
            ExecutorKind.OPTIMIZER,
            ExecutorKind.EVALUATOR,
            ExecutorKind.MODEL_B,
        }:
            raise RuntimeError(
                f"no executable handlers are registered for role={role.name}"
            )
        backend = DatabaseTaskRuntimeBackend(
            engine,
            executor_kind=role.executor_kind,
            worker_identity=worker_identity,
        )
        executor = TaskExecutor(
            backend,
            lease_seconds=lease_seconds,
            heartbeat_interval_seconds=heartbeat_interval_seconds,
        )
        if execute_once:
            claimed = await executor.run_once()
            LOGGER.info("training execute-once completed claimed=%s", claimed)
            return
        while True:
            claimed = await executor.run_once()
            if not claimed:
                await asyncio.sleep(poll_interval_seconds)
    finally:
        await engine.dispose()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Training service identity/lease entrypoint")
    parser.add_argument("--role", choices=tuple(SERVICE_ROLES), required=True)
    parser.add_argument("--expected-user", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="verify identity and exit")
    mode.add_argument(
        "--execute-once",
        action="store_true",
        help="claim and execute at most one supported task, then exit",
    )
    parser.add_argument(
        "--worker-identity",
        default=f"{socket.gethostname()}:{os.getpid()}",
    )
    parser.add_argument("--lease-seconds", type=int, default=300)
    parser.add_argument("--heartbeat-interval-seconds", type=float, default=60.0)
    parser.add_argument("--poll-interval-seconds", type=float, default=5.0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.INFO)
    asyncio.run(
        run_service(
            SERVICE_ROLES[args.role],
            expected_user=args.expected_user,
            identity_only=args.once,
            execute_once=args.execute_once,
            worker_identity=args.worker_identity,
            lease_seconds=args.lease_seconds,
            heartbeat_interval_seconds=args.heartbeat_interval_seconds,
            poll_interval_seconds=args.poll_interval_seconds,
        )
    )


if __name__ == "__main__":
    main()
