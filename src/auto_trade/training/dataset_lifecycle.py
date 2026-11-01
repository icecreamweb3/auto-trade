from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

from auto_trade.training.dataset_builder import (
    DatasetAuditResult,
    DatasetBuildError,
    SourceFreshnessAssessment,
)


def _sha(value: str, length: int, field_name: str) -> str:
    if len(value) != length or any(character not in "0123456789abcdef" for character in value):
        raise DatasetBuildError(f"{field_name} must be a lowercase SHA hash")
    return value


@dataclass(frozen=True, slots=True)
class DatasetManifestSpec:
    code_commit: str
    image_digest: str
    python_version: str
    system_version: str
    dependency_lock_hash: str
    database_migration_version: str
    rule_and_scoring_versions: dict[str, object]
    random_seed: int
    blas_thread_count: int
    openmp_thread_count: int
    cpu_count: int
    worker_concurrency: int
    normalized_query_hash: str
    input_hashes: dict[str, str]
    output_hashes: dict[str, str]
    run_command: str

    def __post_init__(self) -> None:
        _sha(self.code_commit, 40, "code_commit")
        _sha(self.dependency_lock_hash, 64, "dependency_lock_hash")
        _sha(self.normalized_query_hash, 64, "normalized_query_hash")
        for field_name in (
            "image_digest",
            "python_version",
            "system_version",
            "database_migration_version",
            "run_command",
        ):
            if not getattr(self, field_name).strip():
                raise DatasetBuildError(f"{field_name} must not be blank")
        if not self.rule_and_scoring_versions:
            raise DatasetBuildError("rule_and_scoring_versions must not be empty")
        for field_name in (
            "blas_thread_count",
            "openmp_thread_count",
            "cpu_count",
            "worker_concurrency",
        ):
            if getattr(self, field_name) <= 0:
                raise DatasetBuildError(f"{field_name} must be positive")
        for field_name in ("input_hashes", "output_hashes"):
            hashes = getattr(self, field_name)
            if not hashes:
                raise DatasetBuildError(f"{field_name} must not be empty")
            for value in hashes.values():
                _sha(value, 64, field_name)


class DatasetManifestStore(Protocol):
    async def complete_manifest(
        self, dataset_version_id: UUID, manifest: DatasetManifestSpec
    ) -> UUID: ...


class DatasetTransitionStore(Protocol):
    async def transition_dataset(
        self,
        dataset_version_id: UUID,
        expected_state: str,
        new_state: str,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> None: ...

    async def mark_stale_for_replacement(
        self,
        stale_dataset_version_id: UUID,
        replacement_dataset_version_id: UUID,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> None: ...


class DatasetLifecycleService:
    def __init__(
        self,
        manifest_store: DatasetManifestStore,
        transition_store: DatasetTransitionStore,
    ) -> None:
        self._manifest_store = manifest_store
        self._transition_store = transition_store

    async def make_ready(
        self,
        *,
        dataset_version_id: UUID,
        audit: DatasetAuditResult,
        manifest: DatasetManifestSpec,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> UUID:
        if not audit.ready_allowed:
            raise DatasetBuildError("blocked dataset audit cannot transition to READY")
        if audit.root_fingerprint not in manifest.output_hashes.values():
            raise DatasetBuildError("manifest outputs must include the audited dataset root")
        manifest_id = await self._manifest_store.complete_manifest(dataset_version_id, manifest)
        await self._transition_store.transition_dataset(
            dataset_version_id,
            "BUILDING",
            "READY",
            actor_user_id,
            reason,
            request_id,
        )
        return manifest_id

    async def replace_stale(
        self,
        *,
        stale_dataset_version_id: UUID,
        replacement_dataset_version_id: UUID,
        freshness: SourceFreshnessAssessment,
        replacement_audit: DatasetAuditResult,
        replacement_manifest: DatasetManifestSpec,
        actor_user_id: UUID,
        stale_reason: str,
        stale_request_id: UUID,
        ready_reason: str,
        ready_request_id: UUID,
        supersede_reason: str,
        supersede_request_id: UUID,
    ) -> UUID:
        if not freshness.is_stale:
            raise DatasetBuildError("unchanged source cannot stale a READY dataset")
        if not replacement_audit.ready_allowed:
            raise DatasetBuildError("replacement audit is blocked")
        if replacement_audit.root_fingerprint not in replacement_manifest.output_hashes.values():
            raise DatasetBuildError("replacement manifest omits the audited dataset root")

        manifest_id = await self._manifest_store.complete_manifest(
            replacement_dataset_version_id, replacement_manifest
        )
        await self._transition_store.mark_stale_for_replacement(
            stale_dataset_version_id,
            replacement_dataset_version_id,
            actor_user_id,
            stale_reason,
            stale_request_id,
        )
        await self._transition_store.transition_dataset(
            replacement_dataset_version_id,
            "BUILDING",
            "READY",
            actor_user_id,
            ready_reason,
            ready_request_id,
        )
        await self._transition_store.transition_dataset(
            stale_dataset_version_id,
            "STALE",
            "SUPERSEDED",
            actor_user_id,
            supersede_reason,
            supersede_request_id,
        )
        return manifest_id
