from __future__ import annotations

import json
from datetime import datetime
from decimal import Decimal
from itertools import pairwise
from typing import Annotated, Any, Literal, TypeGuard
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from auto_trade.accounts.models import CurrentUser
from auto_trade.accounts.router import AuthenticatedUser

CONFIG_TYPES = (
    "FACTOR_REGISTRY",
    "SEARCH_SPACE",
    "SCORING_MODEL_A",
    "SCORING_MODEL_B",
    "SCORING_END_TO_END",
    "TICKER_POOL_RULES",
    "DATA_QUALITY_RULES",
    "HOLDING_HORIZON_RULES",
    "ELIGIBLE_POOL_RULES",
    "REPRODUCIBILITY_TOLERANCE",
    "RESOURCE_LIMITS",
    "SLIPPAGE_MODEL",
    "VISIBILITY_CUTOFF_POLICY",
    "EXIT_RULES",
    "FEE_MODEL",
    "PORTFOLIO_RULES",
    "OPPORTUNITY_DEFINITION",
    "RANDOM_BASELINE",
    "MODEL_B_SAMPLE_MIX",
    "CROSS_FIT_PROTOCOL",
    "VALIDATION_PROTOCOL",
    "RETENTION_POLICY",
)

INITIAL_MODEL_A_CONFIG_TYPES = (
    "TICKER_POOL_RULES",
    "DATA_QUALITY_RULES",
    "HOLDING_HORIZON_RULES",
    "ELIGIBLE_POOL_RULES",
    "REPRODUCIBILITY_TOLERANCE",
    "RESOURCE_LIMITS",
    "FEE_MODEL",
    "SLIPPAGE_MODEL",
    "VISIBILITY_CUTOFF_POLICY",
    "FACTOR_REGISTRY",
    "SEARCH_SPACE",
    "RANDOM_BASELINE",
    "OPPORTUNITY_DEFINITION",
    "SCORING_MODEL_A",
)

CONFIG_LABELS = {
    "TICKER_POOL_RULES": "Ticker 池规则",
    "DATA_QUALITY_RULES": "数据质量规则",
    "HOLDING_HORIZON_RULES": "标签与持仓周期",
    "ELIGIBLE_POOL_RULES": "合格标的规则",
    "REPRODUCIBILITY_TOLERANCE": "可复现容差",
    "RESOURCE_LIMITS": "资源限制",
    "FEE_MODEL": "费用模型",
    "SLIPPAGE_MODEL": "滑点模型",
    "VISIBILITY_CUTOFF_POLICY": "可见截止策略",
    "FACTOR_REGISTRY": "因子注册表",
    "SEARCH_SPACE": "搜索空间",
    "RANDOM_BASELINE": "随机基线",
    "OPPORTUNITY_DEFINITION": "机会定义",
    "SCORING_MODEL_A": "模型 A 评分",
}


def _is_number(value: Any) -> TypeGuard[int | float | Decimal]:
    return isinstance(value, (int, float, Decimal)) and not isinstance(value, bool)


def _positive_integer(payload: dict[str, Any], key: str, errors: list[str]) -> None:
    value = payload.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        errors.append(f"{key} 必须是正整数")


def _number_at_least(
    payload: dict[str, Any], key: str, minimum: float, errors: list[str], *, strict: bool = False
) -> None:
    value = payload.get(key)
    if not _is_number(value):
        operator = "大于" if strict else "不小于"
        errors.append(f"{key} 必须是{operator} {minimum} 的数值")
        return
    if value <= minimum if strict else value < minimum:
        operator = "大于" if strict else "不小于"
        errors.append(f"{key} 必须是{operator} {minimum} 的数值")


