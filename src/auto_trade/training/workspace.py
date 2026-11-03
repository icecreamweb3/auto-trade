from __future__ import annotations

from collections.abc import Mapping, Sequence
from datetime import UTC, datetime
from typing import Annotated, Any, cast

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


class WorkspaceConfigReference(BaseModel):
    model_config = ConfigDict(frozen=True)

    config_version_id: str
    semver: str
    content_hash: str


class WorkspaceParameterProfile(BaseModel):
    model_config = ConfigDict(frozen=True)

    source: str
    experiment_id: str | None
    factor_registry: WorkspaceConfigReference
    search_space: WorkspaceConfigReference
    factors: tuple[str, ...]
    strategy_parameters: dict[str, Any]
    search_parameters: dict[str, Any]


class WorkspaceIteration(BaseModel):
    model_config = ConfigDict(frozen=True)

    iteration_id: str
    experiment_id: str
    candidate_version: int
    candidate_source: str
    state: str
    candidate_parameters: dict[str, Any]
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
    ready_profile: WorkspaceParameterProfile | None
    experiment_profiles: tuple[WorkspaceParameterProfile, ...]
    iterations: tuple[WorkspaceIteration, ...]
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


def _parameter_profile(
    rows: Sequence[Mapping[str, object]],
    *,
    source: str,
    experiment_id: str | None,
) -> WorkspaceParameterProfile | None:
    configs: dict[str, Mapping[str, object]] = {}
    for row in rows:
        configs.setdefault(str(row["config_type"]), row)
    factor_row = configs.get("FACTOR_REGISTRY")
    search_row = configs.get("SEARCH_SPACE")
    if factor_row is None or search_row is None:
        return None
    factor_config = cast(Mapping[str, object], factor_row["config_json"])
    search_config = cast(Mapping[str, object], search_row["config_json"])
    raw_factors = factor_config.get("factors")
    raw_strategy = search_config.get("strategy_parameters")
    raw_search = search_config.get("parameters")
    if (
        not isinstance(raw_factors, list)
        or not isinstance(raw_strategy, Mapping)
        or not isinstance(raw_search, Mapping)
    ):
        return None

    def reference(row: Mapping[str, object]) -> WorkspaceConfigReference:
        return WorkspaceConfigReference(
            config_version_id=str(row["config_version_id"]),
            semver=str(row["semver"]),
            content_hash=str(row["content_hash"]),
        )

    return WorkspaceParameterProfile(
        source=source,
        experiment_id=experiment_id,
        factor_registry=reference(factor_row),
        search_space=reference(search_row),
        factors=tuple(str(item) for item in raw_factors),
        strategy_parameters=dict(raw_strategy),
        search_parameters=dict(raw_search),
    )


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
            ready_config_rows = (
                await connection.execute(
                    text(
                        """
                        SELECT config_type, config_version_id::text, semver,
                               content_hash, config_json
                        FROM strategy_training.training_config_versions
                        WHERE status = 'READY'
                          AND config_type IN ('FACTOR_REGISTRY', 'SEARCH_SPACE')
                        ORDER BY config_type, created_at DESC
                        """
                    )
                )
            ).mappings().all()
            experiment_config_rows = (
                await connection.execute(
                    text(
                        """
                        SELECT binding.experiment_id::text, binding.config_type,
                               config.config_version_id::text, config.semver,
                               config.content_hash, config.config_json
                        FROM strategy_training.training_experiment_config_bindings binding
                        JOIN strategy_training.training_config_versions config
                          ON config.config_version_id = binding.config_version_id
                        WHERE binding.config_type IN ('FACTOR_REGISTRY', 'SEARCH_SPACE')
                        ORDER BY binding.experiment_id, binding.config_type
                        """
                    )
                )
            ).mappings().all()
            iterations = (
                await connection.execute(
                    text(
                        """
                        SELECT iteration_id::text, experiment_id::text,
                               candidate_version, candidate_source, state,
                               candidate_parameters, created_at
                        FROM strategy_training.training_iterations
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

    grouped_bindings: dict[str, list[Mapping[str, object]]] = {}
    for row in experiment_config_rows:
        grouped_bindings.setdefault(str(row["experiment_id"]), []).append(row)
    experiment_profiles = tuple(
        profile
        for experiment_id, rows in grouped_bindings.items()
        if (
            profile := _parameter_profile(
                rows,
                source="EXPERIMENT_FROZEN",
                experiment_id=experiment_id,
            )
        )
        is not None
    )
    return TrainingWorkspace(
        generated_at=datetime.now(UTC),
        mode="TRAINING_RESEARCH",
        counts={key: int(value) for key, value in count_rows.items()},
        experiments=tuple(WorkspaceExperiment.model_validate(row) for row in experiments),
        ready_profile=_parameter_profile(
            ready_config_rows,
            source="CURRENT_READY",
            experiment_id=None,
        ),
        experiment_profiles=experiment_profiles,
        iterations=tuple(WorkspaceIteration.model_validate(row) for row in iterations),
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
