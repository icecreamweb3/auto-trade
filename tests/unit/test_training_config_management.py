from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import HTTPException

from auto_trade.accounts.models import AccountSummary, CurrentUser, UserRole
from auto_trade.training.config_management import (
    INITIAL_MODEL_A_CONFIG_TYPES,
    INITIAL_MODEL_B_CONFIG_TYPES,
    MODEL_B_DRAFT_TEMPLATES,
    ConfigVersion,
    _build_ready_export,
    _database_conflict,
    _row_to_version,
    require_config_reader,
    validate_config_payload,
)


def _user() -> CurrentUser:
    return CurrentUser(
        user_id=uuid4(),
        email="researcher@example.test",
        role=UserRole.NORMAL,
        created_at=datetime.now(UTC),
        account=AccountSummary(
            starting_balance=1000,
            balance=1000,
            realized_pnl=0,
            trade_count=0,
        ),
    )


def _request_with_roles(*roles: str) -> MagicMock:
    scalars = MagicMock()
    scalars.all.return_value = list(roles)
    result = MagicMock()
    result.scalars.return_value = scalars
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)
    request = MagicMock()
    request.app.state.database_engine = engine
    return request


async def test_config_reader_requires_explicit_training_role() -> None:
    user = _user()

    assert await require_config_reader(_request_with_roles("TRAINING_RESEARCHER"), user) is user
    assert await require_config_reader(_request_with_roles("TRAINING_ADMIN"), user) is user
    with pytest.raises(HTTPException) as error:
        await require_config_reader(_request_with_roles(), user)
    assert error.value.status_code == 403


def test_initial_model_a_inventory_contains_exactly_fourteen_governed_types() -> None:
    assert len(INITIAL_MODEL_A_CONFIG_TYPES) == 14
    assert len(set(INITIAL_MODEL_A_CONFIG_TYPES)) == 14
    assert "RESOURCE_LIMITS" in INITIAL_MODEL_A_CONFIG_TYPES
    assert "SCORING_MODEL_A" in INITIAL_MODEL_A_CONFIG_TYPES


def test_initial_model_b_inventory_has_separate_exit_search_and_shared_costs() -> None:
    assert len(INITIAL_MODEL_B_CONFIG_TYPES) == 9
    assert len(set(INITIAL_MODEL_B_CONFIG_TYPES)) == 9
    assert "SEARCH_SPACE" not in INITIAL_MODEL_B_CONFIG_TYPES
    assert "MODEL_B_SEARCH_SPACE" in INITIAL_MODEL_B_CONFIG_TYPES
    assert {"FEE_MODEL", "SLIPPAGE_MODEL", "CROSS_FIT_PROTOCOL"}.issubset(
        INITIAL_MODEL_B_CONFIG_TYPES
    )
    assert set(MODEL_B_DRAFT_TEMPLATES) == {
        "EXIT_RULES",
        "MODEL_B_SEARCH_SPACE",
        "SCORING_MODEL_B",
        "MODEL_B_SAMPLE_MIX",
        "PORTFOLIO_RULES",
    }


def test_factor_registry_and_search_space_validation() -> None:
    assert (
        validate_config_payload(
            "FACTOR_REGISTRY",
            {"adapter_version": "v2", "factors": ["volume_ratio", "amplitude"]},
        )
        == ()
    )
    assert (
        validate_config_payload(
            "SEARCH_SPACE",
            {
                "interval_seconds": 300,
                "strategy_parameters": {"cooldown_bars": 4},
                "parameters": {"cooldown_bars": {"type": "int", "low": 1, "high": 8}},
            },
        )
        == ()
    )
    assert "factors 必须是唯一的非空字符串" in validate_config_payload(
        "FACTOR_REGISTRY", {"adapter_version": "v2", "factors": ["x", "x"]}
    )


def test_ticker_pool_rejects_top_n_above_current_ranking_contract() -> None:
    payload = {
        "policy_name": "UTC_DAILY_2355_TOP_50_D_MINUS_1_V1",
        "source": "market.ranking_snapshots",
        "ranking_type": "UTC_DAILY_2355",
        "as_of_lag_days": 1,
        "top_n": 50,
        "excluded_symbols": [],
        "required_contract_type": "USDT_PERPETUAL",
    }

    assert validate_config_payload("TICKER_POOL_RULES", payload) == ()
    payload["top_n"] = 100
    assert (
        "top_n 必须是 1 到 50 的整数 (当前排名契约上限为 50)"
        in validate_config_payload("TICKER_POOL_RULES", payload)
    )


def test_eligible_pool_requires_explicit_kline_status_inference_threshold() -> None:
    payload = {
        "minimum_listing_age_seconds": 86400,
        "minimum_notional_volume": 500,
        "liquidity_lookback_seconds": 86400,
        "required_contract_type": "USDT_PERPETUAL",
    }

    assert (
        "inferred_trading_minimum_notional_volume 必须是大于 0 的数值"
        in validate_config_payload("ELIGIBLE_POOL_RULES", payload)
    )
    payload["inferred_trading_minimum_notional_volume"] = 100000
    assert validate_config_payload("ELIGIBLE_POOL_RULES", payload) == ()


