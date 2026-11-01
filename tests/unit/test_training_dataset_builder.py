from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID, uuid4

import pytest

from auto_trade.training.contracts import Partition, PartitionKind
from auto_trade.training.dataset_builder import (
    DatasetAuditService,
    DatasetBuildError,
    DatasetBuildSpec,
    DependencyObservation,
    DependencyQualityReport,
    DependencyRequirement,
    HistoricalPoolFact,
    MissingReadyConfigError,
    PreflightStatus,
    QualityStatus,
    ReadyConfigBinding,
    ResourceEstimate,
    ResourceLimits,
    ResourcePreflight,
    SourceShard,
    assess_source_freshness,
    audit_dependency,
    build_member_manifest_hash,
    evaluate_resource_preflight,
    validate_ready_config_bindings,
)


def _time(day: int) -> datetime:
    return datetime(2026, 6, day, tzinfo=UTC)


def _spec(kind: PartitionKind = PartitionKind.TRAIN) -> DatasetBuildSpec:
    return DatasetBuildSpec(
        partition=Partition(kind, _time(1), datetime(2026, 7, 1, tzinfo=UTC)),
        interval_seconds=300,
        warmup_start_at=datetime(2026, 5, 1, tzinfo=UTC),
        eligible_start_at=_time(1),
        eligible_end_at=_time(29),
        label_window_end_at=_time(30),
        source_as_of_at=datetime(2026, 7, 2, tzinfo=UTC),
        visibility_cutoff_at=datetime(2026, 5, 31, tzinfo=UTC),
        label_horizon=timedelta(days=1),
        max_holding_horizon=timedelta(days=1),
        purge_duration=timedelta(days=1),
        embargo_duration=timedelta(days=1),
    )


def _limits() -> ResourceLimits:
    return ResourceLimits.from_config(
        {
            "db_workers_per_experiment": 2,
            "pool_connections": 6,
            "statement_timeout_seconds": 900,
            "work_mem_bytes": 64 * 1024**2,
            "cpu_limit": 4,
            "memory_bytes": 8 * 1024**3,
            "temp_disk_min_free_bytes": 1024**3,
            "max_candidate_count": 1_000,
            "max_signal_count": 100_000,
            "max_decision_row_count": 1_000_000,
            "max_storage_bytes": 10 * 1024**3,
        }
    )


def _estimate(**overrides: int | Decimal) -> ResourceEstimate:
    values: dict[str, int | Decimal] = {
        "candidate_count": 10,
        "signal_count": 100,
        "decision_row_count": 1_000,
        "storage_bytes": 1024**2,
        "db_workers": 1,
        "pool_connections": 2,
        "statement_seconds": 60,
        "work_mem_bytes": 1024**2,
        "cpu": Decimal(1),
        "memory_bytes": 1024**3,
        "temp_bytes": 1024**2,
        "available_temp_bytes": 2 * 1024**3,
    }
    values.update(overrides)
    return ResourceEstimate(**values)  # type: ignore[arg-type]


def _passing_quality() -> DependencyQualityReport:
    return audit_dependency(
        DependencyRequirement("KLINE", 100, Decimal("0.99"), 50, 1, True),
        DependencyObservation(100, 0, True, 100, 1, {"source": "fixture"}),
    )


def _bindings(resource_config_id: UUID, quality_config_id: UUID) -> tuple[ReadyConfigBinding, ...]:
    config_ids = {
        "TICKER_POOL_RULES": uuid4(),
        "DATA_QUALITY_RULES": quality_config_id,
        "HOLDING_HORIZON_RULES": uuid4(),
        "ELIGIBLE_POOL_RULES": uuid4(),
        "REPRODUCIBILITY_TOLERANCE": uuid4(),
        "RESOURCE_LIMITS": resource_config_id,
        "FEE_MODEL": uuid4(),
        "SLIPPAGE_MODEL": uuid4(),
        "VISIBILITY_CUTOFF_POLICY": uuid4(),
    }
    return tuple(
        ReadyConfigBinding(config_type, config_id, "READY")
        for config_type, config_id in config_ids.items()
    )


def _source_shard() -> SourceShard:
    return SourceShard(
        "market",
        "klines",
        "BTCUSDT:300:2026-05/06",
        datetime(2026, 5, 1, tzinfo=UTC),
        _time(30),
        {"revision": 1},
        17_280,
        "a" * 64,
        "b" * 64,
    )


