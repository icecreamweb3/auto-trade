"""Governed out-of-fold Model-A prediction task."""

from __future__ import annotations

import json
from datetime import datetime, timedelta

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.strategies.feature_scan import evaluate_series
from auto_trade.training.cross_fit_prediction_repository import (
    DatabaseCrossFitPredictionStore,
)
from auto_trade.training.model_a_candidate_scan_repository import (
    PoolEvaluation,
    feature_bar_fingerprint,
)
from auto_trade.training.model_a_candidate_scan_task_handler import (
    build_candidate_strategy_parameters,
)
from auto_trade.training.model_a_pipeline import ModelAPipelineError, adapt_model_a_signal
from auto_trade.training.model_a_repository import DatabaseModelAFeatureStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.random_baseline_strata import compute_stratum, parse_strata_config


class CrossFitPredictionError(ModelAPipelineError):
    """The frozen outer-fold prediction cannot be reproduced safely."""


def _pool_at(
    evaluations: tuple[PoolEvaluation, ...], signal_time: datetime
) -> PoolEvaluation | None:
    selected = None
    for evaluation in evaluations:
        if evaluation.evaluation_at <= signal_time:
            selected = evaluation
        else:
            break
    if selected is None or signal_time >= selected.evaluation_at + timedelta(days=1):
        return None
    return selected


class CrossFitPredictionTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseCrossFitPredictionStore(connection)
        self._feature_store = DatabaseModelAFeatureStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.WORKER:
            raise CrossFitPredictionError("CROSS_FIT_PREDICT requires WORKER executor")
        if lease.payload != {"task_type": "CROSS_FIT_PREDICT", "payload_version": 1}:
            raise CrossFitPredictionError("CROSS_FIT_PREDICT requires exact v1 payload")

        context = await self._store.load_context(lease.task_id, lease.lease_token)
        if context.existing_batch_hash is not None:
            return context.existing_batch_hash
        parameters = build_candidate_strategy_parameters(context)
        persisted_ids: list[str] = []
        instruments = await self._store.load_instruments(
            lease.task_id, lease.lease_token
        )
        if not instruments:
            return await self._store.complete(
                lease.task_id, lease.lease_token, ()
            )
        random_baseline = await self._store.load_random_baseline_config(
            lease.task_id, lease.lease_token
        )
        if random_baseline.reference_dataset_version_id != context.dataset_version_id:
            raise CrossFitPredictionError(
                "Cross-fit prediction requires a same-dataset frozen baseline reference"
            )
        strata_config = parse_strata_config(
            random_baseline.config_version_id, random_baseline.config
        )
        benchmark_bars = await self._store.load_benchmark_bars(
            lease.task_id, lease.lease_token
        )
        if not benchmark_bars:
            raise CrossFitPredictionError("random-baseline benchmark history is empty")
        for instrument in instruments:
            bars = await self._store.load_bars(
                lease.task_id, lease.lease_token, instrument.instrument_id
            )
            if not bars:
                continue
            prediction_bars = tuple(
                bar for bar in bars if bar.open_time < context.eligible_end_at
            )
            entry_bars = {bar.open_time: bar for bar in bars}
            pools = await self._store.load_pool_evaluations(
                lease.task_id, lease.lease_token, instrument.instrument_id
            )
            input_fingerprint = feature_bar_fingerprint(
                context.dataset_root_fingerprint, prediction_bars
            )
            for signal in evaluate_series(
                instrument.symbol,
                prediction_bars,
                parameters,
                context.eligible_start_at,
            ):
                if not (
                    context.eligible_start_at
                    <= signal.open_time
                    < context.eligible_end_at
                ):
                    continue
                pool = _pool_at(pools, signal.open_time)
                entry_bar = entry_bars.get(
                    signal.open_time + timedelta(seconds=context.interval_seconds)
                )
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
                    factor_names=parameters.required_factors,
                )
                entry_event_id = (
                    await self._feature_store.record_cross_fit_prediction_signal(
                        adapted, task_id=lease.task_id, lease_token=lease.lease_token
                    )
                )
                persisted_ids.append(entry_event_id)
                stratum = compute_stratum(
                    observed_at=signal.open_time,
                    instrument_bars=bars,
                    benchmark_bars=benchmark_bars,
                    interval_seconds=context.interval_seconds,
                    config=strata_config,
                )
                evidence = dict(stratum.evidence)
                evidence.update(
                    {
                        "frame_kind": "CROSS_FIT_MATCHED_SIGNAL",
                        "trigger_reason": signal.trigger_reason,
                        "trigger_score": str(signal.score),
                    }
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
                    evidence_json=json.dumps(
                        evidence, sort_keys=True, separators=(",", ":"), default=str
                    ),
                )
                if len(persisted_ids) > context.maximum_signal_count:
                    raise CrossFitPredictionError(
                        "Cross-fit prediction signal count exceeds READY limit"
                    )
        return await self._store.complete(
            lease.task_id, lease.lease_token, tuple(sorted(persisted_ids))
        )
