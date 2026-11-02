from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.dataset_builder import DatasetBuildError
from auto_trade.training.dataset_task_handler import (
    DatasetBuildTaskHandler,
    parse_dataset_build_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def payload() -> dict[str, object]:
    return {
        "task_type": "DATASET_BUILD",
        "payload_version": 1,
        "dataset_version_id": str(uuid4()),
        "evaluation_times": ["2026-06-01T00:00:00Z"],
        "shard_requests": [
            {
                "instrument_id": 1,
                "member_start_at": "2026-05-01T00:00:00Z",
                "member_end_at": "2026-06-30T00:00:00Z",
            }
        ],
        "resource_estimate": {
            "candidate_count": 10,
            "signal_count": 100,
            "decision_row_count": 1000,
            "storage_bytes": 1024,
            "db_workers": 1,
            "pool_connections": 2,
            "statement_seconds": 60,
            "work_mem_bytes": 1048576,
            "cpu": "1",
            "memory_bytes": 1073741824,
            "temp_bytes": 1024,
            "available_temp_bytes": 2147483648,
        },
        "quality_reports": [
            {
                "dependency_name": "KLINE",
                "coverage_ratio": "1",
                "missing_ratio": "0",
                "warmup_complete": True,
                "effective_sample_count": 100,
                "effective_fold_count": 1,
                "expected_row_count": 100,
                "observed_row_count": 100,
                "missing_row_count": 0,
                "status": "PASS",
                "blocking_reasons": [],
                "evidence": {"source": "fixture"},
            }
        ],
        "dependency_kinds": {"KLINE": "KLINE"},
    }


def test_parse_dataset_build_payload_v1() -> None:
    parsed = parse_dataset_build_payload(payload())
    assert parsed.resource_estimate.db_workers == 1
    assert parsed.shard_requests[0].instrument_id == 1
    assert parsed.quality_reports[0].dependency_name == "KLINE"


def test_dataset_build_payload_rejects_unknown_fields() -> None:
    value = payload()
    value["validation_metric"] = 1
    with pytest.raises(DatasetBuildError, match="unexpected"):
        parse_dataset_build_payload(value)


def test_dataset_build_payload_rejects_non_utc_time() -> None:
    value = payload()
    value["evaluation_times"] = ["2026-06-01T08:00:00+08:00"]
    with pytest.raises(DatasetBuildError, match="must be UTC"):
        parse_dataset_build_payload(value)


def test_dataset_build_payload_rejects_untrusted_shard_hashes() -> None:
    value = payload()
    shard = value["shard_requests"]
    assert isinstance(shard, list)
    assert isinstance(shard[0], dict)
    shard[0]["content_hash"] = "a" * 64
    # Nested shard keys are checked by the handler contract below; untrusted
    # hashes must never be accepted as authoritative input.
    with pytest.raises(DatasetBuildError):
        parse_dataset_build_payload(value)


def test_dataset_build_payload_rejects_reversed_shard_window() -> None:
    value = payload()
    shard = value["shard_requests"]
    assert isinstance(shard, list)
    assert isinstance(shard[0], dict)
    shard[0]["member_end_at"] = "2026-04-01T00:00:00Z"
    with pytest.raises(DatasetBuildError, match="must precede"):
        parse_dataset_build_payload(value)


def test_dataset_build_payload_rejects_unknown_quality_status() -> None:
    value = payload()
    reports = value["quality_reports"]
    assert isinstance(reports, list)
    assert isinstance(reports[0], dict)
    reports[0]["status"] = "TRUST_ME"
    with pytest.raises(DatasetBuildError, match="PASS, WARN, or BLOCKED"):
        parse_dataset_build_payload(value)


def task_lease(value: dict[str, object]) -> TaskLease:
    return TaskLease(
        uuid4(),
        ExecutorKind.WORKER,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        value,
    )


@pytest.mark.asyncio
async def test_handler_resolves_shards_from_trusted_database_function(monkeypatch) -> None:
    fake_store = MagicMock()
    fake_store.load_audit_context = AsyncMock(
        return_value=("spec", ("binding",), "resource-id", "quality-id", "limits")
    )
    fake_store.kline_source_shard = AsyncMock(return_value="trusted-shard")
    captured: dict[str, object] = {}

    class FakeAuditService:
        def __init__(self, store: object) -> None:
            assert store is fake_store

        async def audit(self, **kwargs: object) -> object:
            captured.update(kwargs)
            return SimpleNamespace(ready_allowed=True, root_fingerprint="a" * 64)

    monkeypatch.setattr(
        "auto_trade.training.dataset_task_handler.DatabaseDatasetAuditStore",
        lambda _connection: fake_store,
    )
    monkeypatch.setattr(
        "auto_trade.training.dataset_task_handler.DatasetAuditService", FakeAuditService
    )

    result = await DatasetBuildTaskHandler(MagicMock())(task_lease(payload()))

    assert result == "a" * 64
    fake_store.kline_source_shard.assert_awaited_once()
    assert captured["source_shards"] == ("trusted-shard",)


@pytest.mark.asyncio
async def test_handler_refuses_success_when_ready_gate_remains_blocked(monkeypatch) -> None:
    fake_store = MagicMock()
    fake_store.load_audit_context = AsyncMock(
        return_value=("spec", (), "resource-id", "quality-id", "limits")
    )
    fake_store.kline_source_shard = AsyncMock(return_value="trusted-shard")

    class FakeAuditService:
        def __init__(self, _store: object) -> None:
            pass

        async def audit(self, **_kwargs: object) -> object:
            return SimpleNamespace(ready_allowed=False, root_fingerprint="b" * 64)

    monkeypatch.setattr(
        "auto_trade.training.dataset_task_handler.DatabaseDatasetAuditStore",
        lambda _connection: fake_store,
    )
    monkeypatch.setattr(
        "auto_trade.training.dataset_task_handler.DatasetAuditService", FakeAuditService
    )

    with pytest.raises(DatasetBuildError, match="READY remains blocked"):
        await DatasetBuildTaskHandler(MagicMock())(task_lease(payload()))
