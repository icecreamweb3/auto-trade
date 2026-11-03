from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from auto_trade.accounts.models import CurrentUser
from auto_trade.accounts.router import AuthenticatedUser


class WorkspaceExperiment(BaseModel):
    model_config = ConfigDict(frozen=True)

    experiment_id: str
    experiment_type: str
    status: str
    created_at: datetime


class WorkspaceFailure(BaseModel):
    model_config = ConfigDict(frozen=True)

    iteration_id: str
    status: str
    failure_code: str | None
    ended_at: datetime | None


class TrainingWorkspace(BaseModel):
    model_config = ConfigDict(frozen=True)

    generated_at: datetime
    mode: str
    counts: dict[str, int]
    experiments: tuple[WorkspaceExperiment, ...]
    failures: tuple[WorkspaceFailure, ...]
    test_metrics_available: bool


class OperationalOnlyStatus(BaseModel):
    model_config = ConfigDict(frozen=True)

    generated_at: datetime
    mode: str
    strategy_outputs_visible: bool
    allowed_metrics: tuple[str, ...]
    message: str


router = APIRouter(prefix="/api/training", tags=["training-workspace"])


async def require_training_researcher(
    request: Request, user: AuthenticatedUser
) -> CurrentUser:
    """Require an explicit active grant; ADMIN is deliberately not implicit."""
    engine = request.app.state.database_engine
    try:
        async with engine.connect() as connection:
            has_role = bool(
                (
                    await connection.execute(
                        text(
                            """
                            SELECT EXISTS (
                                SELECT 1
                                FROM core.app_user_training_roles role_grant
                                LEFT JOIN core.app_user_training_role_revocations revocation
                                  ON revocation.grant_id = role_grant.grant_id
                                WHERE role_grant.user_id = :user_id
                                  AND role_grant.training_role = 'TRAINING_RESEARCHER'
                                  AND role_grant.valid_from <= clock_timestamp()
                                  AND role_grant.expires_at > clock_timestamp()
                                  AND revocation.grant_id IS NULL
                            )
                            """
                        ),
                        {"user_id": user.user_id},
                    )
                ).scalar_one()
            )
    except SQLAlchemyError as error:
        raise HTTPException(
            status_code=503, detail="training authorization unavailable"
        ) from error
    if not has_role:
        raise HTTPException(status_code=403, detail="需要有效的 TRAINING_RESEARCHER 授权")
    return user


TrainingResearcher = Annotated[CurrentUser, Depends(require_training_researcher)]


async def _workspace_payload(request: Request) -> TrainingWorkspace:
    engine = request.app.state.database_engine
    try:
        async with engine.connect() as connection:
            experiments = (
                await connection.execute(
                    text(
                        """
                        SELECT experiment_id::text, experiment_mode AS experiment_type,
                               state AS status, created_at
                        FROM strategy_training.training_experiments
                        ORDER BY created_at DESC
                        LIMIT 100
                        """
                    )
                )
            ).mappings().all()
            failures = (
                await connection.execute(
                    text(
                        """
                        SELECT iteration_id::text, state AS status, failure_code, ended_at
                        FROM strategy_training.training_iterations
                        WHERE state IN ('FAILED', 'REJECTED', 'CANCELLED')
                        ORDER BY ended_at DESC NULLS LAST
                        LIMIT 100
                        """
                    )
                )
            ).mappings().all()
            count_rows = (
                await connection.execute(
                    text(
                        """
                        SELECT
                          (SELECT count(*)
                             FROM strategy_training.training_dataset_versions) AS datasets,
                          (SELECT count(*)
                             FROM strategy_training.training_experiments) AS experiments,
                          (SELECT count(*) FROM strategy_training.training_tasks
                             WHERE state IN ('QUEUED', 'LEASED', 'RUNNING', 'PAUSED'))
                             AS active_tasks,
                          (SELECT coalesce(sum(reserved_evaluation_count), 0)
                             FROM strategy_training.training_validation_scopes)
                             AS validation_reserved
                        """
                    )
                )
            ).mappings().one()
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="training workspace unavailable") from error

    return TrainingWorkspace(
        generated_at=datetime.now(UTC),
        mode="TRAINING_RESEARCH",
        counts={key: int(value) for key, value in count_rows.items()},
        experiments=tuple(WorkspaceExperiment.model_validate(row) for row in experiments),
        failures=tuple(WorkspaceFailure.model_validate(row) for row in failures),
        test_metrics_available=False,
    )


@router.get("/workspace", response_model=TrainingWorkspace)
async def workspace(
    request: Request, _researcher: TrainingResearcher
) -> TrainingWorkspace:
    return await _workspace_payload(request)


@router.get("/operational-only", response_model=OperationalOnlyStatus)
async def operational_only() -> OperationalOnlyStatus:
    return OperationalOnlyStatus(
        generated_at=datetime.now(UTC),
        mode="OPERATIONAL_ONLY",
        strategy_outputs_visible=False,
        allowed_metrics=("collector_latency", "task_health", "database_connection", "error_count"),
        message="候选月仅显示运维指标; 策略/信号/回测/交易/盈亏数据不可见。",
    )
