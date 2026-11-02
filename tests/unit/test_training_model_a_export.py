from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from decimal import Decimal

import pytest

from auto_trade.training.model_a_export import ExportScalar, export_model_a_rows
from auto_trade.training.model_a_pipeline import ModelAPipelineError


class _FixtureParquetEncoder:
    def encode(self, rows: tuple[dict[str, ExportScalar], ...]) -> bytes:
        assert rows[0]["observed_at"] == "2026-06-01T01:00:00Z"
        return b"PAR1-fixture-PAR1"


def _rows():
    return (
        {
            "score": Decimal("75.00"),
            "entry_event_id": "a" * 64,
            "observed_at": datetime(2026, 6, 1, 1, tzinfo=UTC),
            "available": True,
        },
        {
            "score": Decimal("0"),
            "entry_event_id": "b" * 64,
            "observed_at": datetime(2026, 6, 1, 2, tzinfo=UTC),
            "available": False,
        },
    )


def test_jsonl_and_csv_exports_are_deterministic_and_hash_the_exact_bytes() -> None:
    first = export_model_a_rows(_rows(), output_format="jsonl")
    second = export_model_a_rows(_rows(), output_format="jsonl")
    csv_artifact = export_model_a_rows(_rows(), output_format="csv")

    assert first == second
    assert first.columns == ("available", "entry_event_id", "observed_at", "score")
    assert first.content.endswith(b"\n")
    assert first.content_hash == hashlib.sha256(first.content).hexdigest()
    assert csv_artifact.content.startswith(b"available,entry_event_id,observed_at,score\n")
    assert csv_artifact.canonical_rows_hash == first.canonical_rows_hash
    assert first.manifest()["record_count"] == 2


def test_parquet_export_uses_explicit_encoder_and_produces_manifest_hashes() -> None:
    artifact = export_model_a_rows(
        _rows(), output_format="parquet", parquet_encoder=_FixtureParquetEncoder()
    )
    assert artifact.content == b"PAR1-fixture-PAR1"
    assert artifact.extension == "parquet"
    assert artifact.content_hash == hashlib.sha256(artifact.content).hexdigest()


def test_exports_fail_closed_on_schema_drift_or_naive_time() -> None:
    with pytest.raises(ModelAPipelineError, match="same columns"):
        export_model_a_rows(({"a": 1}, {"b": 2}), output_format="jsonl")
    with pytest.raises(ModelAPipelineError, match="timezone-aware"):
        export_model_a_rows(({"observed_at": datetime(2026, 6, 1)},), output_format="jsonl")
