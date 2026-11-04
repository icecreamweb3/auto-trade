from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from datetime import datetime, timedelta
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.contracts import Partition, PartitionKind
from auto_trade.training.dataset_builder import (
    DatasetBuildError,
    DatasetBuildSpec,
    DependencyQualityReport,
    HistoricalPoolFact,
    ReadyConfigBinding,
    ResourceEstimate,
    ResourceLimits,
    ResourcePreflight,
    SourceShard,
)
from auto_trade.training.dataset_lifecycle import DatasetManifestSpec


def _json_text(value: object) -> str:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
        allow_nan=False,
    )


class DatabaseDatasetAuditStore:
    """Persist M2 facts only through the least-privilege database procedures."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_audit_context(
        self, dataset_version_id: UUID
    ) -> tuple[
        DatasetBuildSpec,
        tuple[ReadyConfigBinding, ...],
        UUID,
        UUID,
        ResourceLimits,
    ]:
        dataset_result = await self._connection.execute(
            text(
                """
                SELECT partition, partition_start_at, partition_end_at,
                       interval_seconds, warmup_start_at, eligible_start_at,
                       eligible_end_at, label_window_end_at, source_as_of_at,
                       visibility_cutoff_at, label_horizon_duration,
                       max_holding_duration, purge_duration, embargo_duration,
                       data_quality_rule_version_id, status
                FROM strategy_training.training_dataset_versions
                WHERE dataset_version_id = :dataset_version_id
                """
            ),
            {"dataset_version_id": dataset_version_id},
        )
        row = dataset_result.mappings().one_or_none()
        if row is None:
            raise DatasetBuildError("dataset version does not exist")
        if row["status"] != "BUILDING":
            raise DatasetBuildError("DATASET_BUILD requires a BUILDING dataset")

        binding_result = await self._connection.execute(
            text(
                """
                SELECT binding.config_type, binding.config_version_id,
                       config.status, config.config_json
                FROM strategy_training.training_dataset_config_bindings binding
                JOIN strategy_training.training_config_versions config
                  ON config.config_version_id = binding.config_version_id
                WHERE binding.dataset_version_id = :dataset_version_id
                ORDER BY binding.config_type
                """
            ),
            {"dataset_version_id": dataset_version_id},
        )
        binding_rows = binding_result.mappings().all()
        bindings = tuple(
            ReadyConfigBinding(
                str(binding["config_type"]),
                cast(UUID, binding["config_version_id"]),
                str(binding["status"]),
            )
            for binding in binding_rows
        )
        resource_rows = [
            binding for binding in binding_rows if binding["config_type"] == "RESOURCE_LIMITS"
        ]
        if len(resource_rows) != 1:
            raise DatasetBuildError("dataset requires exactly one RESOURCE_LIMITS binding")
        resource_row = resource_rows[0]
        spec = DatasetBuildSpec(
            partition=Partition(
                PartitionKind(str(row["partition"])),
                cast(datetime, row["partition_start_at"]),
                cast(datetime, row["partition_end_at"]),
            ),
            interval_seconds=int(row["interval_seconds"]),
            warmup_start_at=cast(datetime, row["warmup_start_at"]),
            eligible_start_at=cast(datetime, row["eligible_start_at"]),
            eligible_end_at=cast(datetime, row["eligible_end_at"]),
            label_window_end_at=cast(datetime, row["label_window_end_at"]),
            source_as_of_at=cast(datetime, row["source_as_of_at"]),
            visibility_cutoff_at=cast(datetime, row["visibility_cutoff_at"]),
            label_horizon=cast(timedelta, row["label_horizon_duration"]),
            max_holding_horizon=cast(timedelta, row["max_holding_duration"]),
            purge_duration=cast(timedelta, row["purge_duration"]),
            embargo_duration=cast(timedelta, row["embargo_duration"]),
        )
        return (
            spec,
            bindings,
            cast(UUID, resource_row["config_version_id"]),
            cast(UUID, row["data_quality_rule_version_id"]),
            ResourceLimits.from_config(cast(Mapping[str, object], resource_row["config_json"])),
        )

    async def historical_pool(
        self, dataset_version_id: UUID, evaluation_at: datetime
    ) -> tuple[HistoricalPoolFact, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT instrument_id, symbol, evaluation_at, onboard_at,
                       contract_identity, exchange_status, system_status,
                       status_effective_at, status_payload_hash,
                       observed_quote_notional, liquidity_observed_at,
                       liquidity_revision_hash, is_eligible, rejection_codes
                FROM strategy_training.historical_instrument_universe(
                    :dataset_version_id, :evaluation_at
                )
                ORDER BY symbol, instrument_id
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "evaluation_at": evaluation_at,
            },
        )
        facts: list[HistoricalPoolFact] = []
        for raw_row in result.mappings().all():
            row = cast(Mapping[str, object], raw_row)
            rejection_codes = cast(Sequence[object], row["rejection_codes"])
            facts.append(
                HistoricalPoolFact(
                    instrument_id=int(cast(int, row["instrument_id"])),
                    symbol=str(row["symbol"]),
                    evaluation_at=cast(datetime, row["evaluation_at"]),
                    is_eligible=bool(row["is_eligible"]),
                    rejection_codes=tuple(str(value) for value in rejection_codes),
                    onboard_at=cast(datetime | None, row["onboard_at"]),
                    contract_identity=str(row["contract_identity"]),
                    exchange_status=(
                        str(row["exchange_status"]) if row["exchange_status"] is not None else None
                    ),
                    system_status=(
                        str(row["system_status"]) if row["system_status"] is not None else None
                    ),
                    status_effective_at=cast(datetime | None, row["status_effective_at"]),
                    status_payload_hash=(
                        str(row["status_payload_hash"])
                        if row["status_payload_hash"] is not None
                        else None
                    ),
                    observed_quote_notional=(
                        Decimal(str(row["observed_quote_notional"]))
                        if row["observed_quote_notional"] is not None
                        else None
                    ),
                    liquidity_observed_at=cast(datetime | None, row["liquidity_observed_at"]),
                    liquidity_revision_hash=(
                        str(row["liquidity_revision_hash"])
                        if row["liquidity_revision_hash"] is not None
                        else None
                    ),
                )
            )
        return tuple(facts)

    async def record_historical_pool(
        self, dataset_version_id: UUID, facts: Sequence[HistoricalPoolFact]
    ) -> None:
        statement = text(
            """
            SELECT strategy_training.record_historical_pool_evaluation(
                :dataset_version_id, :instrument_id, :symbol, :evaluation_at,
                :onboard_at, :contract_identity, :exchange_status, :system_status,
                :status_effective_at, :status_payload_hash,
                :observed_quote_notional, :liquidity_observed_at,
                :liquidity_revision_hash, :is_eligible,
                CAST(:rejection_codes AS jsonb), CAST(:evidence AS jsonb)
            )
            """
        )
        for fact in facts:
            evidence = {
                "evaluation_at": fact.evaluation_at.isoformat(),
                "liquidity_revision_hash": fact.liquidity_revision_hash,
                "rejection_codes": fact.rejection_codes,
                "status_policy": "HISTORICAL_EXCHANGE_STATUS_OR_KLINE_24H_VOLUME_V1",
                "status_payload_hash": fact.status_payload_hash,
                "symbol": fact.symbol,
            }
            await self._connection.execute(
                statement,
                {
                    "dataset_version_id": dataset_version_id,
                    "instrument_id": fact.instrument_id,
                    "symbol": fact.symbol,
                    "evaluation_at": fact.evaluation_at,
                    "onboard_at": fact.onboard_at,
                    "contract_identity": fact.contract_identity,
                    "exchange_status": fact.exchange_status,
                    "system_status": fact.system_status,
                    "status_effective_at": fact.status_effective_at,
                    "status_payload_hash": fact.status_payload_hash,
                    "observed_quote_notional": fact.observed_quote_notional,
                    "liquidity_observed_at": fact.liquidity_observed_at,
                    "liquidity_revision_hash": fact.liquidity_revision_hash,
                    "is_eligible": fact.is_eligible,
                    "rejection_codes": _json_text(fact.rejection_codes),
                    "evidence": _json_text(evidence),
                },
            )

    async def record_resource_preflight(
        self,
        dataset_version_id: UUID,
        limits_config_version_id: UUID,
        estimate: ResourceEstimate,
        preflight: ResourcePreflight,
    ) -> None:
        evidence = {
            "estimate": {
                "available_temp_bytes": estimate.available_temp_bytes,
                "candidate_count": estimate.candidate_count,
                "cpu": str(estimate.cpu),
                "db_workers": estimate.db_workers,
                "decision_row_count": estimate.decision_row_count,
                "memory_bytes": estimate.memory_bytes,
                "pool_connections": estimate.pool_connections,
                "signal_count": estimate.signal_count,
                "statement_seconds": estimate.statement_seconds,
                "storage_bytes": estimate.storage_bytes,
                "temp_bytes": estimate.temp_bytes,
                "work_mem_bytes": estimate.work_mem_bytes,
            },
            "status": preflight.status.value,
        }
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_resource_preflight(
                    :dataset_version_id, :config_version_id,
                    :candidate_count, :signal_count, :decision_row_count,
                    :storage_bytes, :db_workers, :pool_connections,
                    :statement_seconds, :work_mem_bytes, :cpu, :memory_bytes,
                    :temp_bytes, :available_temp_bytes, :status,
                    CAST(:blocking_reasons AS jsonb), CAST(:evidence AS jsonb)
                )
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "config_version_id": limits_config_version_id,
                "candidate_count": estimate.candidate_count,
                "signal_count": estimate.signal_count,
                "decision_row_count": estimate.decision_row_count,
                "storage_bytes": estimate.storage_bytes,
                "db_workers": estimate.db_workers,
                "pool_connections": estimate.pool_connections,
                "statement_seconds": estimate.statement_seconds,
                "work_mem_bytes": estimate.work_mem_bytes,
                "cpu": estimate.cpu,
                "memory_bytes": estimate.memory_bytes,
                "temp_bytes": estimate.temp_bytes,
                "available_temp_bytes": estimate.available_temp_bytes,
                "status": preflight.status.value,
                "blocking_reasons": _json_text(preflight.blocking_reasons),
                "evidence": _json_text(evidence),
            },
        )

    async def record_source_shard(self, dataset_version_id: UUID, shard: SourceShard) -> None:
        if shard.source_table != "klines" or shard.instrument_id is None:
            raise DatasetBuildError(
                "database-backed source shards require a governed Kline instrument_id"
            )
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_kline_dataset_member(
                    :dataset_version_id, :instrument_id,
                    :member_start_at, :member_end_at
                )
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "instrument_id": shard.instrument_id,
                "member_start_at": shard.member_start_at,
                "member_end_at": shard.member_end_at,
            },
        )

    async def kline_source_shard(
        self,
        dataset_version_id: UUID,
        instrument_id: int,
        member_start_at: datetime,
        member_end_at: datetime,
    ) -> SourceShard:
        result = await self._connection.execute(
            text(
                """
                SELECT source_schema, source_table, source_shard_identity,
                       member_start_at, member_end_at, source_revision_watermark,
                       member_hash, shard_fingerprint, normalized_query_hash,
                       row_count
                FROM strategy_training.training_kline_source_shard(
                    :dataset_version_id, :instrument_id,
                    :member_start_at, :member_end_at
                )
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "instrument_id": instrument_id,
                "member_start_at": member_start_at,
                "member_end_at": member_end_at,
            },
        )
        raw_row = result.mappings().one_or_none()
        if raw_row is None:
            raise DatasetBuildError("governed Kline shard contains no visible valid rows")
        row = cast(Mapping[str, object], raw_row)
        return SourceShard(
            source_schema=str(row["source_schema"]),
            source_table=str(row["source_table"]),
            source_shard_identity=str(row["source_shard_identity"]),
            member_start_at=cast(datetime, row["member_start_at"]),
            member_end_at=cast(datetime, row["member_end_at"]),
            source_revision_watermark=cast(Mapping[str, object], row["source_revision_watermark"]),
            row_count=int(cast(int, row["row_count"])),
            normalized_query_hash=str(row["normalized_query_hash"]),
            content_hash=str(row["member_hash"]),
            instrument_id=instrument_id,
            recorded_shard_fingerprint=str(row["shard_fingerprint"]),
        )

    async def record_quality_report(
        self,
        dataset_version_id: UUID,
        data_quality_rule_version_id: UUID,
        dependency_kind: str,
        report: DependencyQualityReport,
    ) -> None:
        evidence = dict(report.evidence)
        evidence["blocking_reasons"] = report.blocking_reasons
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_quality_report(
                    :dataset_version_id, :rule_version_id, :dependency_name,
                    :dependency_kind, true, :coverage_ratio, :missing_ratio,
                    :warmup_complete, :effective_sample_count,
                    :effective_fold_count, :expected_row_count,
                    :observed_row_count, :missing_row_count, :status,
                    :blocking_reason, CAST(:evidence AS jsonb)
                )
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "rule_version_id": data_quality_rule_version_id,
                "dependency_name": report.dependency_name,
                "dependency_kind": dependency_kind,
                "coverage_ratio": report.coverage_ratio,
                "missing_ratio": report.missing_ratio,
                "warmup_complete": report.warmup_complete,
                "effective_sample_count": report.effective_sample_count,
                "effective_fold_count": report.effective_fold_count,
                "expected_row_count": report.expected_row_count,
                "observed_row_count": report.observed_row_count,
                "missing_row_count": report.missing_row_count,
                "status": report.status.value,
                "blocking_reason": (
                    ",".join(report.blocking_reasons) if report.blocking_reasons else None
                ),
                "evidence": _json_text(evidence),
            },
        )

    async def finalize_fingerprint(self, dataset_version_id: UUID) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_dataset_fingerprint(
                    :dataset_version_id
                )
                """
            ),
            {"dataset_version_id": dataset_version_id},
        )
        return str(result.scalar_one())


class DatabaseDatasetManifestStore:
    """Complete manifests using a least-privilege training-worker connection."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def complete_manifest(
        self, dataset_version_id: UUID, manifest: DatasetManifestSpec
    ) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.complete_training_dataset_manifest(
                    :dataset_version_id, :code_commit, :image_digest,
                    :python_version, :system_version, :dependency_lock_hash,
                    :database_migration_version,
                    CAST(:rule_and_scoring_versions AS jsonb), :random_seed,
                    :blas_thread_count, :openmp_thread_count, :cpu_count,
                    :worker_concurrency, :normalized_query_hash,
                    CAST(:input_hashes AS jsonb), CAST(:output_hashes AS jsonb),
                    :run_command
                )
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "code_commit": manifest.code_commit,
                "image_digest": manifest.image_digest,
                "python_version": manifest.python_version,
                "system_version": manifest.system_version,
                "dependency_lock_hash": manifest.dependency_lock_hash,
                "database_migration_version": manifest.database_migration_version,
                "rule_and_scoring_versions": _json_text(manifest.rule_and_scoring_versions),
                "random_seed": manifest.random_seed,
                "blas_thread_count": manifest.blas_thread_count,
                "openmp_thread_count": manifest.openmp_thread_count,
                "cpu_count": manifest.cpu_count,
                "worker_concurrency": manifest.worker_concurrency,
                "normalized_query_hash": manifest.normalized_query_hash,
                "input_hashes": _json_text(manifest.input_hashes),
                "output_hashes": _json_text(manifest.output_hashes),
                "run_command": manifest.run_command,
            },
        )
        return cast(UUID, result.scalar_one())


class DatabaseDatasetTransitionStore:
    """Run state changes using a separate orchestrator connection."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def transition_dataset(
        self,
        dataset_version_id: UUID,
        expected_state: str,
        new_state: str,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.transition_training_dataset(
                    :dataset_version_id, :expected_state, :new_state,
                    :actor_user_id, NULL, :reason, :request_id
                )
                """
            ),
            {
                "dataset_version_id": dataset_version_id,
                "expected_state": expected_state,
                "new_state": new_state,
                "actor_user_id": actor_user_id,
                "reason": reason,
                "request_id": request_id,
            },
        )

    async def mark_stale_for_replacement(
        self,
        stale_dataset_version_id: UUID,
        replacement_dataset_version_id: UUID,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.mark_training_dataset_stale_for_replacement(
                    :stale_dataset_version_id, :replacement_dataset_version_id,
                    :actor_user_id, :reason, :request_id
                )
                """
            ),
            {
                "stale_dataset_version_id": stale_dataset_version_id,
                "replacement_dataset_version_id": replacement_dataset_version_id,
                "actor_user_id": actor_user_id,
                "reason": reason,
                "request_id": request_id,
            },
        )
