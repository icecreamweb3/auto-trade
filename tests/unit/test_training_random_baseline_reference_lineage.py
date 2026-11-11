from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/102_training_random_baseline_reference_lineage.sql"


def test_reference_iteration_uniqueness_applies_only_to_root_references() -> None:
    sql = MIGRATION.read_text()

    assert "DROP CONSTRAINT" in sql
    assert (
        "training_random_baseline_reference_s_reference_iteration_id_key" in sql
    )
    assert "ux_training_random_baseline_root_reference_iteration" in sql
    assert "WHERE source_reference_set_id IS NULL" in sql