def validate_config_payload(config_type: str, payload: dict[str, Any]) -> tuple[str, ...]:
    errors: list[str] = []
    if not payload:
        return ("配置 JSON 不能为空",)
    if any(value is None for value in payload.values()):
        errors.append("配置 JSON 顶层字段不能使用 null 占位")

    if config_type == "FACTOR_REGISTRY":
        if (
            not isinstance(payload.get("adapter_version"), str)
            or not payload["adapter_version"].strip()
        ):
            errors.append("adapter_version 必须是非空字符串")
        factors = payload.get("factors")
        if not isinstance(factors, list) or not factors:
            errors.append("factors 必须是非空数组")
        elif any(not isinstance(item, str) or not item.strip() for item in factors) or len(
            set(factors)
        ) != len(factors):
            errors.append("factors 必须是唯一的非空字符串")
    elif config_type == "SEARCH_SPACE":
        if payload.get("interval_seconds") not in (300, 900):
            errors.append("interval_seconds 必须为 300 或 900")
        if (
            not isinstance(payload.get("strategy_parameters"), dict)
            or not payload["strategy_parameters"]
        ):
            errors.append("strategy_parameters 必须是非空对象")
        if not isinstance(payload.get("parameters"), dict) or not payload["parameters"]:
            errors.append("parameters 必须是非空 Optuna 参数对象")
    elif config_type == "OPPORTUNITY_DEFINITION":
        _number_at_least(payload, "minimum_mfe_percent", 0, errors, strict=True)
        _number_at_least(payload, "maximum_mae_percent", 0, errors)
        if not _is_number(payload.get("minimum_return_percent")):
            errors.append("minimum_return_percent 必须是显式数值")
    elif config_type == "HOLDING_HORIZON_RULES":
        _positive_integer(payload, "label_horizon_seconds", errors)
        _positive_integer(payload, "max_holding_seconds", errors)
    elif config_type == "REPRODUCIBILITY_TOLERANCE":
        _number_at_least(payload, "absolute_tolerance", 0, errors)
        _number_at_least(payload, "relative_tolerance", 0, errors)
    elif config_type == "ELIGIBLE_POOL_RULES":
        _number_at_least(payload, "minimum_listing_age_seconds", 0, errors)
        _number_at_least(payload, "minimum_notional_volume", 0, errors, strict=True)
        _number_at_least(payload, "liquidity_lookback_seconds", 0, errors, strict=True)
        if (
            not isinstance(payload.get("required_contract_type"), str)
            or not payload["required_contract_type"].strip()
        ):
            errors.append("required_contract_type 必须是非空字符串")
    elif config_type == "DATA_QUALITY_RULES":
        dependencies = payload.get("required_dependencies")
        rules = payload.get("dependency_rules")
        if not isinstance(dependencies, list) or not dependencies:
            errors.append("required_dependencies 必须是非空数组")
        elif any(not isinstance(item, str) or not item.strip() for item in dependencies):
            errors.append("required_dependencies 只能包含非空字符串")
        if not isinstance(rules, dict):
            errors.append("dependency_rules 必须是对象")
        elif isinstance(dependencies, list):
            for dependency in dependencies:
                rule = rules.get(dependency) if isinstance(dependency, str) else None
                if not isinstance(rule, dict):
                    errors.append(f"dependency_rules 缺少 {dependency} 的规则")
                    continue
                coverage = rule.get("minimum_coverage")
                if not _is_number(coverage):
                    errors.append(f"{dependency}.minimum_coverage 必须在 0 到 1 之间")
                elif not 0 <= coverage <= 1:
                    errors.append(f"{dependency}.minimum_coverage 必须在 0 到 1 之间")
                for key in ("minimum_effective_samples", "minimum_effective_folds"):
                    value = rule.get(key)
                    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                        errors.append(f"{dependency}.{key} 必须是非负整数")
                if not isinstance(rule.get("warmup_required"), bool):
                    errors.append(f"{dependency}.warmup_required 必须是布尔值")
    elif config_type == "RESOURCE_LIMITS":
        for key in (
            "max_heavy_experiments",
            "db_workers_per_experiment",
            "pool_connections",
            "statement_timeout_seconds",
            "lock_timeout_seconds",
            "idle_in_transaction_session_timeout_seconds",
            "work_mem_bytes",
            "cpu_limit",
            "memory_bytes",
            "temp_disk_min_free_bytes",
            "max_candidate_count",
            "max_signal_count",
            "max_decision_row_count",
            "max_storage_bytes",
        ):
            _number_at_least(payload, key, 0, errors, strict=True)
    elif config_type == "FEE_MODEL":
        _number_at_least(payload, "maker_rate", 0, errors)
        _number_at_least(payload, "taker_rate", 0, errors)
    elif config_type == "SLIPPAGE_MODEL":
        if not isinstance(payload.get("model_name"), str) or not payload["model_name"].strip():
            errors.append("model_name 必须是非空字符串")
        for key in ("notional_coefficient", "liquidity_coefficient", "volatility_coefficient"):
            _number_at_least(payload, key, 0, errors)
    elif config_type == "VISIBILITY_CUTOFF_POLICY":
        if not isinstance(payload.get("policy_name"), str) or not payload["policy_name"].strip():
            errors.append("policy_name 必须是非空字符串")
        _number_at_least(payload, "required_lead_seconds", 0, errors)
    elif config_type == "RANDOM_BASELINE":
        for key in ("sample_count", "minimum_frame_size", "maximum_frame_candidates"):
            _positive_integer(payload, key, errors)
        exclusion = payload.get("exclusion_window_seconds")
        if not isinstance(exclusion, int) or isinstance(exclusion, bool) or exclusion < 0:
            errors.append("exclusion_window_seconds 必须是非负整数")
        expected_fields = {
            "btc_regime",
            "instrument_id",
            "liquidity_bucket",
            "pool_identity",
            "time_bucket",
            "volatility_bucket",
        }
        fields = payload.get("matching_fields")
        if not isinstance(fields, list) or len(fields) != 6 or set(fields) != expected_fields:
            errors.append("matching_fields 必须精确包含六个治理匹配字段")
        strata = payload.get("stratification")
        if not isinstance(strata, dict):
            errors.append("stratification 必须是对象")
        else:
            measures = {
                "volatility_measure": "CLOSE_RETURN_STDDEV_PERCENT",
                "liquidity_measure": "MEAN_QUOTE_VOLUME",
                "btc_regime_measure": "CLOSE_RETURN_PERCENT",
            }
            if (
                not isinstance(strata.get("benchmark_symbol"), str)
                or not strata["benchmark_symbol"].strip()
                or strata["benchmark_symbol"] != strata["benchmark_symbol"].upper()
            ):
                errors.append("benchmark_symbol 必须是大写非空字符串")
            for key, expected in measures.items():
                if strata.get(key) != expected:
                    errors.append(f"{key} 必须为 {expected}")
            for key in (
                "volatility_window_bars",
                "liquidity_window_bars",
                "btc_regime_window_bars",
            ):
                _positive_integer(strata, key, errors)
            for key in (
                "volatility_boundaries_percent",
                "liquidity_boundaries_quote_volume",
                "btc_return_boundaries_percent",
            ):
                values = strata.get(key)
                if (
                    not isinstance(values, list)
                    or not values
                    or any(not _is_number(value) for value in values)
                ):
                    errors.append(f"{key} 必须是非空数值数组")
                elif any(current <= previous for previous, current in pairwise(values)):
                    errors.append(f"{key} 必须严格递增")
    elif config_type == "SCORING_MODEL_A":
        if payload.get("calculation_version") != "DISCOVERY_V1":
            errors.append("calculation_version 必须为 DISCOVERY_V1")
        expected_weights = {
            "opportunity_recall",
            "entry_timing",
            "excess_mfe_quality",
            "cross_period_stability",
            "false_signal_penalty",
            "low_sample_penalty",
            "concentration_penalty",
        }
        weights = payload.get("weights")
        if not isinstance(weights, dict) or set(weights) != expected_weights:
            errors.append("weights 必须精确包含七个模型 A 权重")
        elif any(not _is_number(value) or value < 0 for value in weights.values()):
            errors.append("模型 A 权重必须是非负数值")
        for key in ("entry_timing_scale_percent", "excess_mfe_scale_percent"):
            _number_at_least(payload, key, 0, errors, strict=True)
        for key in (
            "minimum_signal_count",
            "minimum_opportunity_count",
            "minimum_effective_day_count",
            "minimum_week_count",
        ):
            _positive_integer(payload, key, errors)

    return tuple(dict.fromkeys(errors))


