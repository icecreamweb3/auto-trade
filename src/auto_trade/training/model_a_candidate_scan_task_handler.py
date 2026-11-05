"""Governed 5m in-sample Model-A candidate scan task."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import fields
from datetime import datetime, timedelta
from decimal import Decimal
from typing import cast

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.strategies.feature_scan import (
    StrategyEvaluation,
    StrategyParameters,
    evaluate_series,
)
from auto_trade.training.model_a_candidate_scan_repository import (
    CandidateScanContext,
    DatabaseModelACandidateScanStore,
    PoolEvaluation,
    feature_bar_fingerprint,
)
from auto_trade.training.model_a_pipeline import ModelAPipelineError, adapt_model_a_signal
from auto_trade.training.model_a_repository import DatabaseModelAFeatureStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.random_baseline_strata import (
    ComputedStratum,
    compute_stratum,
    parse_strata_config,
)


class ModelACandidateScanError(ModelAPipelineError):
    """The governed candidate scan cannot produce a trustworthy entry batch."""


def _mapping(value: object, field_name: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise ModelACandidateScanError(f"{field_name} must be an object")
    return cast(Mapping[str, object], value)


def build_candidate_strategy_parameters(context: CandidateScanContext) -> StrategyParameters:
    if context.interval_seconds != 300:
        raise ModelACandidateScanError("candidate scan v1 is restricted to governed 5m data")
    raw_base = _mapping(
        context.scan_parameters_config.get("strategy_parameters"),
        "SEARCH_SPACE.strategy_parameters",
    )
    values = dict(raw_base)
    values.update(context.candidate_parameters)
    allowed = {field.name for field in fields(StrategyParameters)}
    unexpected = sorted(set(values) - allowed)
    if unexpected:
        raise ModelACandidateScanError(
            "candidate contains unsupported strategy parameters: " + ", ".join(unexpected)
        )

    raw_factors = context.factor_registry_config.get("factors")
    if not isinstance(raw_factors, list) or not raw_factors or any(
        not isinstance(value, str) or not value.strip() for value in raw_factors
    ):
        raise ModelACandidateScanError("FACTOR_REGISTRY factors are invalid")
    registry_factors = tuple(cast(list[str], raw_factors))
    configured_factors = values.get("required_factors")
    if configured_factors is not None:
        if not isinstance(configured_factors, (list, tuple)) or tuple(
            cast(list[str] | tuple[str, ...], configured_factors)
        ) != registry_factors:
            raise ModelACandidateScanError("SEARCH_SPACE factors differ from FACTOR_REGISTRY")
    values["required_factors"] = registry_factors
    values["interval_seconds"] = context.interval_seconds

    defaults = StrategyParameters()
    for name, value in tuple(values.items()):
        if isinstance(getattr(defaults, name), Decimal):
            values[name] = Decimal(str(value))
    if "factor_weights" in values:
        values["factor_weights"] = {
            str(name): Decimal(str(weight))
            for name, weight in _mapping(values["factor_weights"], "factor_weights").items()
        }
    if "factor_parameters" in values:
        values["factor_parameters"] = {
            str(name): dict(_mapping(parameters, f"factor_parameters.{name}"))
            for name, parameters in _mapping(
                values["factor_parameters"], "factor_parameters"
            ).items()
        }
    try:
        return StrategyParameters(**values)  # type: ignore[arg-type]
    except (TypeError, ValueError) as error:
        raise ModelACandidateScanError("candidate strategy parameters are invalid") from error


def _pool_at(
    evaluations: tuple[PoolEvaluation, ...], signal_time: datetime
) -> PoolEvaluation | None:
    selected = None
    for evaluation in evaluations:
        if evaluation.evaluation_at <= signal_time:
            selected = evaluation
        else:
            break
    return selected


def _stratum_evidence(
    stratum: ComputedStratum, *, kind: str, score: Decimal, trigger_reason: str | None
) -> str:
    evidence = dict(stratum.evidence)
    evidence.update(
        {
            "frame_kind": kind,
            "trigger_reason": trigger_reason,
            "trigger_score": str(score),
        }
    )
    return json.dumps(evidence, sort_keys=True, separators=(",", ":"), default=str)


class ModelACandidateScanTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseModelACandidateScanStore(connection)
        self._feature_store = DatabaseModelAFeatureStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.WORKER:
            raise ModelACandidateScanError("MODEL_A_CANDIDATE_SCAN requires WORKER executor")
        if lease.payload != {"task_type": "MODEL_A_CANDIDATE_SCAN", "payload_version": 1}:
            raise ModelACandidateScanError("MODEL_A_CANDIDATE_SCAN requires exact v1 payload")
        context = await self._store.load_context(lease.task_id, lease.lease_token)
        if context.existing_batch_hash is not None:
            return context.existing_batch_hash
        parameters = build_candidate_strategy_parameters(context)
        raw_baseline = await self._store.load_random_baseline_config(
            lease.task_id, lease.lease_token
        )
        strata_config = parse_strata_config(
            raw_baseline.config_version_id, raw_baseline.config
        )
        benchmark_bars = await self._store.load_benchmark_bars(
            lease.task_id, lease.lease_token
        )
        if not benchmark_bars:
            raise ModelACandidateScanError("random-baseline benchmark history is empty")
        persisted_ids: list[str] = []
        frame_candidate_ids: list[str] = []
        for instrument in await self._store.load_instruments(
            lease.task_id, lease.lease_token
        ):
            bars = await self._store.load_bars(
                lease.task_id, lease.lease_token, instrument.instrument_id
            )
            if not bars:
                continue
            scan_bars = tuple(
                bar for bar in bars if bar.open_time < context.eligible_end_at
            )
            entry_bars = {bar.open_time: bar for bar in bars}
            input_fingerprint = feature_bar_fingerprint(
                context.dataset_root_fingerprint, bars
            )
            pools = await self._store.load_pool_evaluations(
                lease.task_id, lease.lease_token, instrument.instrument_id
            )
            evaluations: list[StrategyEvaluation] = []
            signals = evaluate_series(
                instrument.symbol,
                scan_bars,
                parameters,
                context.eligible_start_at,
                evaluation_callback=evaluations.append,
            )
            evaluation_by_time = {item.open_time: item for item in evaluations}
            for signal in signals:
                pool = _pool_at(pools, signal.open_time)
                entry_time = signal.open_time + timedelta(
                    seconds=parameters.interval_seconds
                )
                entry_bar = entry_bars.get(entry_time)
                if pool is None or entry_bar is None:
                    continue
                adapted = adapt_model_a_signal(
                    signal,
                    source=context.entry_source,
                    dataset_version_id=context.dataset_version_id,
                    generating_version_id=context.iteration_id,
                    instrument_id=instrument.instrument_id,
                    interval_seconds=context.interval_seconds,
                    pool_evaluation_id=pool.pool_evaluation_id,
                    ticker_pool_rule_version_id=context.ticker_pool_rule_version_id,
                    factor_registry_version_id=context.factor_registry_version_id,
                    scan_parameters_version_id=context.scan_parameters_version_id,
                    input_fingerprint=input_fingerprint,
                    entry_price=entry_bar.open_price,
                )
                entry_event_id = await self._feature_store.record_candidate_signal(
                    adapted, task_id=lease.task_id, lease_token=lease.lease_token
                )
                persisted_ids.append(entry_event_id)
                evaluation = evaluation_by_time[signal.open_time]
                stratum = compute_stratum(
                    observed_at=signal.open_time,
                    instrument_bars=bars,
                    benchmark_bars=benchmark_bars,
                    interval_seconds=context.interval_seconds,
                    config=strata_config,
                )
                await self._store.record_signal_stratum(
                    task_id=lease.task_id,
                    lease_token=lease.lease_token,
                    entry_event_id=entry_event_id,
                    config_version_id=strata_config.config_version_id,
                    volatility_bucket=stratum.volatility_bucket,
                    liquidity_bucket=stratum.liquidity_bucket,
                    btc_regime=stratum.btc_regime,
                    volatility_window_start_at=stratum.volatility_window_start_at,
                    liquidity_window_start_at=stratum.liquidity_window_start_at,
                    btc_regime_window_start_at=stratum.btc_regime_window_start_at,
                    evidence_json=_stratum_evidence(
                        stratum,
                        kind="MATCHED_SIGNAL",
                        score=evaluation.score,
                        trigger_reason=evaluation.trigger_reason,
                    ),
                )
                if len(persisted_ids) > context.maximum_signal_count:
                    raise ModelACandidateScanError("candidate signal count exceeds READY limit")
            for evaluation in evaluations:
                if (
                    not evaluation.candidate_triggered
                    or evaluation.score >= parameters.signal_score_threshold
                    or evaluation.coverage_percent
                    < parameters.minimum_data_coverage_percent
                ):
                    continue
                pool = _pool_at(pools, evaluation.open_time)
                entry_time = evaluation.open_time + timedelta(
                    seconds=parameters.interval_seconds
                )
                if pool is None or entry_bars.get(entry_time) is None:
                    continue
                stratum = compute_stratum(
                    observed_at=evaluation.open_time,
                    instrument_bars=bars,
                    benchmark_bars=benchmark_bars,
                    interval_seconds=context.interval_seconds,
                    config=strata_config,
                )
                frame_candidate_ids.append(
                    await self._store.record_random_candidate(
                        task_id=lease.task_id,
                        lease_token=lease.lease_token,
                        context=context,
                        instrument_id=instrument.instrument_id,
                        observed_at=evaluation.open_time,
                        pool_evaluation_id=pool.pool_evaluation_id,
                        config_version_id=strata_config.config_version_id,
                        trigger_score=evaluation.score,
                        signal_score_threshold=parameters.signal_score_threshold,
                        volatility_bucket=stratum.volatility_bucket,
                        liquidity_bucket=stratum.liquidity_bucket,
                        btc_regime=stratum.btc_regime,
                        volatility_window_start_at=stratum.volatility_window_start_at,
                        liquidity_window_start_at=stratum.liquidity_window_start_at,
                        btc_regime_window_start_at=stratum.btc_regime_window_start_at,
                        evidence_json=_stratum_evidence(
                            stratum,
                            kind="LOW_SCORE_CANDIDATE",
                            score=evaluation.score,
                            trigger_reason=evaluation.trigger_reason,
                        ),
                    )
                )
                if len(frame_candidate_ids) > strata_config.maximum_frame_candidates:
                    raise ModelACandidateScanError(
                        "random-baseline candidate frame exceeds READY limit"
                    )
        if not persisted_ids:
            raise ModelACandidateScanError("candidate emitted no governed entry signals")
        ordered_ids = tuple(sorted(persisted_ids))
        scan_result_hash = hashlib.sha256(
            json.dumps(
                {
                    "candidate_parameters": context.candidate_parameters,
                    "dataset_root_fingerprint": context.dataset_root_fingerprint,
                    "entry_event_ids": ordered_ids,
                    "random_baseline_candidate_ids": tuple(
                        sorted(frame_candidate_ids)
                    ),
                    "payload_version": 1,
                },
                sort_keys=True,
                separators=(",", ":"),
                default=str,
            ).encode()
        ).hexdigest()
        return await self._store.freeze_batch(
            lease.task_id, lease.lease_token, scan_result_hash
        )