def test_dataset_spec_rejects_test_partition() -> None:
    with pytest.raises(DatasetBuildError, match="TRAIN/VALIDATION"):
        _spec(PartitionKind.TEST)


def test_dataset_spec_rejects_short_embargo() -> None:
    spec = _spec()
    with pytest.raises(DatasetBuildError, match="embargo_duration"):
        DatasetBuildSpec(
            partition=spec.partition,
            interval_seconds=spec.interval_seconds,
            warmup_start_at=spec.warmup_start_at,
            eligible_start_at=spec.eligible_start_at,
            eligible_end_at=spec.eligible_end_at,
            label_window_end_at=spec.label_window_end_at,
            source_as_of_at=spec.source_as_of_at,
            visibility_cutoff_at=spec.visibility_cutoff_at,
            label_horizon=spec.label_horizon,
            max_holding_horizon=timedelta(days=2),
            purge_duration=timedelta(days=2),
            embargo_duration=timedelta(days=1),
        )


def test_evaluation_times_are_left_closed_right_open_and_sorted() -> None:
    spec = _spec()
    assert spec.validate_evaluation_times((_time(1), _time(2))) == (_time(1), _time(2))
    with pytest.raises(DatasetBuildError, match="unique and sorted"):
        spec.validate_evaluation_times((_time(2), _time(1)))
    with pytest.raises(DatasetBuildError, match="outside"):
        spec.validate_evaluation_times((_time(29),))


def test_ready_config_validation_requires_every_explicit_type() -> None:
    with pytest.raises(MissingReadyConfigError, match="missing READY configs"):
        validate_ready_config_bindings((ReadyConfigBinding("RESOURCE_LIMITS", uuid4(), "READY"),))
    with pytest.raises(MissingReadyConfigError, match="expected READY"):
        validate_ready_config_bindings((ReadyConfigBinding("RESOURCE_LIMITS", uuid4(), "DRAFT"),))


def test_source_revision_changes_shard_and_manifest_fingerprints() -> None:
    common = {
        "source_schema": "market",
        "source_table": "klines",
        "source_shard_identity": "BTCUSDT:300:2026-06",
        "member_start_at": _time(1),
        "member_end_at": _time(2),
        "row_count": 288,
        "normalized_query_hash": "a" * 64,
        "content_hash": "b" * 64,
    }
    first = SourceShard(**common, source_revision_watermark={"max_revision": 1})
    revised = SourceShard(**common, source_revision_watermark={"max_revision": 2})
    assert first.shard_fingerprint != revised.shard_fingerprint
    assert build_member_manifest_hash((first,)) != build_member_manifest_hash((revised,))


def test_member_manifest_is_order_independent_but_rejects_duplicate_identity() -> None:
    first = SourceShard(
        "market", "klines", "A", _time(1), _time(2), {"revision": 1}, 1, "a" * 64, "b" * 64
    )
    second = SourceShard(
        "market", "klines", "B", _time(1), _time(2), {"revision": 1}, 1, "c" * 64, "d" * 64
    )
    assert build_member_manifest_hash((first, second)) == build_member_manifest_hash(
        (second, first)
    )
    with pytest.raises(DatasetBuildError, match="unique"):
        build_member_manifest_hash((first, first))


def test_source_freshness_identifies_revised_and_added_shards() -> None:
    first = SourceShard(
        "market", "klines", "A", _time(1), _time(2), {"revision": 1}, 1, "a" * 64, "b" * 64
    )
    revised = SourceShard(
        "market", "klines", "A", _time(1), _time(2), {"revision": 2}, 1, "a" * 64, "c" * 64
    )
    added = SourceShard(
        "market", "klines", "B", _time(1), _time(2), {"revision": 1}, 1, "d" * 64, "e" * 64
    )
    unchanged = assess_source_freshness((first,), (first,))
    changed = assess_source_freshness((first,), (revised, added))
    assert not unchanged.is_stale
    assert changed.is_stale
    assert changed.changed_shard_identities == ("A", "B")


def test_missing_dependency_is_blocked_and_never_silently_passes_as_zero() -> None:
    report = audit_dependency(DependencyRequirement("OI", 100, Decimal("0.95"), 20, 1, True), None)
    assert report.status is QualityStatus.BLOCKED
    assert report.coverage_ratio == 0
    assert report.missing_ratio == 1
    assert report.blocking_reasons == ("DATA_DEPENDENCY_UNAVAILABLE",)