class ConfigVersion(BaseModel):
    model_config = ConfigDict(frozen=True)

    config_version_id: UUID
    config_type: str
    label: str
    semver: str
    schema_version: int
    config_json: dict[str, Any]
    content_hash: str
    parent_version_id: UUID | None
    status: Literal["DRAFT", "READY", "RETIRED"]
    created_by: str
    ready_by: str | None
    retired_by: str | None
    created_at: datetime
    ready_at: datetime | None
    retired_at: datetime | None
    validation_errors: tuple[str, ...]


class ConfigInventory(BaseModel):
    model_config = ConfigDict(frozen=True)

    required_types: tuple[str, ...]
    missing_ready_types: tuple[str, ...]
    ready_complete: bool
    can_edit: bool
    can_approve: bool
    versions: tuple[ConfigVersion, ...]


class ConfigDraftCreate(BaseModel):
    config_type: str
    semver: str = Field(pattern=r"^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$")
    schema_version: int = Field(ge=1)
    config_json: dict[str, Any]
    parent_version_id: UUID | None = None
    reason: str = Field(min_length=1, max_length=1000)


class ConfigDraftUpdate(BaseModel):
    expected_content_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    semver: str = Field(pattern=r"^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$")
    schema_version: int = Field(ge=1)
    config_json: dict[str, Any]
    parent_version_id: UUID | None = None
    reason: str = Field(min_length=1, max_length=1000)


