from __future__ import annotations

import json
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_a_pipeline import AdaptedModelASignal, FactorSnapshot


def _json_text(value: object) -> str:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
        allow_nan=False,
    )


class DatabaseModelAFeatureStore:
    """Persist governed Model-A discovery entries through worker procedures."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def record_signal(self, adapted: AdaptedModelASignal) -> str:
        event = adapted.event
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.create_training_entry_event(
                    :entry_event_id, :dataset_version_id,
                    :generating_iteration_id, :instrument_id, :symbol,
                    :signal_time, :entry_time, :direction, :trigger_score,
                    :coverage_percent, :theoretical_signal_price,
                    :entry_price, :pool_evaluation_id,
                    :ticker_pool_rule_version_id, :factor_registry_version_id,
                    :scan_parameters_version_id, :signal_payload_hash
                )
                """
            ),
            {
                "entry_event_id": event.entry_event_id,
                "dataset_version_id": event.dataset_version_id,
                "generating_iteration_id": event.generating_version_id,
                "instrument_id": event.instrument_id,
                "symbol": event.symbol,
                "signal_time": event.signal_time,
                "entry_time": event.entry_time,
                "direction": event.direction.value,
                "trigger_score": event.trigger_score,
                "coverage_percent": event.coverage_percent,
                "theoretical_signal_price": event.theoretical_signal_price,
                "entry_price": event.entry_price,
                "pool_evaluation_id": event.pool_evaluation_id,
                "ticker_pool_rule_version_id": event.ticker_pool_rule_version_id,
                "factor_registry_version_id": event.factor_registry_version_id,
                "scan_parameters_version_id": event.scan_parameters_version_id,
                "signal_payload_hash": event.signal_payload_hash,
            },
        )
        persisted_id = str(result.scalar_one())
        for snapshot in adapted.factors:
            await self._record_factor(snapshot, event.factor_registry_version_id)
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_entry_event(
                    :entry_event_id
                )
                """
            ),
            {"entry_event_id": persisted_id},
        )
        return persisted_id

    async def record_candidate_signal(
        self, adapted: AdaptedModelASignal, *, task_id: UUID, lease_token: UUID
    ) -> str:
        event = adapted.event
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.create_training_candidate_entry_event(
                    :task_id, :lease_token, :entry_event_id, :dataset_version_id,
                    :generating_iteration_id, :instrument_id, :symbol,
                    :signal_time, :entry_time, :direction, :trigger_score,
                    :coverage_percent, :theoretical_signal_price,
                    :entry_price, :pool_evaluation_id,
                    :ticker_pool_rule_version_id, :factor_registry_version_id,
                    :scan_parameters_version_id, :signal_payload_hash
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": event.entry_event_id,
                "dataset_version_id": event.dataset_version_id,
                "generating_iteration_id": event.generating_version_id,
                "instrument_id": event.instrument_id,
                "symbol": event.symbol,
                "signal_time": event.signal_time,
                "entry_time": event.entry_time,
                "direction": event.direction.value,
                "trigger_score": event.trigger_score,
                "coverage_percent": event.coverage_percent,
                "theoretical_signal_price": event.theoretical_signal_price,
                "entry_price": event.entry_price,
                "pool_evaluation_id": event.pool_evaluation_id,
                "ticker_pool_rule_version_id": event.ticker_pool_rule_version_id,
                "factor_registry_version_id": event.factor_registry_version_id,
                "scan_parameters_version_id": event.scan_parameters_version_id,
                "signal_payload_hash": event.signal_payload_hash,
            },
        )
        persisted_id = str(result.scalar_one())
        for snapshot in adapted.factors:
            await self._record_factor(snapshot, event.factor_registry_version_id)
        await self._connection.execute(
            text("SELECT strategy_training.finalize_training_entry_event(:entry_event_id)"),
            {"entry_event_id": persisted_id},
        )
        return persisted_id

    async def record_cross_fit_prediction_signal(
        self, adapted: AdaptedModelASignal, *, task_id: UUID, lease_token: UUID
    ) -> str:
        event = adapted.event
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.create_cross_fit_prediction_entry_event(
                    :task_id, :lease_token, :entry_event_id, :dataset_version_id,
                    :generating_iteration_id, :instrument_id, :symbol,
                    :signal_time, :entry_time, :direction, :trigger_score,
                    :coverage_percent, :theoretical_signal_price,
                    :entry_price, :pool_evaluation_id,
                    :ticker_pool_rule_version_id, :factor_registry_version_id,
                    :scan_parameters_version_id, :signal_payload_hash
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": event.entry_event_id,
                "dataset_version_id": event.dataset_version_id,
                "generating_iteration_id": event.generating_version_id,
                "instrument_id": event.instrument_id,
                "symbol": event.symbol,
                "signal_time": event.signal_time,
                "entry_time": event.entry_time,
                "direction": event.direction.value,
                "trigger_score": event.trigger_score,
                "coverage_percent": event.coverage_percent,
                "theoretical_signal_price": event.theoretical_signal_price,
                "entry_price": event.entry_price,
                "pool_evaluation_id": event.pool_evaluation_id,
                "ticker_pool_rule_version_id": event.ticker_pool_rule_version_id,
                "factor_registry_version_id": event.factor_registry_version_id,
                "scan_parameters_version_id": event.scan_parameters_version_id,
                "signal_payload_hash": event.signal_payload_hash,
            },
        )
        persisted_id = str(result.scalar_one())
        for snapshot in adapted.factors:
            await self._record_factor(snapshot, event.factor_registry_version_id)
        await self._connection.execute(
            text("SELECT strategy_training.finalize_training_entry_event(:entry_event_id)"),
            {"entry_event_id": persisted_id},
        )
        return persisted_id

    async def _record_factor(
        self, snapshot: FactorSnapshot, factor_registry_version_id: UUID
    ) -> None:
        value_json = None if snapshot.value is None else _json_text(snapshot.value)
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_feature_snapshot(
                    :entry_event_id, :factor_registry_version_id,
                    :factor_name, :passed, :available,
                    CAST(:value_json AS jsonb), :threshold, :reason,
                    CAST(:metrics_json AS jsonb), :score, :weight,
                    :contribution, :input_fingerprint
                )
                """
            ),
            {
                "entry_event_id": snapshot.entry_event_id,
                "factor_registry_version_id": factor_registry_version_id,
                "factor_name": snapshot.factor_name,
                "passed": snapshot.passed,
                "available": snapshot.available,
                "value_json": value_json,
                "threshold": snapshot.threshold,
                "reason": snapshot.reason,
                "metrics_json": _json_text(snapshot.metrics),
                "score": snapshot.score,
                "weight": snapshot.weight,
                "contribution": snapshot.contribution,
                "input_fingerprint": snapshot.input_fingerprint,
            },
        )
