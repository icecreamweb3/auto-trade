from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.archive import ArchiveEvidence


@dataclass(frozen=True, slots=True)
class ArchiveVerifyContext:
    archive_manifest_id: UUID
    artifact_kind: str
    storage_uri_hash: str
    evidence: ArchiveEvidence


class DatabaseArchiveVerifyStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(self, task_id: UUID, lease_token: UUID) -> ArchiveVerifyContext:
        result = await self._connection.execute(
            text(
                """
                SELECT archive_manifest_id, artifact_kind, storage_uri_hash,
                       row_count, minimum_observed_at, maximum_observed_at,
                       object_size_bytes, content_sha256
                FROM strategy_training.training_archive_verify_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = result.mappings().one()
        return ArchiveVerifyContext(
            archive_manifest_id=cast(UUID, row["archive_manifest_id"]),
            artifact_kind=str(row["artifact_kind"]),
            storage_uri_hash=str(row["storage_uri_hash"]),
            evidence=ArchiveEvidence(
                row_count=int(row["row_count"]),
                minimum_observed_at=cast(datetime, row["minimum_observed_at"]),
                maximum_observed_at=cast(datetime, row["maximum_observed_at"]),
                object_size_bytes=int(row["object_size_bytes"]),
                content_sha256=str(row["content_sha256"]),
            ),
        )

    async def record_result(
        self,
        *,
        task_id: UUID,
        lease_token: UUID,
        restored: ArchiveEvidence,
    ) -> bool:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_archive_verify_result(
                    :task_id, :lease_token, :row_count, :minimum_observed_at,
                    :maximum_observed_at, :object_size_bytes, :content_sha256
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "row_count": restored.row_count,
                "minimum_observed_at": restored.minimum_observed_at,
                "maximum_observed_at": restored.maximum_observed_at,
                "object_size_bytes": restored.object_size_bytes,
                "content_sha256": restored.content_sha256,
            },
        )
        return bool(result.scalar_one())