class ConfigTransition(BaseModel):
    reason: str = Field(min_length=1, max_length=1000)


router = APIRouter(prefix="/api/training/configs", tags=["training-configs"])


async def _roles(request: Request, user_id: UUID) -> set[str]:
    try:
        async with request.app.state.database_engine.connect() as connection:
            rows = (
                (
                    await connection.execute(
                        text("""
                        SELECT DISTINCT role_grant.training_role
                        FROM core.app_user_training_roles role_grant
                        LEFT JOIN core.app_user_training_role_revocations revocation
                          ON revocation.grant_id = role_grant.grant_id
                        WHERE role_grant.user_id = :user_id
                          AND role_grant.valid_from <= clock_timestamp()
                          AND role_grant.expires_at > clock_timestamp()
                          AND revocation.grant_id IS NULL
                          AND role_grant.training_role IN ('TRAINING_RESEARCHER', 'TRAINING_ADMIN')
                    """),
                        {"user_id": user_id},
                    )
                )
                .scalars()
                .all()
            )
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="训练配置授权不可用") from error
    return {str(role) for role in rows}


async def require_config_reader(request: Request, user: AuthenticatedUser) -> CurrentUser:
    if not await _roles(request, user.user_id):
        raise HTTPException(status_code=403, detail="需要有效的训练研究员或训练管理员授权")
    return user


ConfigReader = Annotated[CurrentUser, Depends(require_config_reader)]


def _row_to_version(row: Any) -> ConfigVersion:
    payload = dict(row["config_json"])
    return ConfigVersion(
        **dict(row),
        label=CONFIG_LABELS.get(str(row["config_type"]), str(row["config_type"])),
        config_json=payload,
        validation_errors=validate_config_payload(str(row["config_type"]), payload),
    )