def test_duplicate_config_semver_has_actionable_conflict_message() -> None:
    error = MagicMock()
    error.orig = Exception(
        'duplicate key value violates unique constraint '
        '"training_config_versions_config_type_semver_key"'
    )

    conflict = _database_conflict(error)

    assert conflict.status_code == 409
    assert "已退役版本的版本号也不能复用" in conflict.detail


def test_random_baseline_rejects_incomplete_stratification() -> None:
    errors = validate_config_payload(
        "RANDOM_BASELINE",
        {
            "sample_count": 10,
            "minimum_frame_size": 5,
            "maximum_frame_candidates": 100,
            "exclusion_window_seconds": 300,
            "matching_fields": [
                "btc_regime",
                "instrument_id",
                "liquidity_bucket",
                "pool_identity",
                "time_bucket",
                "volatility_bucket",
            ],
            "stratification": {"benchmark_symbol": "BTCUSDT"},
        },
    )

    assert "volatility_measure 必须为 CLOSE_RETURN_STDDEV_PERCENT" in errors
    assert "volatility_window_bars 必须是正整数" in errors


def test_scoring_model_a_requires_exact_weights_and_minimum_counts() -> None:
    errors = validate_config_payload(
        "SCORING_MODEL_A",
        {
            "calculation_version": "DISCOVERY_V1",
            "weights": {"opportunity_recall": 1},
            "entry_timing_scale_percent": 1,
            "excess_mfe_scale_percent": 1,
            "minimum_signal_count": 0,
            "minimum_opportunity_count": 1,
            "minimum_effective_day_count": 1,
            "minimum_week_count": 1,
        },
    )

    assert "weights 必须精确包含七个模型 A 权重" in errors
    assert "minimum_signal_count 必须是正整数" in errors


@pytest.mark.parametrize(
    ("config_type", "payload"),
    tuple(MODEL_B_DRAFT_TEMPLATES.items()),
)
def test_model_b_draft_templates_pass_service_validation(
    config_type: str, payload: dict[str, object]
) -> None:
    assert validate_config_payload(config_type, payload) == ()


def test_model_b_search_space_rejects_model_a_or_over_24h_rules() -> None:
    model_a_errors = validate_config_payload(
        "MODEL_B_SEARCH_SPACE",
        {
            "interval_seconds": 300,
            "strategy_parameters": {"cooldown_bars": 4},
            "parameters": {"cooldown_bars": [1, 12]},
        },
    )
    assert "model_family 必须为 RULE_BASED_EXIT_V1" in model_a_errors
    assert "parameters 必须精确包含五个模型 B 退出参数" in model_a_errors

    payload = dict(MODEL_B_DRAFT_TEMPLATES["MODEL_B_SEARCH_SPACE"])
    payload["parameters"] = dict(payload["parameters"])
    payload["parameters"]["max_holding_seconds"] = {
        "kind": "categorical",
        "choices": [86700],
    }
    assert (
        "max_holding_seconds choices 必须按 5m 对齐且不超过 24h"
        in validate_config_payload("MODEL_B_SEARCH_SPACE", payload)
    )


def test_database_row_is_converted_without_duplicate_config_json_argument() -> None:
    config_version_id = uuid4()
    created_at = datetime.now(UTC)
    version = _row_to_version(
        {
            "config_version_id": config_version_id,
            "config_type": "HOLDING_HORIZON_RULES",
            "semver": "0.1.0",
            "schema_version": 1,
            "config_json": {
                "label_horizon_seconds": 86400,
                "max_holding_seconds": 86400,
            },
            "content_hash": "a" * 64,
            "parent_version_id": None,
            "status": "DRAFT",
            "created_by": "researcher@example.test",
            "ready_by": None,
            "retired_by": None,
            "created_at": created_at,
            "ready_at": None,
            "retired_at": None,
        }
    )

    assert version.config_version_id == config_version_id
    assert version.config_json["label_horizon_seconds"] == 86400
    assert version.validation_errors == ()


def test_ready_export_is_ordered_and_contains_integrity_manifest() -> None:
    generated_at = datetime(2026, 11, 3, 6, 30, tzinfo=UTC)
    versions = tuple(
        ConfigVersion(
            config_version_id=uuid4(),
            config_type=config_type,
            label=config_type,
            semver="0.1.0",
            schema_version=1,
            config_json={"position": index},
            content_hash=f"{index:064x}",
            parent_version_id=None,
            status="READY",
            created_by="researcher@example.test",
            ready_by="admin@example.test",
            retired_by=None,
            created_at=generated_at,
            ready_at=generated_at,
            retired_at=None,
            validation_errors=(),
        )
        for index, config_type in reversed(tuple(enumerate(INITIAL_MODEL_A_CONFIG_TYPES, 1)))
    )

    exported = _build_ready_export(
        versions, exported_by="admin@example.test", generated_at=generated_at
    )

    assert exported["ready_complete"] is True
    assert exported["config_count"] == 14
    assert exported["missing_ready_types"] == []
    assert [config["config_type"] for config in exported["configs"]] == list(
        INITIAL_MODEL_A_CONFIG_TYPES
    )
    assert len(exported["manifest_hash"]) == 64
    assert exported["configs"][0]["ready_by"] == "admin@example.test"