def test_dependency_thresholds_are_explicit_and_enforced() -> None:
    report = audit_dependency(
        DependencyRequirement("EMA", 100, Decimal("0.99"), 90, 2, True),
        DependencyObservation(98, 2, False, 80, 1, {"query": "fixture"}),
    )
    assert report.status is QualityStatus.BLOCKED
    assert report.blocking_reasons == (
        "COVERAGE_BELOW_CONFIGURED_MINIMUM",
        "WARMUP_INCOMPLETE",
        "EFFECTIVE_SAMPLE_COUNT_TOO_LOW",
        "EFFECTIVE_FOLD_COUNT_TOO_LOW",
    )


def test_resource_limits_reject_missing_or_boolean_values() -> None:
    config: dict[str, object] = {
        "db_workers_per_experiment": 2,
        "pool_connections": 6,
        "statement_timeout_seconds": 900,
        "work_mem_bytes": 1024,
        "cpu_limit": 4,
        "memory_bytes": 1024,
        "temp_disk_min_free_bytes": 1024,
        "max_candidate_count": 100,
        "max_signal_count": 100,
        "max_decision_row_count": 100,
        "max_storage_bytes": 100,
    }
    del config["max_storage_bytes"]
    with pytest.raises(DatasetBuildError, match="max_storage_bytes"):
        ResourceLimits.from_config(config)
    config["max_storage_bytes"] = True
    with pytest.raises(DatasetBuildError, match="max_storage_bytes"):
        ResourceLimits.from_config(config)


def test_resource_preflight_reports_every_exceeded_limit_in_stable_order() -> None:
    result = evaluate_resource_preflight(
        _limits(),
        _estimate(
            candidate_count=1_001,
            cpu=Decimal(5),
            available_temp_bytes=1024**3,
            temp_bytes=1,
        ),
    )
    assert result.status is PreflightStatus.BLOCKED
    assert result.blocking_reasons == (
        "CANDIDATE_COUNT_EXCEEDED",
        "CPU_EXCEEDED",
        "TEMP_DISK_WATERMARK_EXCEEDED",
    )


class _AuditStore:
    def __init__(self, facts: dict[datetime, tuple[HistoricalPoolFact, ...]]) -> None:
        self.facts = facts
        self.recorded: list[tuple[UUID, tuple[HistoricalPoolFact, ...]]] = []
        self.preflights: list[ResourcePreflight] = []
        self.shards: list[SourceShard] = []
        self.quality: list[DependencyQualityReport] = []

    async def historical_pool(
        self, dataset_version_id: UUID, evaluation_at: datetime
    ) -> tuple[HistoricalPoolFact, ...]:
        return self.facts[evaluation_at]

    async def record_historical_pool(
        self, dataset_version_id: UUID, facts: Sequence[HistoricalPoolFact]
    ) -> None:
        self.recorded.append((dataset_version_id, tuple(facts)))

    async def record_resource_preflight(
        self,
        dataset_version_id: UUID,
        limits_config_version_id: UUID,
        estimate: ResourceEstimate,
        preflight: ResourcePreflight,
    ) -> None:
        self.preflights.append(preflight)

    async def record_source_shard(self, dataset_version_id: UUID, shard: SourceShard) -> None:
        self.shards.append(shard)

    async def record_quality_report(
        self,
        dataset_version_id: UUID,
        data_quality_rule_version_id: UUID,
        dependency_kind: str,
        report: DependencyQualityReport,
    ) -> None:
        self.quality.append(report)

    async def finalize_fingerprint(self, dataset_version_id: UUID) -> str:
        return "f" * 64


@pytest.mark.asyncio
async def test_audit_service_sorts_facts_and_allows_ready_only_after_all_gates() -> None:
    evaluation_at = _time(10)
    dataset_id = uuid4()
    store = _AuditStore(
        {
            evaluation_at: (
                HistoricalPoolFact(2, "ZZZUSDT", evaluation_at, False, ("MISSING_LIQUIDITY",)),
                HistoricalPoolFact(1, "AAAUSDT", evaluation_at, True, ()),
            )
        }
    )
    resource_config_id = uuid4()
    quality_config_id = uuid4()
    result = await DatasetAuditService(store).audit(
        dataset_version_id=dataset_id,
        spec=_spec(),
        ready_config_bindings=_bindings(resource_config_id, quality_config_id),
        source_shards=(_source_shard(),),
        evaluation_times=(evaluation_at,),
        resource_limit_config_version_id=resource_config_id,
        data_quality_rule_version_id=quality_config_id,
        resource_limits=_limits(),
        resource_estimate=_estimate(),
        quality_reports=(_passing_quality(),),
        dependency_kinds={"KLINE": "MARKET_DATA"},
    )
    assert result.ready_allowed
    assert result.eligible_fact_count == 1
    assert [fact.symbol for fact in store.recorded[0][1]] == ["AAAUSDT", "ZZZUSDT"]