_CONFIG_SELECT = """
    SELECT config.config_version_id, config.config_type, config.semver,
           config.schema_version, config.config_json, config.content_hash,
           config.parent_version_id, config.status,
           creator.email AS created_by, approver.email AS ready_by,
           retirer.email AS retired_by, config.created_at, config.ready_at,
           config.retired_at
    FROM strategy_training.training_config_versions config
    JOIN core.app_users creator ON creator.user_id = config.created_by_user_id
    LEFT JOIN core.app_users approver ON approver.user_id = config.ready_by_user_id
    LEFT JOIN core.app_users retirer ON retirer.user_id = config.retired_by_user_id
"""


async def _load_config(connection: Any, config_version_id: UUID) -> ConfigVersion:
    row = (
        (
            await connection.execute(
                text(_CONFIG_SELECT + " WHERE config.config_version_id = :config_version_id"),
                {"config_version_id": config_version_id},
            )
        )
        .mappings()
        .one_or_none()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="训练配置版本不存在")
    return _row_to_version(row)


def _database_conflict(error: SQLAlchemyError) -> HTTPException:
    message = str(getattr(error, "orig", error)).splitlines()[0]
    return HTTPException(status_code=409, detail=f"配置操作被数据库契约拒绝: {message}")


@router.get("", response_model=ConfigInventory)
async def list_configs(request: Request, user: ConfigReader) -> ConfigInventory:
    roles = await _roles(request, user.user_id)
    try:
        async with request.app.state.database_engine.connect() as connection:
            rows = (
                (
                    await connection.execute(
                        text(
                            _CONFIG_SELECT + " ORDER BY config.config_type, config.created_at DESC"
                        )
                    )
                )
                .mappings()
                .all()
            )
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="训练配置清单读取失败") from error
    versions = tuple(_row_to_version(row) for row in rows)
    ready_types = {version.config_type for version in versions if version.status == "READY"}
    missing = tuple(item for item in INITIAL_MODEL_A_CONFIG_TYPES if item not in ready_types)
    return ConfigInventory(
        required_types=INITIAL_MODEL_A_CONFIG_TYPES,
        missing_ready_types=missing,
        ready_complete=not missing,
        can_edit="TRAINING_RESEARCHER" in roles,
        can_approve="TRAINING_ADMIN" in roles,
        versions=versions,
    )


@router.get("/{config_version_id}", response_model=ConfigVersion)
async def get_config(
    config_version_id: UUID, request: Request, _user: ConfigReader
) -> ConfigVersion:
    async with request.app.state.database_engine.connect() as connection:
        return await _load_config(connection, config_version_id)


@router.post("", response_model=ConfigVersion, status_code=201)
async def create_config(
    payload: ConfigDraftCreate, request: Request, user: ConfigReader
) -> ConfigVersion:
    roles = await _roles(request, user.user_id)
    if "TRAINING_RESEARCHER" not in roles:
        raise HTTPException(status_code=403, detail="创建 DRAFT 需要 TRAINING_RESEARCHER 授权")
    if payload.config_type not in CONFIG_TYPES:
        raise HTTPException(status_code=422, detail="未知的配置类型")
    request_id = uuid4()
    try:
        async with request.app.state.database_engine.begin() as connection:
            config_version_id = (
                await connection.execute(
                    text("""
                        SELECT strategy_training.create_training_config_draft(
                            :config_type, :semver, :schema_version,
                            CAST(:config_json AS jsonb), :parent_version_id,
                            :actor_user_id, :reason, :request_id
                        )
                    """),
                    {
                        "config_type": payload.config_type,
                        "semver": payload.semver,
                        "schema_version": payload.schema_version,
                        "config_json": json.dumps(payload.config_json, ensure_ascii=False),
                        "parent_version_id": payload.parent_version_id,
                        "actor_user_id": user.user_id,
                        "reason": payload.reason.strip(),
                        "request_id": request_id,
                    },
                )
            ).scalar_one()
            return await _load_config(connection, config_version_id)
    except SQLAlchemyError as error:
        raise _database_conflict(error) from error


