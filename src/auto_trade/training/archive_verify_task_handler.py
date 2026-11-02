"""ARCHIVE_VERIFY v1 isolated local Parquet restore handler."""

from __future__ import annotations

import hashlib
import json
import os
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Protocol, cast
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.archive import ArchiveContractError, ArchiveEvidence, sha256_bytes
from auto_trade.training.archive_verify_repository import DatabaseArchiveVerifyStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class ArchiveVerifyError(RuntimeError):
    """The leased archive cannot be restored and independently inspected."""


@dataclass(frozen=True, slots=True)
class ArchiveVerifyTaskPayload:
    archive_manifest_id: UUID
    storage_key: str


class ArchiveRestorer(Protocol):
    def restore(self, storage_key: str, artifact_kind: str) -> ArchiveEvidence: ...


_OBSERVED_AT_COLUMNS = {
    "SIGNALS": "signal_time",
    "DECISIONS": "decision_time",
    "FILLS": "fill_time",
    "EQUITY_POINTS": "observed_at",
}


def parse_archive_verify_payload(payload: Mapping[str, object]) -> ArchiveVerifyTaskPayload:
    allowed = {"task_type", "payload_version", "archive_manifest_id", "storage_key"}
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise ArchiveVerifyError("unexpected ARCHIVE_VERIFY fields: " + ", ".join(unexpected))
    if payload.get("task_type") != "ARCHIVE_VERIFY" or payload.get("payload_version") != 1:
        raise ArchiveVerifyError("ARCHIVE_VERIFY requires payload_version 1")
    manifest_id = payload.get("archive_manifest_id")
    storage_key = payload.get("storage_key")
    if not isinstance(manifest_id, str) or not isinstance(storage_key, str):
        raise ArchiveVerifyError("archive_manifest_id and storage_key must be strings")
    try:
        parsed_manifest_id = UUID(manifest_id)
    except ValueError as error:
        raise ArchiveVerifyError("archive_manifest_id must be a UUID") from error
    normalized = PurePosixPath(storage_key)
    if (
        not storage_key.strip()
        or normalized.is_absolute()
        or ".." in normalized.parts
        or str(normalized) != storage_key
    ):
        raise ArchiveVerifyError("storage_key must be a normalized relative path")
    return ArchiveVerifyTaskPayload(parsed_manifest_id, storage_key)


class LocalParquetArchiveRestorer:
    def __init__(self, root: Path | None = None) -> None:
        configured = root or Path(os.environ.get("TRAINING_ARCHIVE_ROOT", ""))
        self._root = configured if str(configured) not in {"", "."} else None

    def restore(self, storage_key: str, artifact_kind: str) -> ArchiveEvidence:
        if self._root is None:
            raise ArchiveVerifyError("TRAINING_ARCHIVE_ROOT is not configured")
        try:
            root = self._root.resolve(strict=True)
            archive_path = (root / storage_key).resolve(strict=True)
        except OSError as error:
            raise ArchiveVerifyError("archive object is unavailable") from error
        if not archive_path.is_relative_to(root) or not archive_path.is_file():
            raise ArchiveVerifyError("archive object is outside the configured root")
        try:
            import pyarrow as pa  # type: ignore[import-not-found]
            import pyarrow.parquet as pq  # type: ignore[import-not-found]
            from pyarrow.lib import ArrowException  # type: ignore[import-not-found]
        except ImportError as error:
            raise ArchiveVerifyError("archive verification requires training-export") from error
        try:
            payload = archive_path.read_bytes()
            observed_at_column = _OBSERVED_AT_COLUMNS[artifact_kind]
            table = pq.read_table(pa.BufferReader(payload), columns=[observed_at_column])
            observed_values = table.column(observed_at_column).to_pylist()
        except (ArrowException, KeyError, OSError, ValueError) as error:
            raise ArchiveVerifyError("archive object cannot be inspected") from error
        if not observed_values or any(not isinstance(value, datetime) for value in observed_values):
            raise ArchiveVerifyError("archive observed-at column is empty or invalid")
        datetimes = cast(list[datetime], observed_values)
        if any(value.tzinfo is None or value.utcoffset() is None for value in datetimes):
            raise ArchiveVerifyError("archive observed-at values must be timezone-aware")
        return ArchiveEvidence(
            row_count=table.num_rows,
            minimum_observed_at=min(datetimes),
            maximum_observed_at=max(datetimes),
            object_size_bytes=len(payload),
            content_sha256=sha256_bytes(payload),
        )


def _result_hash(manifest_id: UUID, restored: ArchiveEvidence, matches: bool) -> str:
    canonical = json.dumps(
        {
            "archive_manifest_id": str(manifest_id),
            "content_sha256": restored.content_sha256,
            "matches": matches,
            "maximum_observed_at": restored.maximum_observed_at.isoformat(),
            "minimum_observed_at": restored.minimum_observed_at.isoformat(),
            "object_size_bytes": restored.object_size_bytes,
            "row_count": restored.row_count,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(canonical).hexdigest()


class ArchiveVerifyTaskHandler:
    def __init__(
        self,
        connection: AsyncConnection,
        restorer: ArchiveRestorer | None = None,
    ) -> None:
        self._store = DatabaseArchiveVerifyStore(connection)
        self._restorer = restorer or LocalParquetArchiveRestorer()

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise ArchiveVerifyError("ARCHIVE_VERIFY requires EVALUATOR executor")
        payload = parse_archive_verify_payload(lease.payload)
        context = await self._store.load_context(lease.task_id, lease.lease_token)
        if payload.archive_manifest_id != context.archive_manifest_id:
            raise ArchiveVerifyError("payload manifest differs from leased context")
        if sha256_bytes(payload.storage_key.encode()) != context.storage_uri_hash:
            raise ArchiveVerifyError("storage_key differs from frozen manifest")
        try:
            restored = self._restorer.restore(payload.storage_key, context.artifact_kind)
        except ArchiveContractError as error:
            raise ArchiveVerifyError("restored archive evidence is invalid") from error
        matches = await self._store.record_result(
            task_id=lease.task_id,
            lease_token=lease.lease_token,
            restored=restored,
        )
        return _result_hash(context.archive_manifest_id, restored, matches)
