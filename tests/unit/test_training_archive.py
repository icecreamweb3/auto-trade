from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from auto_trade.training.archive import (
    ArchiveContractError,
    ArchiveEvidence,
    sha256_bytes,
    verify_restored_archive,
)


def test_archive_restore_requires_exact_hash_size_rows_and_range() -> None:
    payload = b"parquet-zstd-fixture"
    start = datetime(2026, 1, 1, tzinfo=UTC)
    end = start + timedelta(hours=1)
    evidence = ArchiveEvidence(4, start, end, len(payload), sha256_bytes(payload))
    assert verify_restored_archive(
        evidence,
        restored_payload=payload,
        restored_row_count=4,
        restored_minimum_observed_at=start,
        restored_maximum_observed_at=end,
    ) == sha256_bytes(payload)


def test_archive_restore_fails_closed_on_any_mismatch() -> None:
    payload = b"parquet-zstd-fixture"
    observed_at = datetime(2026, 1, 1, tzinfo=UTC)
    evidence = ArchiveEvidence(4, observed_at, observed_at, len(payload), sha256_bytes(payload))
    with pytest.raises(ArchiveContractError, match="does not match"):
        verify_restored_archive(
            evidence,
            restored_payload=payload + b"tampered",
            restored_row_count=4,
            restored_minimum_observed_at=observed_at,
            restored_maximum_observed_at=observed_at,
        )