@router.put("/{config_version_id}", response_model=ConfigVersion)
async def update_config(
    config_version_id: UUID, payload: ConfigDraftUpdate, request: Request, user: ConfigReader
) -> ConfigVersion:
    roles = await _roles(request, user.user_id)
    if "TRAINING_RESEARCHER" not in roles:
        raise HTTPException(status_code=403, detail="编辑 DRAFT 需要 TRAINING_RESEARCHER 授权")
    try:
        async with request.app.state.database_engine.begin() as connection:
            await connection.execute(
                text("""
                    SELECT strategy_training.update_training_config_draft(
                        :config_version_id, :expected_content_hash, :semver,
                        :schema_version, CAST(:config_json AS jsonb), :parent_version_id,
                        :actor_user_id, :reason, :request_id
                    )
                """),
                {
                    "config_version_id": config_version_id,
                    "expected_content_hash": payload.expected_content_hash,
                    "semver": payload.semver,
                    "schema_version": payload.schema_version,
                    "config_json": json.dumps(payload.config_json, ensure_ascii=False),
                    "parent_version_id": payload.parent_version_id,
                    "actor_user_id": user.user_id,
                    "reason": payload.reason.strip(),
                    "request_id": uuid4(),
                },
            )
            return await _load_config(connection, config_version_id)
    except SQLAlchemyError as error:
        raise _database_conflict(error) from error


async def _transition(
    config_version_id: UUID,
    expected_state: str,
    new_state: str,
    payload: ConfigTransition,
    request: Request,
    user: CurrentUser,
) -> ConfigVersion:
    roles = await _roles(request, user.user_id)
    if "TRAINING_ADMIN" not in roles:
        raise HTTPException(status_code=403, detail="状态审批需要 TRAINING_ADMIN 授权")
    try:
        async with request.app.state.database_engine.begin() as connection:
            if new_state == "READY":
                current = await _load_config(connection, config_version_id)
                errors = validate_config_payload(current.config_type, current.config_json)
                if errors:
                    raise HTTPException(
                        status_code=422,
                        detail={"message": "配置未通过服务端校验", "errors": errors},
                    )
                await connection.execute(
                    text("""
                        SELECT strategy_training.approve_training_config_ready(
                            :config_version_id, :expected_content_hash,
                            :actor_user_id, :reason, :request_id
                        )
                    """),
                    {
                        "config_version_id": config_version_id,
                        "expected_content_hash": current.content_hash,
                        "actor_user_id": user.user_id,
                        "reason": payload.reason.strip(),
                        "request_id": uuid4(),
                    },
                )
            else:
                await connection.execute(
                    text("""
                        SELECT strategy_training.transition_training_config(
                            :config_version_id, :expected_state, :new_state,
                            :actor_user_id, :reason, :request_id
                        )
                    """),
                    {
                        "config_version_id": config_version_id,
                        "expected_state": expected_state,
                        "new_state": new_state,
                        "actor_user_id": user.user_id,
                        "reason": payload.reason.strip(),
                        "request_id": uuid4(),
                    },
                )
            return await _load_config(connection, config_version_id)
    except HTTPException:
        raise
    except SQLAlchemyError as error:
        raise _database_conflict(error) from error


@router.post("/{config_version_id}/ready", response_model=ConfigVersion)
async def approve_ready(
    config_version_id: UUID, payload: ConfigTransition, request: Request, user: ConfigReader
) -> ConfigVersion:
    return await _transition(config_version_id, "DRAFT", "READY", payload, request, user)


@router.post("/{config_version_id}/retire", response_model=ConfigVersion)
async def retire_config(
    config_version_id: UUID, payload: ConfigTransition, request: Request, user: ConfigReader
) -> ConfigVersion:
    return await _transition(config_version_id, "READY", "RETIRED", payload, request, user)