@pytest.mark.asyncio
async def test_audit_service_returns_diagnostic_not_ready_when_resource_blocked() -> None:
    evaluation_at = _time(10)
    store = _AuditStore(
        {evaluation_at: (HistoricalPoolFact(1, "AAAUSDT", evaluation_at, True, ()),)}
    )
    resource_config_id = uuid4()
    quality_config_id = uuid4()
    result = await DatasetAuditService(store).audit(
        dataset_version_id=uuid4(),
        spec=_spec(),
        ready_config_bindings=_bindings(resource_config_id, quality_config_id),
        source_shards=(_source_shard(),),
        evaluation_times=(evaluation_at,),
        resource_limit_config_version_id=resource_config_id,
        data_quality_rule_version_id=quality_config_id,
        resource_limits=_limits(),
        resource_estimate=_estimate(candidate_count=1_001),
        quality_reports=(_passing_quality(),),
        dependency_kinds={"KLINE": "MARKET_DATA"},
    )
    assert not result.ready_allowed
    assert result.resource_preflight.status is PreflightStatus.BLOCKED


@pytest.mark.asyncio
async def test_audit_service_rejects_empty_or_duplicate_historical_facts() -> None:
    evaluation_at = _time(10)
    empty_store = _AuditStore({evaluation_at: ()})
    resource_config_id = uuid4()
    quality_config_id = uuid4()
    with pytest.raises(DatasetBuildError, match="no auditable facts"):
        await DatasetAuditService(empty_store).audit(
            dataset_version_id=uuid4(),
            spec=_spec(),
            ready_config_bindings=_bindings(resource_config_id, quality_config_id),
            source_shards=(_source_shard(),),
            evaluation_times=(evaluation_at,),
            resource_limit_config_version_id=resource_config_id,
            data_quality_rule_version_id=quality_config_id,
            resource_limits=_limits(),
            resource_estimate=_estimate(),
            quality_reports=(_passing_quality(),),
            dependency_kinds={"KLINE": "MARKET_DATA"},
        )

    duplicate = HistoricalPoolFact(1, "AAAUSDT", evaluation_at, True, ())
    duplicate_store = _AuditStore({evaluation_at: (duplicate, duplicate)})
    with pytest.raises(DatasetBuildError, match="duplicate"):
        await DatasetAuditService(duplicate_store).audit(
            dataset_version_id=uuid4(),
            spec=_spec(),
            ready_config_bindings=_bindings(resource_config_id, quality_config_id),
            source_shards=(_source_shard(),),
            evaluation_times=(evaluation_at,),
            resource_limit_config_version_id=resource_config_id,
            data_quality_rule_version_id=quality_config_id,
            resource_limits=_limits(),
            resource_estimate=_estimate(),
            quality_reports=(_passing_quality(),),
            dependency_kinds={"KLINE": "MARKET_DATA"},
        )


@pytest.mark.asyncio
async def test_audit_service_prevalidates_before_first_controlled_write() -> None:
    evaluation_at = _time(10)
    store = _AuditStore(
        {evaluation_at: (HistoricalPoolFact(1, "AAAUSDT", evaluation_at, True, ()),)}
    )
    resource_config_id = uuid4()
    quality_config_id = uuid4()
    with pytest.raises(DatasetBuildError, match="dependency kind is missing"):
        await DatasetAuditService(store).audit(
            dataset_version_id=uuid4(),
            spec=_spec(),
            ready_config_bindings=_bindings(resource_config_id, quality_config_id),
            source_shards=(_source_shard(),),
            evaluation_times=(evaluation_at,),
            resource_limit_config_version_id=resource_config_id,
            data_quality_rule_version_id=quality_config_id,
            resource_limits=_limits(),
            resource_estimate=_estimate(),
            quality_reports=(_passing_quality(),),
            dependency_kinds={},
        )
    assert store.shards == []
    assert store.recorded == []
    assert store.quality == []
    assert store.preflights == []
