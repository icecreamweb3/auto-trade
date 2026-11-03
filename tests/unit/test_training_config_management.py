from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import HTTPException

from auto_trade.accounts.models import AccountSummary, CurrentUser, UserRole
from auto_trade.training.config_management import (
    INITIAL_MODEL_A_CONFIG_TYPES,
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
