from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.archive import ArchiveEvidence, sha256_bytes
from auto_trade.training.archive_verify_repository import ArchiveVerifyContext
from auto_trade.training.archive_verify_task_handler import (
    ArchiveVerifyError,
    ArchiveVerifyTaskHandler,
    LocalParquetArchiveRestorer,
    parse_archive_verify_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease

STORAGE_KEY = "experiment/iteration/signals.parquet"


def lease(kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {
            "task_type": "ARCHIVE_VERIFY",
            "payload_version": 1,
            "archive_manifest_id": str(uuid4()),
            "storage_key": STORAGE_KEY,
        },
    )


def evidence(*, content_hash: str = "a" * 64) -> ArchiveEvidence:
    start = datetime(2026, 1, 1, tzinfo=UTC)
    return ArchiveEvidence(4, start, start + timedelta(hours=1), 100, content_hash)


def context(value: TaskLease) -> ArchiveVerifyContext:
    return ArchiveVerifyContext(
        archive_manifest_id=parse_archive_verify_payload(value.payload).archive_manifest_id,
        artifact_kind="SIGNALS",
        storage_uri_hash=sha256_bytes(STORAGE_KEY.encode()),
        evidence=evidence(),
    )


def test_payload_rejects_parent_traversal_and_evidence_injection() -> None:
    value = dict(lease().payload)
    value["storage_key"] = "../signals.parquet"
    with pytest.raises(ArchiveVerifyError, match="normalized relative"):
        parse_archive_verify_payload(value)
    value = dict(lease().payload)
    value["row_count"] = 4
    with pytest.raises(ArchiveVerifyError, match="unexpected"):
        parse_archive_verify_payload(value)


def test_local_restorer_recomputes_real_parquet_evidence(tmp_path: Path) -> None:
    pa = pytest.importorskip("pyarrow")
    pq = pytest.importorskip("pyarrow.parquet")
    archive_path = tmp_path / "signals.parquet"
    start = datetime(2026, 1, 1, tzinfo=UTC)
    table = pa.Table.from_pylist(
        [{"signal_time": start}, {"signal_time": start + timedelta(hours=1)}]
    )
    pq.write_table(table, archive_path, compression="zstd")

    restored = LocalParquetArchiveRestorer(tmp_path).restore(
        "signals.parquet", "SIGNALS"
    )

    assert restored.row_count == 2
    assert restored.minimum_observed_at == start
    assert restored.maximum_observed_at == start + timedelta(hours=1)
    assert restored.object_size_bytes == archive_path.stat().st_size
    assert restored.content_sha256 == sha256_bytes(archive_path.read_bytes())


def test_local_restorer_reports_missing_object_with_bounded_error(tmp_path: Path) -> None:
    with pytest.raises(ArchiveVerifyError, match="unavailable"):
        LocalParquetArchiveRestorer(tmp_path).restore("missing.parquet", "SIGNALS")


@pytest.mark.asyncio
@pytest.mark.parametrize("matches", [True, False])
async def test_handler_records_database_match_decision(monkeypatch, matches: bool) -> None:
    task_lease = lease()
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context(task_lease))
    store.record_result = AsyncMock(return_value=matches)
    restorer = MagicMock()
    restorer.restore.return_value = evidence(content_hash="b" * 64)
    monkeypatch.setattr(
        "auto_trade.training.archive_verify_task_handler.DatabaseArchiveVerifyStore",
        lambda _connection: store,
    )

    result_hash = await ArchiveVerifyTaskHandler(MagicMock(), restorer)(task_lease)

    assert len(result_hash) == 64
    restorer.restore.assert_called_once_with(STORAGE_KEY, "SIGNALS")
    assert store.record_result.await_args.kwargs["restored"].content_sha256 == "b" * 64


@pytest.mark.asyncio
async def test_handler_rejects_storage_key_not_bound_to_manifest(monkeypatch) -> None:
    task_lease = lease()
    archive_context = context(task_lease)
    store = MagicMock()
    store.load_context = AsyncMock(
        return_value=ArchiveVerifyContext(
            archive_context.archive_manifest_id,
            archive_context.artifact_kind,
            "f" * 64,
            archive_context.evidence,
        )
    )
    store.record_result = AsyncMock()
    restorer = MagicMock()
    monkeypatch.setattr(
        "auto_trade.training.archive_verify_task_handler.DatabaseArchiveVerifyStore",
        lambda _connection: store,
    )

    with pytest.raises(ArchiveVerifyError, match="frozen manifest"):
        await ArchiveVerifyTaskHandler(MagicMock(), restorer)(task_lease)
    restorer.restore.assert_not_called()
    store.record_result.assert_not_awaited()


@pytest.mark.asyncio
async def test_handler_requires_evaluator_executor(monkeypatch) -> None:
    monkeypatch.setattr(
        "auto_trade.training.archive_verify_task_handler.DatabaseArchiveVerifyStore",
        lambda _connection: MagicMock(),
    )
    with pytest.raises(ArchiveVerifyError, match="EVALUATOR executor"):
        await ArchiveVerifyTaskHandler(MagicMock(), MagicMock())(
            lease(ExecutorKind.WORKER)
        )
