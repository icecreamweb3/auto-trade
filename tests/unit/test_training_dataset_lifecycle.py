from __future__ import annotations

from uuid import UUID, uuid4

import pytest

from auto_trade.training.dataset_builder import (
    DatasetAuditResult,
    DatasetBuildError,
    PreflightStatus,
    ResourcePreflight,
    SourceFreshnessAssessment,
)
from auto_trade.training.dataset_lifecycle import (
    DatasetLifecycleService,
    DatasetManifestSpec,
)


def _manifest(root: str = "f" * 64) -> DatasetManifestSpec:
    return DatasetManifestSpec(
        code_commit="a" * 40,
        image_digest="sha256:fixture",
        python_version="3.12",
        system_version="linux",
        dependency_lock_hash="b" * 64,
        database_migration_version="024_training_dataset_lifecycle",
        rule_and_scoring_versions={"dataset_builder": "v1"},
        random_seed=7,
        blas_thread_count=1,
        openmp_thread_count=1,
        cpu_count=2,
        worker_concurrency=1,
        normalized_query_hash="c" * 64,
        input_hashes={"source": "d" * 64},
        output_hashes={"dataset_root": root},
        run_command="python -m auto_trade.training.dataset_builder",
    )


def _audit(ready: bool = True, root: str = "f" * 64) -> DatasetAuditResult:
    return DatasetAuditResult(
        evaluation_count=1,
        eligible_fact_count=1,
        resource_preflight=ResourcePreflight(PreflightStatus.PASS, ()),
        root_fingerprint=root,
        ready_allowed=ready,
    )


class _LifecycleStore:
    def __init__(self) -> None:
        self.calls: list[tuple[object, ...]] = []
        self.manifest_id = uuid4()

    async def complete_manifest(
        self, dataset_version_id: UUID, manifest: DatasetManifestSpec
    ) -> UUID:
        self.calls.append(("manifest", dataset_version_id))
        return self.manifest_id

    async def transition_dataset(
        self,
        dataset_version_id: UUID,
        expected_state: str,
        new_state: str,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> None:
        self.calls.append(("transition", dataset_version_id, expected_state, new_state))

    async def mark_stale_for_replacement(
        self,
        stale_dataset_version_id: UUID,
        replacement_dataset_version_id: UUID,
        actor_user_id: UUID,
        reason: str,
        request_id: UUID,
    ) -> None:
        self.calls.append(("stale", stale_dataset_version_id, replacement_dataset_version_id))


@pytest.mark.asyncio
async def test_make_ready_requires_passed_audit_before_manifest_write() -> None:
    store = _LifecycleStore()
    with pytest.raises(DatasetBuildError, match="blocked dataset audit"):
        await DatasetLifecycleService(store, store).make_ready(
            dataset_version_id=uuid4(),
            audit=_audit(False),
            manifest=_manifest(),
            actor_user_id=uuid4(),
            reason="fixture",
            request_id=uuid4(),
        )
    assert store.calls == []


@pytest.mark.asyncio
async def test_make_ready_completes_manifest_before_transition() -> None:
    store = _LifecycleStore()
    dataset_id = uuid4()
    manifest_id = await DatasetLifecycleService(store, store).make_ready(
        dataset_version_id=dataset_id,
        audit=_audit(),
        manifest=_manifest(),
        actor_user_id=uuid4(),
        reason="all gates passed",
        request_id=uuid4(),
    )
    assert manifest_id == store.manifest_id
    assert store.calls == [
        ("manifest", dataset_id),
        ("transition", dataset_id, "BUILDING", "READY"),
    ]


@pytest.mark.asyncio
async def test_replace_stale_is_refused_when_source_manifest_is_unchanged() -> None:
    store = _LifecycleStore()
    unchanged = SourceFreshnessAssessment("a" * 64, "a" * 64, ())
    with pytest.raises(DatasetBuildError, match="unchanged source"):
        await DatasetLifecycleService(store, store).replace_stale(
            stale_dataset_version_id=uuid4(),
            replacement_dataset_version_id=uuid4(),
            freshness=unchanged,
            replacement_audit=_audit(),
            replacement_manifest=_manifest(),
            actor_user_id=uuid4(),
            stale_reason="revision changed",
            stale_request_id=uuid4(),
            ready_reason="replacement ready",
            ready_request_id=uuid4(),
            supersede_reason="replacement activated",
            supersede_request_id=uuid4(),
        )
    assert store.calls == []


@pytest.mark.asyncio
async def test_replace_stale_orders_manifest_and_state_transitions() -> None:
    store = _LifecycleStore()
    stale_id = uuid4()
    replacement_id = uuid4()
    changed = SourceFreshnessAssessment("a" * 64, "b" * 64, ("KLINE",))
    await DatasetLifecycleService(store, store).replace_stale(
        stale_dataset_version_id=stale_id,
        replacement_dataset_version_id=replacement_id,
        freshness=changed,
        replacement_audit=_audit(),
        replacement_manifest=_manifest(),
        actor_user_id=uuid4(),
        stale_reason="revision changed",
        stale_request_id=uuid4(),
        ready_reason="replacement ready",
        ready_request_id=uuid4(),
        supersede_reason="replacement activated",
        supersede_request_id=uuid4(),
    )
    assert store.calls == [
        ("manifest", replacement_id),
        ("stale", stale_id, replacement_id),
        ("transition", replacement_id, "BUILDING", "READY"),
        ("transition", stale_id, "STALE", "SUPERSEDED"),
    ]
