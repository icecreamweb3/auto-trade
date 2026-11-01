from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from enum import StrEnum
from typing import Protocol
from uuid import UUID

from auto_trade.training.contracts import Partition, PartitionKind, TrainingContractError

REQUIRED_DATASET_CONFIG_TYPES = frozenset(
    {
        "TICKER_POOL_RULES",
        "DATA_QUALITY_RULES",
        "HOLDING_HORIZON_RULES",
        "ELIGIBLE_POOL_RULES",
        "REPRODUCIBILITY_TOLERANCE",
        "RESOURCE_LIMITS",
        "FEE_MODEL",
        "SLIPPAGE_MODEL",
        "VISIBILITY_CUTOFF_POLICY",
    }
)


class DatasetBuildError(TrainingContractError):
    """A dataset build cannot produce governed facts."""


class MissingReadyConfigError(DatasetBuildError):
    """A required dataset configuration is absent or not READY."""


class QualityStatus(StrEnum):
    PASS = "PASS"
    WARN = "WARN"
    BLOCKED = "BLOCKED"


class PreflightStatus(StrEnum):
    PASS = "PASS"
    BLOCKED = "BLOCKED"


def _utc(value: datetime, field_name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise DatasetBuildError(f"{field_name} must be timezone-aware UTC")
    return value.astimezone(UTC)


def _positive_int(value: object, field_name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise DatasetBuildError(f"{field_name} must be an explicit positive integer")
    return value


def _positive_decimal(value: object, field_name: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal, str)):
        raise DatasetBuildError(f"{field_name} must be an explicit positive number")
    try:
        result = Decimal(str(value))
    except Exception as exc:  # pragma: no cover - Decimal error classes vary by input
        raise DatasetBuildError(f"{field_name} must be an explicit positive number") from exc
    if not result.is_finite() or result <= 0:
        raise DatasetBuildError(f"{field_name} must be an explicit positive number")
    return result


def canonical_json_hash(payload: object) -> str:
    encoded = json.dumps(
        payload,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True, slots=True)
class ReadyConfigBinding:
    config_type: str
    config_version_id: UUID
    status: str

    def __post_init__(self) -> None:
        config_type = self.config_type.strip().upper()
        if not config_type:
            raise DatasetBuildError("config_type must not be blank")
        object.__setattr__(self, "config_type", config_type)


def validate_ready_config_bindings(
    bindings: Sequence[ReadyConfigBinding],
) -> dict[str, UUID]:
    by_type: dict[str, UUID] = {}
    for binding in bindings:
        if binding.status != "READY":
            raise MissingReadyConfigError(
                f"config {binding.config_type} is {binding.status}, expected READY"
            )
        if binding.config_type in by_type:
            raise MissingReadyConfigError(f"duplicate config binding {binding.config_type}")
        by_type[binding.config_type] = binding.config_version_id
    missing = sorted(REQUIRED_DATASET_CONFIG_TYPES - by_type.keys())
    if missing:
        raise MissingReadyConfigError(f"missing READY configs: {', '.join(missing)}")
    return by_type


@dataclass(frozen=True, slots=True)
class DatasetBuildSpec:
    partition: Partition
    interval_seconds: int
    warmup_start_at: datetime
    eligible_start_at: datetime
    eligible_end_at: datetime
    label_window_end_at: datetime
    source_as_of_at: datetime
    visibility_cutoff_at: datetime
    label_horizon: timedelta
    max_holding_horizon: timedelta
    purge_duration: timedelta
    embargo_duration: timedelta

    def __post_init__(self) -> None:
        if self.partition.kind not in (PartitionKind.TRAIN, PartitionKind.VALIDATION):
            raise DatasetBuildError("main-schema datasets are limited to TRAIN/VALIDATION")
        if self.interval_seconds <= 0 or self.interval_seconds % 60:
            raise DatasetBuildError("interval_seconds must be a positive whole minute")
        for field_name in (
            "warmup_start_at",
            "eligible_start_at",
            "eligible_end_at",
            "label_window_end_at",
            "source_as_of_at",
            "visibility_cutoff_at",
        ):
            object.__setattr__(self, field_name, _utc(getattr(self, field_name), field_name))
        maximum_horizon = max(self.label_horizon, self.max_holding_horizon)
        if self.label_horizon <= timedelta(0) or self.max_holding_horizon <= timedelta(0):
            raise DatasetBuildError("label and holding horizons must be positive")
        if self.purge_duration < maximum_horizon:
            raise DatasetBuildError("purge_duration must cover the maximum horizon")
        if self.embargo_duration < maximum_horizon:
            raise DatasetBuildError("embargo_duration must cover the maximum horizon")
        if not (
            self.warmup_start_at <= self.eligible_start_at
            and self.partition.start_at
            <= self.eligible_start_at
            < self.eligible_end_at
            <= self.label_window_end_at
            <= self.partition.end_at
        ):
            raise DatasetBuildError("warmup/eligible/label boundaries are inconsistent")
        if self.label_window_end_at != self.eligible_end_at + self.label_horizon:
            raise DatasetBuildError(
                "label_window_end_at must equal eligible_end plus label horizon"
            )
        if self.eligible_end_at + maximum_horizon > self.partition.end_at:
            raise DatasetBuildError("eligible entries would cross the partition boundary")
        if self.source_as_of_at < self.partition.end_at:
            raise DatasetBuildError("source_as_of_at must freeze at or after partition_end")
        if self.visibility_cutoff_at > self.partition.start_at:
            raise DatasetBuildError("visibility_cutoff_at must not follow partition_start")

    def validate_evaluation_times(self, values: Sequence[datetime]) -> tuple[datetime, ...]:
        normalized = tuple(_utc(value, "evaluation_at") for value in values)
        if not normalized:
            raise DatasetBuildError("at least one historical evaluation time is required")
        if normalized != tuple(sorted(set(normalized))):
            raise DatasetBuildError("evaluation times must be unique and sorted")
        if any(
            value < self.eligible_start_at or value >= self.eligible_end_at for value in normalized
        ):
            raise DatasetBuildError("evaluation time is outside the eligible interval")
        return normalized


@dataclass(frozen=True, slots=True)
class SourceShard:
    source_schema: str
    source_table: str
    source_shard_identity: str
    member_start_at: datetime
    member_end_at: datetime
    source_revision_watermark: Mapping[str, object]
    row_count: int
    normalized_query_hash: str
    content_hash: str
    instrument_id: int | None = None
    recorded_shard_fingerprint: str | None = None

    def __post_init__(self) -> None:
        if self.source_schema != "market":
            raise DatasetBuildError("training source shards must come from market")
        if not self.source_table.strip() or not self.source_shard_identity.strip():
            raise DatasetBuildError("source table and shard identity are required")
        object.__setattr__(self, "member_start_at", _utc(self.member_start_at, "member_start_at"))
        object.__setattr__(self, "member_end_at", _utc(self.member_end_at, "member_end_at"))
        if self.member_start_at >= self.member_end_at:
            raise DatasetBuildError("member_start_at must precede member_end_at")
        if not self.source_revision_watermark:
            raise DatasetBuildError("source revision watermark must not be empty")
        if self.row_count <= 0:
            raise DatasetBuildError("source shard row_count must be positive")
        if self.instrument_id is not None and self.instrument_id <= 0:
            raise DatasetBuildError("instrument_id must be positive when provided")
        for field_name in ("normalized_query_hash", "content_hash"):
            value = getattr(self, field_name)
            if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
                raise DatasetBuildError(f"{field_name} must be a lowercase SHA-256")
        if self.recorded_shard_fingerprint is not None:
            value = self.recorded_shard_fingerprint
            if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
                raise DatasetBuildError("recorded_shard_fingerprint must be a lowercase SHA-256")

    @property
    def shard_fingerprint(self) -> str:
        if self.recorded_shard_fingerprint is not None:
            return self.recorded_shard_fingerprint
        return canonical_json_hash(
            {
                "content_hash": self.content_hash,
                "member_end_at": self.member_end_at.isoformat(),
                "member_start_at": self.member_start_at.isoformat(),
                "normalized_query_hash": self.normalized_query_hash,
                "row_count": self.row_count,
                "source_revision_watermark": self.source_revision_watermark,
                "source_schema": self.source_schema,
                "source_shard_identity": self.source_shard_identity,
                "source_table": self.source_table,
            }
        )


def build_member_manifest_hash(shards: Sequence[SourceShard]) -> str:
    if not shards:
        raise DatasetBuildError("dataset requires at least one source shard")
    identities = [
        (shard.source_schema, shard.source_table, shard.source_shard_identity) for shard in shards
    ]
    if len(identities) != len(set(identities)):
        raise DatasetBuildError("source shard identities must be unique")
    ordered = sorted(
        shards,
        key=lambda shard: (
            shard.source_schema,
            shard.source_table,
            shard.source_shard_identity,
        ),
    )
    return canonical_json_hash(
        [
            {
                "identity": shard.source_shard_identity,
                "shard_fingerprint": shard.shard_fingerprint,
                "source_schema": shard.source_schema,
                "source_table": shard.source_table,
            }
            for shard in ordered
        ]
    )


@dataclass(frozen=True, slots=True)
class SourceFreshnessAssessment:
    recorded_manifest_hash: str
    observed_manifest_hash: str
    changed_shard_identities: tuple[str, ...]

    @property
    def is_stale(self) -> bool:
        return self.recorded_manifest_hash != self.observed_manifest_hash


def assess_source_freshness(
    recorded_shards: Sequence[SourceShard],
    observed_shards: Sequence[SourceShard],
) -> SourceFreshnessAssessment:
    """Compare the immutable source view with a newly observed revision view."""

    recorded_by_identity = {
        (shard.source_schema, shard.source_table, shard.source_shard_identity): shard
        for shard in recorded_shards
    }
    observed_by_identity = {
        (shard.source_schema, shard.source_table, shard.source_shard_identity): shard
        for shard in observed_shards
    }
    # The manifest builders also enforce non-empty input and duplicate identities.
    recorded_hash = build_member_manifest_hash(recorded_shards)
    observed_hash = build_member_manifest_hash(observed_shards)
    all_identities = sorted(recorded_by_identity.keys() | observed_by_identity.keys())
    changed = tuple(
        identity[2]
        for identity in all_identities
        if recorded_by_identity.get(identity) != observed_by_identity.get(identity)
    )
    return SourceFreshnessAssessment(recorded_hash, observed_hash, changed)


@dataclass(frozen=True, slots=True)
class DependencyRequirement:
    dependency_name: str
    expected_row_count: int
    minimum_coverage: Decimal
    minimum_effective_samples: int
    minimum_effective_folds: int
    warmup_required: bool

    def __post_init__(self) -> None:
        if not self.dependency_name.strip():
            raise DatasetBuildError("dependency_name must not be blank")
        if self.expected_row_count <= 0:
            raise DatasetBuildError("expected_row_count must be positive")
        if not Decimal(0) <= self.minimum_coverage <= Decimal(1):
            raise DatasetBuildError("minimum_coverage must be between zero and one")
        if self.minimum_effective_samples < 0 or self.minimum_effective_folds < 0:
            raise DatasetBuildError("effective sample/fold requirements cannot be negative")


@dataclass(frozen=True, slots=True)
class DependencyObservation:
    observed_row_count: int
    missing_row_count: int
    warmup_complete: bool
    effective_sample_count: int
    effective_fold_count: int
    evidence: Mapping[str, object]

    def __post_init__(self) -> None:
        if (
            min(
                self.observed_row_count,
                self.missing_row_count,
                self.effective_sample_count,
                self.effective_fold_count,
            )
            < 0
        ):
            raise DatasetBuildError("dependency observation counts cannot be negative")
        if not self.evidence:
            raise DatasetBuildError("dependency evidence must not be empty")


@dataclass(frozen=True, slots=True)
class DependencyQualityReport:
    dependency_name: str
    coverage_ratio: Decimal
    missing_ratio: Decimal
    warmup_complete: bool
    effective_sample_count: int
    effective_fold_count: int
    expected_row_count: int
    observed_row_count: int
    missing_row_count: int
    status: QualityStatus
    blocking_reasons: tuple[str, ...]
    evidence: Mapping[str, object]


def audit_dependency(
    requirement: DependencyRequirement,
    observation: DependencyObservation | None,
) -> DependencyQualityReport:
    if observation is None:
        return DependencyQualityReport(
            dependency_name=requirement.dependency_name,
            coverage_ratio=Decimal(0),
            missing_ratio=Decimal(1),
            warmup_complete=False,
            effective_sample_count=0,
            effective_fold_count=0,
            expected_row_count=requirement.expected_row_count,
            observed_row_count=0,
            missing_row_count=requirement.expected_row_count,
            status=QualityStatus.BLOCKED,
            blocking_reasons=("DATA_DEPENDENCY_UNAVAILABLE",),
            evidence={"availability": "MISSING"},
        )
    if observation.observed_row_count + observation.missing_row_count != (
        requirement.expected_row_count
    ):
        raise DatasetBuildError("observed plus missing rows must equal expected rows")
    expected = Decimal(requirement.expected_row_count)
    coverage = Decimal(observation.observed_row_count) / expected
    missing = Decimal(observation.missing_row_count) / expected
    reasons: list[str] = []
    if coverage < requirement.minimum_coverage:
        reasons.append("COVERAGE_BELOW_CONFIGURED_MINIMUM")
    if requirement.warmup_required and not observation.warmup_complete:
        reasons.append("WARMUP_INCOMPLETE")
    if observation.effective_sample_count < requirement.minimum_effective_samples:
        reasons.append("EFFECTIVE_SAMPLE_COUNT_TOO_LOW")
    if observation.effective_fold_count < requirement.minimum_effective_folds:
        reasons.append("EFFECTIVE_FOLD_COUNT_TOO_LOW")
    return DependencyQualityReport(
        dependency_name=requirement.dependency_name,
        coverage_ratio=coverage,
        missing_ratio=missing,
        warmup_complete=observation.warmup_complete,
        effective_sample_count=observation.effective_sample_count,
        effective_fold_count=observation.effective_fold_count,
        expected_row_count=requirement.expected_row_count,
        observed_row_count=observation.observed_row_count,
        missing_row_count=observation.missing_row_count,
        status=QualityStatus.PASS if not reasons else QualityStatus.BLOCKED,
        blocking_reasons=tuple(reasons),
        evidence=observation.evidence,
    )


@dataclass(frozen=True, slots=True)
class ResourceLimits:
    db_workers_per_experiment: int
    pool_connections: int
    statement_timeout_seconds: int
    work_mem_bytes: int
    cpu_limit: Decimal
    memory_bytes: int
    temp_disk_min_free_bytes: int
    max_candidate_count: int
    max_signal_count: int
    max_decision_row_count: int
    max_storage_bytes: int

    @classmethod
    def from_config(cls, config: Mapping[str, object]) -> ResourceLimits:
        return cls(
            db_workers_per_experiment=_positive_int(
                config.get("db_workers_per_experiment"), "db_workers_per_experiment"
            ),
            pool_connections=_positive_int(config.get("pool_connections"), "pool_connections"),
            statement_timeout_seconds=_positive_int(
                config.get("statement_timeout_seconds"), "statement_timeout_seconds"
            ),
            work_mem_bytes=_positive_int(config.get("work_mem_bytes"), "work_mem_bytes"),
            cpu_limit=_positive_decimal(config.get("cpu_limit"), "cpu_limit"),
            memory_bytes=_positive_int(config.get("memory_bytes"), "memory_bytes"),
            temp_disk_min_free_bytes=_positive_int(
                config.get("temp_disk_min_free_bytes"), "temp_disk_min_free_bytes"
            ),
            max_candidate_count=_positive_int(
                config.get("max_candidate_count"), "max_candidate_count"
            ),
            max_signal_count=_positive_int(config.get("max_signal_count"), "max_signal_count"),
            max_decision_row_count=_positive_int(
                config.get("max_decision_row_count"), "max_decision_row_count"
            ),
            max_storage_bytes=_positive_int(config.get("max_storage_bytes"), "max_storage_bytes"),
        )


@dataclass(frozen=True, slots=True)
class ResourceEstimate:
    candidate_count: int
    signal_count: int
    decision_row_count: int
    storage_bytes: int
    db_workers: int
    pool_connections: int
    statement_seconds: int
    work_mem_bytes: int
    cpu: Decimal
    memory_bytes: int
    temp_bytes: int
    available_temp_bytes: int

    def __post_init__(self) -> None:
        count_fields = (
            self.candidate_count,
            self.signal_count,
            self.decision_row_count,
            self.storage_bytes,
            self.temp_bytes,
            self.available_temp_bytes,
        )
        if min(count_fields) < 0:
            raise DatasetBuildError("resource estimate counts/bytes cannot be negative")
        if (
            min(
                self.db_workers,
                self.pool_connections,
                self.statement_seconds,
                self.work_mem_bytes,
                self.memory_bytes,
            )
            <= 0
            or self.cpu <= 0
        ):
            raise DatasetBuildError("resource estimate execution values must be positive")


@dataclass(frozen=True, slots=True)
class ResourcePreflight:
    status: PreflightStatus
    blocking_reasons: tuple[str, ...]


def evaluate_resource_preflight(
    limits: ResourceLimits,
    estimate: ResourceEstimate,
) -> ResourcePreflight:
    checks = (
        (estimate.candidate_count > limits.max_candidate_count, "CANDIDATE_COUNT_EXCEEDED"),
        (estimate.signal_count > limits.max_signal_count, "SIGNAL_COUNT_EXCEEDED"),
        (
            estimate.decision_row_count > limits.max_decision_row_count,
            "DECISION_ROW_COUNT_EXCEEDED",
        ),
        (estimate.storage_bytes > limits.max_storage_bytes, "STORAGE_EXCEEDED"),
        (estimate.db_workers > limits.db_workers_per_experiment, "DB_WORKERS_EXCEEDED"),
        (estimate.pool_connections > limits.pool_connections, "POOL_CONNECTIONS_EXCEEDED"),
        (
            estimate.statement_seconds > limits.statement_timeout_seconds,
            "STATEMENT_TIMEOUT_EXCEEDED",
        ),
        (estimate.work_mem_bytes > limits.work_mem_bytes, "WORK_MEM_EXCEEDED"),
        (estimate.cpu > limits.cpu_limit, "CPU_EXCEEDED"),
        (estimate.memory_bytes > limits.memory_bytes, "MEMORY_EXCEEDED"),
        (
            estimate.available_temp_bytes - estimate.temp_bytes < limits.temp_disk_min_free_bytes,
            "TEMP_DISK_WATERMARK_EXCEEDED",
        ),
    )
    reasons = tuple(reason for blocked, reason in checks if blocked)
    return ResourcePreflight(
        status=PreflightStatus.BLOCKED if reasons else PreflightStatus.PASS,
        blocking_reasons=reasons,
    )


@dataclass(frozen=True, slots=True)
class HistoricalPoolFact:
    instrument_id: int
    symbol: str
    evaluation_at: datetime
    is_eligible: bool
    rejection_codes: tuple[str, ...]
    onboard_at: datetime | None = None
    contract_identity: str = ""
    exchange_status: str | None = None
    system_status: str | None = None
    status_effective_at: datetime | None = None
    status_payload_hash: str | None = None
    observed_quote_notional: Decimal | None = None
    liquidity_observed_at: datetime | None = None
    liquidity_revision_hash: str | None = None


class DatasetAuditStore(Protocol):
    async def historical_pool(
        self, dataset_version_id: UUID, evaluation_at: datetime
    ) -> tuple[HistoricalPoolFact, ...]: ...

    async def record_historical_pool(
        self, dataset_version_id: UUID, facts: Sequence[HistoricalPoolFact]
    ) -> None: ...

    async def record_resource_preflight(
        self,
        dataset_version_id: UUID,
        limits_config_version_id: UUID,
        estimate: ResourceEstimate,
        preflight: ResourcePreflight,
    ) -> None: ...

    async def record_source_shard(self, dataset_version_id: UUID, shard: SourceShard) -> None: ...

    async def record_quality_report(
        self,
        dataset_version_id: UUID,
        data_quality_rule_version_id: UUID,
        dependency_kind: str,
        report: DependencyQualityReport,
    ) -> None: ...

    async def finalize_fingerprint(self, dataset_version_id: UUID) -> str: ...


@dataclass(frozen=True, slots=True)
class DatasetAuditResult:
    evaluation_count: int
    eligible_fact_count: int
    resource_preflight: ResourcePreflight
    root_fingerprint: str
    ready_allowed: bool


class DatasetAuditService:
    def __init__(self, store: DatasetAuditStore) -> None:
        self._store = store

    async def audit(
        self,
        *,
        dataset_version_id: UUID,
        spec: DatasetBuildSpec,
        ready_config_bindings: Sequence[ReadyConfigBinding],
        source_shards: Sequence[SourceShard],
        evaluation_times: Sequence[datetime],
        resource_limit_config_version_id: UUID,
        data_quality_rule_version_id: UUID,
        resource_limits: ResourceLimits,
        resource_estimate: ResourceEstimate,
        quality_reports: Sequence[DependencyQualityReport],
        dependency_kinds: Mapping[str, str],
    ) -> DatasetAuditResult:
        bound_configs = validate_ready_config_bindings(ready_config_bindings)
        if bound_configs["RESOURCE_LIMITS"] != resource_limit_config_version_id:
            raise DatasetBuildError("resource limit config does not match READY binding")
        if bound_configs["DATA_QUALITY_RULES"] != data_quality_rule_version_id:
            raise DatasetBuildError("data quality config does not match READY binding")
        times = spec.validate_evaluation_times(evaluation_times)
        if not source_shards:
            raise DatasetBuildError("at least one source shard is required")
        ordered_shards = tuple(
            sorted(
                source_shards,
                key=lambda shard: (
                    shard.source_schema,
                    shard.source_table,
                    shard.source_shard_identity,
                ),
            )
        )
        build_member_manifest_hash(ordered_shards)
        if min(shard.member_start_at for shard in ordered_shards) > spec.warmup_start_at:
            raise DatasetBuildError("source shards do not cover warmup_start_at")
        if max(shard.member_end_at for shard in ordered_shards) < spec.label_window_end_at:
            raise DatasetBuildError("source shards do not cover label_window_end_at")
        if not quality_reports:
            raise DatasetBuildError("at least one dependency quality report is required")
        quality_names = [report.dependency_name for report in quality_reports]
        if len(quality_names) != len(set(quality_names)):
            raise DatasetBuildError("dependency quality reports must be unique")
        missing_dependency_kinds = sorted(
            report.dependency_name
            for report in quality_reports
            if not dependency_kinds.get(report.dependency_name, "").strip()
        )
        if missing_dependency_kinds:
            raise DatasetBuildError(
                "dependency kind is missing for " + ", ".join(missing_dependency_kinds)
            )

        # All deterministic input validation happens before the first controlled
        # write. Database-side guards remain authoritative for concurrent changes.
        for shard in ordered_shards:
            await self._store.record_source_shard(dataset_version_id, shard)

        eligible_count = 0
        for evaluation_at in times:
            facts = await self._store.historical_pool(dataset_version_id, evaluation_at)
            if not facts:
                raise DatasetBuildError(
                    f"historical pool returned no auditable facts at {evaluation_at.isoformat()}"
                )
            ordered = tuple(sorted(facts, key=lambda fact: (fact.symbol, fact.instrument_id)))
            if len({fact.instrument_id for fact in ordered}) != len(ordered):
                raise DatasetBuildError("historical pool contains duplicate instruments")
            if any(fact.evaluation_at != evaluation_at for fact in ordered):
                raise DatasetBuildError("historical pool fact has the wrong evaluation time")
            await self._store.record_historical_pool(dataset_version_id, ordered)
            eligible_count += sum(fact.is_eligible for fact in ordered)

        for report in sorted(quality_reports, key=lambda item: item.dependency_name):
            dependency_kind = dependency_kinds[report.dependency_name]
            await self._store.record_quality_report(
                dataset_version_id,
                data_quality_rule_version_id,
                dependency_kind,
                report,
            )

        preflight = evaluate_resource_preflight(resource_limits, resource_estimate)
        await self._store.record_resource_preflight(
            dataset_version_id,
            resource_limit_config_version_id,
            resource_estimate,
            preflight,
        )
        root_fingerprint = await self._store.finalize_fingerprint(dataset_version_id)
        quality_passed = all(report.status is QualityStatus.PASS for report in quality_reports)
        return DatasetAuditResult(
            evaluation_count=len(times),
            eligible_fact_count=eligible_count,
            resource_preflight=preflight,
            root_fingerprint=root_fingerprint,
            ready_allowed=(
                eligible_count > 0 and quality_passed and preflight.status is PreflightStatus.PASS
            ),
        )
