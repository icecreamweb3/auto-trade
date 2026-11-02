from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum


class ArchiveContractError(ValueError):
    pass


class ArchiveFormat(StrEnum):
    PARQUET = "PARQUET"


class ArchiveCompression(StrEnum):
    ZSTD = "ZSTD"


@dataclass(frozen=True, slots=True)
class ArchiveEvidence:
    row_count: int
    minimum_observed_at: datetime
    maximum_observed_at: datetime
    object_size_bytes: int
    content_sha256: str
    format: ArchiveFormat = ArchiveFormat.PARQUET
    compression: ArchiveCompression = ArchiveCompression.ZSTD

    def __post_init__(self) -> None:
        if self.row_count <= 0 or self.object_size_bytes <= 0:
            raise ArchiveContractError("archive row count and size must be positive")
        if self.minimum_observed_at > self.maximum_observed_at:
            raise ArchiveContractError("archive time range is reversed")
        if self.minimum_observed_at.tzinfo is None or self.maximum_observed_at.tzinfo is None:
            raise ArchiveContractError("archive time range must be timezone-aware")
        if len(self.content_sha256) != 64 or any(
            char not in "0123456789abcdef" for char in self.content_sha256
        ):
            raise ArchiveContractError("archive SHA-256 is invalid")


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def verify_restored_archive(
    expected: ArchiveEvidence,
    *,
    restored_payload: bytes,
    restored_row_count: int,
    restored_minimum_observed_at: datetime,
    restored_maximum_observed_at: datetime,
) -> str:
    restored_hash = sha256_bytes(restored_payload)
    if (
        restored_hash != expected.content_sha256
        or len(restored_payload) != expected.object_size_bytes
        or restored_row_count != expected.row_count
        or restored_minimum_observed_at != expected.minimum_observed_at
        or restored_maximum_observed_at != expected.maximum_observed_at
    ):
        raise ArchiveContractError("restored archive does not match its frozen manifest")
    return restored_hash
