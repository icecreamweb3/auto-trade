from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime
from decimal import Decimal
from itertools import pairwise
from typing import Annotated, Any, Literal, TypeGuard
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from auto_trade.accounts.models import CurrentUser
from auto_trade.accounts.router import AuthenticatedUser

CONFIG_TYPES = (
    "FACTOR_REGISTRY",
    "SEARCH_SPACE",
    "MODEL_B_SEARCH_SPACE",
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

INITIAL_MODEL_B_CONFIG_TYPES = (
    "HOLDING_HORIZON_RULES",
    "FEE_MODEL",
    "SLIPPAGE_MODEL",
    "CROSS_FIT_PROTOCOL",
    "EXIT_RULES",
    "MODEL_B_SEARCH_SPACE",
    "SCORING_MODEL_B",
    "MODEL_B_SAMPLE_MIX",
    "PORTFOLIO_RULES",
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
    "CROSS_FIT_PROTOCOL": "Cross-fit 协议",
    "EXIT_RULES": "模型 B 退出边界",
    "MODEL_B_SEARCH_SPACE": "模型 B 搜索空间",
    "SCORING_MODEL_B": "模型 B 评分",
    "MODEL_B_SAMPLE_MIX": "模型 B 样本混合",
    "PORTFOLIO_RULES": "组合与仓位规则",
}

MODEL_B_DRAFT_TEMPLATES: dict[str, dict[str, Any]] = {
    "EXIT_RULES": {
        "model_family": "RULE_BASED_EXIT_V2",
        "return_basis": "ENTRY_FILL_PRICE_PERCENT",
        "initial_stop_loss_percent": 5.0,
        "partial_take_profit": {
            "fraction_basis": "REMAINING_POSITION",
            "levels": [
                {"trigger_profit_percent": 10.0, "close_fraction": 0.20},
                {"trigger_profit_percent": 15.0, "close_fraction": 0.20},
                {"trigger_profit_percent": 25.0, "close_fraction": 0.20},
                {"trigger_profit_percent": 35.0, "close_fraction": 0.20},
            ],
        },
        "stop_schedule": {
            "levels": [
                {"trigger_profit_percent": 10.0, "locked_profit_percent": 1.0},
                {"trigger_profit_percent": 15.0, "locked_profit_percent": 5.0},
                {"trigger_profit_percent": 25.0, "locked_profit_percent": 15.0},
                {"trigger_profit_percent": 35.0, "locked_profit_percent": 25.0},
            ],
            "high_water_trailing_activation_percent": 25.0,
            "high_water_max_drawdown_percent": 10.0,
        },
        "max_holding_seconds": 86400,
        "intrabar_conflict_policy": "WORST_CASE",
        "rule_activation_timing": "NEXT_BAR",
    },
    "MODEL_B_SEARCH_SPACE": {
        "model_family": "RULE_BASED_EXIT_V2",
        "interval_seconds": 300,
        "hard_max_holding_seconds": 86400,
        "policy_templates": {
            "FOUR_STAGE_SCALED_REMAINING_V1": {
                "base_partial_trigger_profit_percents": [10.0, 15.0, 25.0, 35.0],
                "base_stop_locked_profit_percents": [1.0, 5.0, 15.0, 25.0],
                "base_high_water_trailing_activation_percent": 25.0,
                "base_high_water_max_drawdown_percent": 10.0,
                "minimum_remaining_fraction": 0.30,
            }
        },
        "parameters": {
            "max_holding_seconds": {
                "kind": "categorical",
                "choices": [21600, 43200, 64800, 86400],
            },
            "initial_stop_loss_percent": {
                "kind": "numeric",
                "minimum": 2.0,
                "maximum": 10.0,
                "integer": False,
            },
            "exit_policy_template": {
                "kind": "categorical",
                "choices": ["FOUR_STAGE_SCALED_REMAINING_V1"],
            },
            "trigger_scale": {
                "kind": "numeric",
                "minimum": 0.8,
                "maximum": 1.2,
                "integer": False,
            },
            "shared_close_fraction": {
                "kind": "numeric",
                "minimum": 0.10,
                "maximum": 0.30,
                "integer": False,
            },
        },
    },
    "SCORING_MODEL_B": {
        "calculation_version": "EXIT_NET_EXPECTANCY_V1",
        "primary_metric": "NET_EXPECTANCY_PERCENTAGE_POINTS",
        "cluster_unit": "UTC_DAY",
        "bootstrap_method": "BCA_CLUSTER_BOOTSTRAP",
        "bootstrap_replicates": 5000,
        "confidence_level": 0.95,
        "cost_stress_multipliers": [1.0, 1.5, 2.0],
    },
    "MODEL_B_SAMPLE_MIX": {
        "natural_frequency_source": "CROSS_FIT_MODEL_A",
        "natural_frequency_weight": 1.0,
        "control_source": "ADVERSE_OR_RANGE_CONTROL",
        "control_weight": 0.0,
        "oracle_source": "ORACLE_ENTRY_BENCHMARK",
        "oracle_weight": 0.0,
        "random_seed": 42,
    },
    "PORTFOLIO_RULES": {
        "initial_capital": 1000,
        "notional_per_trade": 1000,
        "maximum_concurrent_positions": 1,
        "same_ticker_position_policy": "ONE_OPEN_POSITION",
    },
}

MODEL_B_DRAFT_SCHEMA_VERSIONS: dict[str, int] = {
    config_type: 2 if config_type in {"EXIT_RULES", "MODEL_B_SEARCH_SPACE"} else 1
    for config_type in MODEL_B_DRAFT_TEMPLATES
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


def _validate_model_b_parameter_rules(payload: dict[str, Any], errors: list[str]) -> None:
    expected = {
        "max_holding_seconds",
        "initial_stop_loss_percent",
        "exit_policy_template",
        "trigger_scale",
        "shared_close_fraction",
    }
    parameters = payload.get("parameters")
    if not isinstance(parameters, dict) or set(parameters) != expected:
        errors.append("parameters 必须精确包含五个模型 B V2 搜索参数")
        return
    for name, raw_rule in parameters.items():
        if not isinstance(raw_rule, dict):
            errors.append(f"{name} 参数规则必须是对象")
            continue
        kind = raw_rule.get("kind")
        if name in {"max_holding_seconds", "exit_policy_template"} and kind != "categorical":
            errors.append(f"{name} 必须使用 categorical choices")
            continue
        if name in {
            "initial_stop_loss_percent",
            "trigger_scale",
            "shared_close_fraction",
        } and kind != "numeric":
            errors.append(f"{name} 必须使用 numeric 范围")
            continue
        if kind == "numeric":
            minimum = raw_rule.get("minimum")
            maximum = raw_rule.get("maximum")
            if (
                not _is_number(minimum)
                or not _is_number(maximum)
                or minimum > maximum
                or not isinstance(raw_rule.get("integer"), bool)
            ):
                errors.append(f"{name} 数值规则必须包含有效 minimum/maximum/integer")
        elif kind == "categorical":
            choices = raw_rule.get("choices")
            if not isinstance(choices, list) or not choices:
                errors.append(f"{name} 分类规则 choices 必须是非空数组")
                continue
            if name == "max_holding_seconds" and any(
                not isinstance(value, int)
                or isinstance(value, bool)
                or value <= 0
                or value > 86400
                or value % 300 != 0
                for value in choices
            ):
                errors.append("max_holding_seconds choices 必须按 5m 对齐且不超过 24h")
            if name == "exit_policy_template":
                templates = payload.get("policy_templates")
                if not isinstance(templates, dict) or any(
                    not isinstance(value, str) or value not in templates for value in choices
                ):
                    errors.append("exit_policy_template choices 必须引用已声明模板")
        else:
            errors.append(f"{name}.kind 必须为 numeric 或 categorical")

    expected_numeric_bounds = {
        "initial_stop_loss_percent": (2.0, 10.0),
        "trigger_scale": (0.8, 1.2),
        "shared_close_fraction": (0.10, 0.30),
    }
    for name, (minimum, maximum) in expected_numeric_bounds.items():
        rule = parameters.get(name)
        if isinstance(rule, dict) and (
            rule.get("minimum") != minimum
            or rule.get("maximum") != maximum
            or rule.get("integer") is not False
        ):
            errors.append(f"{name} 必须使用已审批范围 {minimum}-{maximum}")
    templates = payload.get("policy_templates")
    expected_template = {
        "FOUR_STAGE_SCALED_REMAINING_V1": {
            "base_partial_trigger_profit_percents": [10.0, 15.0, 25.0, 35.0],
            "base_stop_locked_profit_percents": [1.0, 5.0, 15.0, 25.0],
            "base_high_water_trailing_activation_percent": 25.0,
            "base_high_water_max_drawdown_percent": 10.0,
            "minimum_remaining_fraction": 0.30,
        }
    }
    if templates != expected_template:
        errors.append("policy_templates 必须使用已审批的四阶缩放模板")
    holding_rule = parameters.get("max_holding_seconds")
    if not isinstance(holding_rule, dict) or holding_rule.get("choices") != [
        21600,
        43200,
        64800,
        86400,
    ]:
        errors.append("max_holding_seconds 必须使用已审批的 6h/12h/18h/24h 选项")
    template_rule = parameters.get("exit_policy_template")
    if not isinstance(template_rule, dict) or template_rule.get("choices") != [
        "FOUR_STAGE_SCALED_REMAINING_V1"
    ]:
        errors.append("exit_policy_template 必须绑定已审批的四阶缩放模板")


def _strictly_increasing(values: list[Any]) -> bool:
    return bool(values) and all(
        _is_number(value) and (index == 0 or value > values[index - 1])
        for index, value in enumerate(values)
    )


def _validate_v2_exit_rules(payload: dict[str, Any], errors: list[str]) -> None:
    expected = {
        "model_family",
        "return_basis",
        "initial_stop_loss_percent",
        "partial_take_profit",
        "stop_schedule",
        "max_holding_seconds",
        "intrabar_conflict_policy",
        "rule_activation_timing",
    }
    if set(payload) != expected:
        errors.append("RULE_BASED_EXIT_V2 字段集合不符合治理契约")
    if payload.get("return_basis") != "ENTRY_FILL_PRICE_PERCENT":
        errors.append("return_basis 必须为 ENTRY_FILL_PRICE_PERCENT")
    _number_at_least(payload, "initial_stop_loss_percent", 0, errors, strict=True)
    partial = payload.get("partial_take_profit")
    if not isinstance(partial, dict):
        errors.append("partial_take_profit 必须是对象")
    else:
        if partial.get("fraction_basis") != "REMAINING_POSITION":
            errors.append("fraction_basis 必须为 REMAINING_POSITION")
        levels = partial.get("levels")
        if not isinstance(levels, list) or len(levels) != 4:
            errors.append("partial_take_profit.levels 必须包含四个阶梯")
        else:
            triggers = [
                level.get("trigger_profit_percent") for level in levels if isinstance(level, dict)
            ]
            fractions = [level.get("close_fraction") for level in levels if isinstance(level, dict)]
            if len(triggers) != len(levels) or not _strictly_increasing(triggers):
                errors.append("部分止盈触发收益必须严格递增")
            if len(fractions) != len(levels) or any(
                not _is_number(value) or not 0 < value < 1 for value in fractions
            ):
                errors.append("每档 close_fraction 必须在 0 和 1 之间")
    schedule = payload.get("stop_schedule")
    if not isinstance(schedule, dict):
        errors.append("stop_schedule 必须是对象")
    else:
        levels = schedule.get("levels")
        if not isinstance(levels, list) or len(levels) != 4:
            errors.append("stop_schedule.levels 必须包含四个阶梯")
        else:
            triggers = [
                level.get("trigger_profit_percent") for level in levels if isinstance(level, dict)
            ]
            locked = [
                level.get("locked_profit_percent") for level in levels if isinstance(level, dict)
            ]
            if len(triggers) != len(levels) or not _strictly_increasing(triggers):
                errors.append("移动止损触发收益必须严格递增")
            locked_valid = len(locked) == len(levels)
            previous: int | float | Decimal | None = None
            for index, value in enumerate(locked):
                trigger = triggers[index] if index < len(triggers) else None
                if (
                    not _is_number(value)
                    or not _is_number(trigger)
                    or value < 0
                    or value >= trigger
                    or (previous is not None and value < previous)
                ):
                    locked_valid = False
                    break
                previous = value
            if not locked_valid:
                errors.append("锁定收益必须非负、不可回退且低于对应触发收益")
        activation = schedule.get("high_water_trailing_activation_percent")
        drawdown = schedule.get("high_water_max_drawdown_percent")
        if (
            not _is_number(activation)
            or not _is_number(drawdown)
            or drawdown <= 0
            or activation <= drawdown
        ):
            errors.append("最高水位启动值必须大于正的最大回撤值")
    if payload.get("rule_activation_timing") != "NEXT_BAR":
        errors.append("rule_activation_timing 必须为 NEXT_BAR")


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
    elif config_type == "MODEL_B_SEARCH_SPACE":
        if payload.get("model_family") != "RULE_BASED_EXIT_V2":
            errors.append("model_family 必须为 RULE_BASED_EXIT_V2")
        if payload.get("interval_seconds") != 300:
            errors.append("interval_seconds 必须为 300")
        if payload.get("hard_max_holding_seconds") != 86400:
            errors.append("hard_max_holding_seconds 必须为 86400")
        _validate_model_b_parameter_rules(payload, errors)
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
    elif config_type == "TICKER_POOL_RULES":
        for key in ("policy_name", "source", "ranking_type", "required_contract_type"):
            value = payload.get(key)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{key} 必须是非空字符串")
        lag_days = payload.get("as_of_lag_days")
        if not isinstance(lag_days, int) or isinstance(lag_days, bool) or lag_days < 0:
            errors.append("as_of_lag_days 必须是非负整数")
        top_n = payload.get("top_n")
        if not isinstance(top_n, int) or isinstance(top_n, bool) or not 1 <= top_n <= 50:
            errors.append("top_n 必须是 1 到 50 的整数 (当前排名契约上限为 50)")
        excluded = payload.get("excluded_symbols")
        if not isinstance(excluded, list) or any(
            not isinstance(symbol, str) or not symbol.strip() for symbol in excluded
        ):
            errors.append("excluded_symbols 必须是字符串数组")
    elif config_type == "ELIGIBLE_POOL_RULES":
        _number_at_least(payload, "minimum_listing_age_seconds", 0, errors)
        _number_at_least(payload, "minimum_notional_volume", 0, errors, strict=True)
        _number_at_least(
            payload,
            "inferred_trading_minimum_notional_volume",
            0,
            errors,
            strict=True,
        )
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
    elif config_type == "EXIT_RULES":
        if payload.get("model_family") != "RULE_BASED_EXIT_V2":
            errors.append("model_family 必须为 RULE_BASED_EXIT_V2")
        else:
            _validate_v2_exit_rules(payload, errors)
        holding = payload.get("max_holding_seconds")
        if (
            not isinstance(holding, int)
            or isinstance(holding, bool)
            or holding <= 0
            or holding > 86400
            or holding % 300 != 0
        ):
            errors.append("max_holding_seconds 必须按 5m 对齐且不超过 24h")
        if payload.get("intrabar_conflict_policy") != "WORST_CASE":
            errors.append("intrabar_conflict_policy 必须为 WORST_CASE")
    elif config_type == "SCORING_MODEL_B":
        if payload.get("calculation_version") != "EXIT_NET_EXPECTANCY_V1":
            errors.append("calculation_version 必须为 EXIT_NET_EXPECTANCY_V1")
        if payload.get("primary_metric") != "NET_EXPECTANCY_PERCENTAGE_POINTS":
            errors.append("primary_metric 必须为 NET_EXPECTANCY_PERCENTAGE_POINTS")
        if payload.get("cluster_unit") != "UTC_DAY":
            errors.append("cluster_unit 必须为 UTC_DAY")
        if payload.get("bootstrap_method") != "BCA_CLUSTER_BOOTSTRAP":
            errors.append("bootstrap_method 必须为 BCA_CLUSTER_BOOTSTRAP")
        _positive_integer(payload, "bootstrap_replicates", errors)
        confidence = payload.get("confidence_level")
        if not _is_number(confidence) or not 0 < confidence < 1:
            errors.append("confidence_level 必须在 0 和 1 之间")
        multipliers = payload.get("cost_stress_multipliers")
        if (
            not isinstance(multipliers, list)
            or any(not _is_number(value) or value < 1 for value in multipliers)
            or 2.0 not in multipliers
        ):
            errors.append("cost_stress_multipliers 必须包含 2.0 且所有值不小于 1")
    elif config_type == "MODEL_B_SAMPLE_MIX":
        expected_sources = {
            "natural_frequency_source": "CROSS_FIT_MODEL_A",
            "control_source": "ADVERSE_OR_RANGE_CONTROL",
            "oracle_source": "ORACLE_ENTRY_BENCHMARK",
        }
        for key, expected in expected_sources.items():
            if payload.get(key) != expected:
                errors.append(f"{key} 必须为 {expected}")
        _number_at_least(payload, "natural_frequency_weight", 0, errors, strict=True)
        _number_at_least(payload, "control_weight", 0, errors)
        if payload.get("oracle_weight") != 0:
            errors.append("oracle_weight 必须固定为 0")
        seed = payload.get("random_seed")
        if not isinstance(seed, int) or isinstance(seed, bool):
            errors.append("random_seed 必须是整数")
    elif config_type == "PORTFOLIO_RULES":
        _number_at_least(payload, "initial_capital", 0, errors, strict=True)
        _number_at_least(payload, "notional_per_trade", 0, errors, strict=True)
        _positive_integer(payload, "maximum_concurrent_positions", errors)
        if payload.get("same_ticker_position_policy") != "ONE_OPEN_POSITION":
            errors.append("same_ticker_position_policy 必须为 ONE_OPEN_POSITION")

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
    model_b_required_types: tuple[str, ...]
    model_b_missing_ready_types: tuple[str, ...]
    model_b_ready_complete: bool
    draft_templates: dict[str, dict[str, Any]]
    draft_schema_versions: dict[str, int]
    can_edit: bool
    can_approve: bool
    versions: tuple[ConfigVersion, ...]


def _build_ready_export(
    versions: tuple[ConfigVersion, ...], *, exported_by: str, generated_at: datetime
) -> dict[str, Any]:
    def optional_timestamp(value: datetime | None) -> str | None:
        return value.isoformat() if value else None

    ready_by_type: dict[str, ConfigVersion] = {}
    for version in versions:
        if version.status == "READY":
            ready_by_type.setdefault(version.config_type, version)
    missing = tuple(
        config_type
        for config_type in INITIAL_MODEL_A_CONFIG_TYPES
        if config_type not in ready_by_type
    )
    configs = [
        {
            "config_type": config_type,
            "label": ready_by_type[config_type].label,
            "config_version_id": str(ready_by_type[config_type].config_version_id),
            "semver": ready_by_type[config_type].semver,
            "schema_version": ready_by_type[config_type].schema_version,
            "content_hash": ready_by_type[config_type].content_hash,
            "parent_version_id": (
                str(ready_by_type[config_type].parent_version_id)
                if ready_by_type[config_type].parent_version_id
                else None
            ),
            "config_json": ready_by_type[config_type].config_json,
            "created_by": ready_by_type[config_type].created_by,
            "created_at": ready_by_type[config_type].created_at.isoformat(),
            "ready_by": ready_by_type[config_type].ready_by,
            "ready_at": optional_timestamp(ready_by_type[config_type].ready_at),
        }
        for config_type in INITIAL_MODEL_A_CONFIG_TYPES
        if config_type in ready_by_type
    ]
    manifest_payload = {
        "scope": "INITIAL_MODEL_A_READY",
        "required_types": list(INITIAL_MODEL_A_CONFIG_TYPES),
        "configs": configs,
    }
    manifest_hash = hashlib.sha256(
        json.dumps(
            manifest_payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return {
        "export_schema_version": 1,
        "scope": "INITIAL_MODEL_A_READY",
        "generated_at": generated_at.astimezone(UTC).isoformat(),
        "exported_by": exported_by,
        "ready_complete": not missing,
        "required_types": list(INITIAL_MODEL_A_CONFIG_TYPES),
        "missing_ready_types": list(missing),
        "config_count": len(configs),
        "manifest_hash_algorithm": "SHA-256",
        "manifest_hash": manifest_hash,
        "configs": configs,
    }


def _is_model_b_ready(version: ConfigVersion) -> bool:
    if version.status != "READY":
        return False
    if version.config_type not in {"EXIT_RULES", "MODEL_B_SEARCH_SPACE"}:
        return True
    return (
        version.schema_version == 2
        and version.config_json.get("model_family") == "RULE_BASED_EXIT_V2"
    )


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
    values = dict(row)
    payload = dict(values["config_json"])
    values["config_json"] = payload
    return ConfigVersion(
        **values,
        label=CONFIG_LABELS.get(str(row["config_type"]), str(row["config_type"])),
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
    if "training_config_versions_config_type_semver_key" in message:
        return HTTPException(
            status_code=409,
            detail="该配置类型的 SemVer 已存在; 已退役版本的版本号也不能复用, 请提高版本号后重试",
        )
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
    model_b_ready_types = {
        version.config_type for version in versions if _is_model_b_ready(version)
    }
    model_b_missing = tuple(
        item for item in INITIAL_MODEL_B_CONFIG_TYPES if item not in model_b_ready_types
    )
    return ConfigInventory(
        required_types=INITIAL_MODEL_A_CONFIG_TYPES,
        missing_ready_types=missing,
        ready_complete=not missing,
        model_b_required_types=INITIAL_MODEL_B_CONFIG_TYPES,
        model_b_missing_ready_types=model_b_missing,
        model_b_ready_complete=not model_b_missing,
        draft_templates=MODEL_B_DRAFT_TEMPLATES,
        draft_schema_versions=MODEL_B_DRAFT_SCHEMA_VERSIONS,
        can_edit="TRAINING_RESEARCHER" in roles,
        can_approve="TRAINING_ADMIN" in roles,
        versions=versions,
    )


@router.get("/export")
async def export_ready_configs(request: Request, user: ConfigReader) -> JSONResponse:
    try:
        async with request.app.state.database_engine.connect() as connection:
            rows = (
                (
                    await connection.execute(
                        text(
                            _CONFIG_SELECT
                            + " WHERE config.status = 'READY' "
                            + " ORDER BY config.config_type, config.created_at DESC"
                        )
                    )
                )
                .mappings()
                .all()
            )
    except SQLAlchemyError as error:
        raise HTTPException(status_code=503, detail="READY 配置导出失败") from error
    generated_at = datetime.now(UTC)
    payload = _build_ready_export(
        tuple(_row_to_version(row) for row in rows),
        exported_by=user.email,
        generated_at=generated_at,
    )
    filename = f"training-ready-configs-{generated_at.strftime('%Y%m%dT%H%M%SZ')}.json"
    return JSONResponse(
        content=payload,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
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
