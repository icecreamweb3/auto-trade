"""DATASET_BUILD v1 payload contract and governed handler."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import cast
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.dataset_builder import (
    DatasetAuditService,
    DatasetBuildError,
    DependencyQualityReport,
    QualityStatus,
    ResourceEstimate,
)
from auto_trade.training.dataset_repository import DatabaseDatasetAuditStore
from auto_trade.training.orchestrator import TaskLease


def _mapping(value: object, field: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise DatasetBuildError(f"{field} must be an object")
    return cast(Mapping[str, object], value)


def _list(value: object, field: str) -> list[object]:
    if not isinstance(value, list):
        raise DatasetBuildError(f"{field} must be an array")
    return value


def _utc(value: object, field: str) -> datetime:
    if not isinstance(value, str):
        raise DatasetBuildError(f"{field} must be an ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise DatasetBuildError(f"{field} is not a valid timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise DatasetBuildError(f"{field} must include UTC timezone")
    normalized = parsed.astimezone(UTC)
    if parsed.utcoffset() != normalized.utcoffset():
        raise DatasetBuildError(f"{field} must be UTC")
    return normalized


def _integer(value: object, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise DatasetBuildError(f"{field} must be an integer >= {minimum}")
    return value


def _decimal(value: object, field: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise DatasetBuildError(f"{field} must be a finite decimal") from error
    if not parsed.is_finite():
        raise DatasetBuildError(f"{field} must be a finite decimal")
    return parsed


def _boolean(value: object, field: str) -> bool:
    if not isinstance(value, bool):
        raise DatasetBuildError(f"{field} must be a boolean")
    return value


def _quality_status(value: object) -> QualityStatus:
    try:
        return QualityStatus(str(value))
    except ValueError as error:
        raise DatasetBuildError("status must be PASS, WARN, or BLOCKED") from error


def _assert_keys(row: Mapping[str, object], allowed: set[str], field: str) -> None:
    unexpected = sorted(set(row) - allowed)
    if unexpected:
        raise DatasetBuildError(f"unexpected {field} fields: " + ", ".join(unexpected))


@dataclass(frozen=True, slots=True)
class TrustedShardRequest:
    instrument_id: int
    member_start_at: datetime
    member_end_at: datetime


@dataclass(frozen=True, slots=True)
class DatasetBuildTaskPayload:
    dataset_version_id: UUID
    evaluation_times: tuple[datetime, ...]
    shard_requests: tuple[TrustedShardRequest, ...]
    resource_estimate: ResourceEstimate
    quality_reports: tuple[DependencyQualityReport, ...]
    dependency_kinds: Mapping[str, str]


def parse_dataset_build_payload(payload: Mapping[str, object]) -> DatasetBuildTaskPayload:
    allowed = {
        "task_type",
        "payload_version",
        "dataset_version_id",
        "evaluation_times",
        "shard_requests",
        "resource_estimate",
        "quality_reports",
        "dependency_kinds",
    }
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise DatasetBuildError("unexpected DATASET_BUILD fields: " + ", ".join(unexpected))
    if payload.get("task_type") != "DATASET_BUILD" or payload.get("payload_version") != 1:
        raise DatasetBuildError("DATASET_BUILD requires payload_version 1")
    try:
        dataset_version_id = UUID(str(payload["dataset_version_id"]))
    except (KeyError, ValueError) as error:
        raise DatasetBuildError("dataset_version_id must be a UUID") from error

    evaluation_times = tuple(
        _utc(value, "evaluation_times[]")
        for value in _list(payload.get("evaluation_times"), "evaluation_times")
    )
    shard_requests: list[TrustedShardRequest] = []
    for item in _list(payload.get("shard_requests"), "shard_requests"):
        row = _mapping(item, "shard_requests[]")
        _assert_keys(
            row,
            {"instrument_id", "member_start_at", "member_end_at"},
            "shard request",
        )
        request = TrustedShardRequest(
            _integer(row.get("instrument_id"), "instrument_id", minimum=1),
            _utc(row.get("member_start_at"), "member_start_at"),
            _utc(row.get("member_end_at"), "member_end_at"),
        )
        if request.member_start_at >= request.member_end_at:
            raise DatasetBuildError("member_start_at must precede member_end_at")
        shard_requests.append(request)

    estimate = _mapping(payload.get("resource_estimate"), "resource_estimate")
    _assert_keys(
        estimate,
        {
            "candidate_count", "signal_count", "decision_row_count", "storage_bytes",
            "db_workers", "pool_connections", "statement_seconds", "work_mem_bytes",
            "cpu", "memory_bytes", "temp_bytes", "available_temp_bytes",
        },
        "resource estimate",
    )
    resource_estimate = ResourceEstimate(
        candidate_count=_integer(estimate.get("candidate_count"), "candidate_count"),
        signal_count=_integer(estimate.get("signal_count"), "signal_count"),
        decision_row_count=_integer(estimate.get("decision_row_count"), "decision_row_count"),
        storage_bytes=_integer(estimate.get("storage_bytes"), "storage_bytes"),
        db_workers=_integer(estimate.get("db_workers"), "db_workers", minimum=1),
        pool_connections=_integer(
            estimate.get("pool_connections"), "pool_connections", minimum=1
        ),
        statement_seconds=_integer(
            estimate.get("statement_seconds"), "statement_seconds", minimum=1
        ),
        work_mem_bytes=_integer(estimate.get("work_mem_bytes"), "work_mem_bytes", minimum=1),
        cpu=_decimal(estimate.get("cpu"), "cpu"),
        memory_bytes=_integer(estimate.get("memory_bytes"), "memory_bytes", minimum=1),
        temp_bytes=_integer(estimate.get("temp_bytes"), "temp_bytes"),
        available_temp_bytes=_integer(
            estimate.get("available_temp_bytes"), "available_temp_bytes"
        ),
    )

    reports: list[DependencyQualityReport] = []
    for item in _list(payload.get("quality_reports"), "quality_reports"):
        row = _mapping(item, "quality_reports[]")
        _assert_keys(
            row,
            {
                "dependency_name", "coverage_ratio", "missing_ratio", "warmup_complete",
                "effective_sample_count", "effective_fold_count", "expected_row_count",
                "observed_row_count", "missing_row_count", "status", "blocking_reasons",
                "evidence",
            },
            "quality report",
        )
        reports.append(
            DependencyQualityReport(
                dependency_name=str(row.get("dependency_name", "")),
                coverage_ratio=_decimal(row.get("coverage_ratio"), "coverage_ratio"),
                missing_ratio=_decimal(row.get("missing_ratio"), "missing_ratio"),
                warmup_complete=_boolean(row.get("warmup_complete"), "warmup_complete"),
                effective_sample_count=_integer(
                    row.get("effective_sample_count"), "effective_sample_count"
                ),
                effective_fold_count=_integer(
                    row.get("effective_fold_count"), "effective_fold_count"
                ),
                expected_row_count=_integer(
                    row.get("expected_row_count"), "expected_row_count", minimum=1
                ),
                observed_row_count=_integer(
                    row.get("observed_row_count"), "observed_row_count"
                ),
                missing_row_count=_integer(row.get("missing_row_count"), "missing_row_count"),
                status=_quality_status(row.get("status")),
                blocking_reasons=tuple(
                    str(value)
                    for value in _list(row.get("blocking_reasons"), "blocking_reasons")
                ),
                evidence=_mapping(row.get("evidence"), "evidence"),
            )
        )
    dependency_kinds_raw = _mapping(payload.get("dependency_kinds"), "dependency_kinds")
    dependency_kinds = {str(key): str(value) for key, value in dependency_kinds_raw.items()}
    return DatasetBuildTaskPayload(
        dataset_version_id,
        evaluation_times,
        tuple(shard_requests),
        resource_estimate,
        tuple(reports),
        dependency_kinds,
    )


class DatasetBuildTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseDatasetAuditStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        payload = parse_dataset_build_payload(lease.payload)
        spec, bindings, resource_id, quality_id, limits = (
            await self._store.load_audit_context(payload.dataset_version_id)
        )
        shards = tuple(
            [
                await self._store.kline_source_shard(
                    payload.dataset_version_id,
                    request.instrument_id,
                    request.member_start_at,
                    request.member_end_at,
                )
                for request in payload.shard_requests
            ]
        )
        result = await DatasetAuditService(self._store).audit(
            dataset_version_id=payload.dataset_version_id,
            spec=spec,
            ready_config_bindings=bindings,
            source_shards=shards,
            evaluation_times=payload.evaluation_times,
            resource_limit_config_version_id=resource_id,
            data_quality_rule_version_id=quality_id,
            resource_limits=limits,
            resource_estimate=payload.resource_estimate,
            quality_reports=payload.quality_reports,
            dependency_kinds=payload.dependency_kinds,
        )
        if not result.ready_allowed:
            raise DatasetBuildError("dataset audit completed but READY remains blocked")
        return result.root_fingerprint
