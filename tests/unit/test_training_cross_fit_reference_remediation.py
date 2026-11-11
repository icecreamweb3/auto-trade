from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/103_training_cross_fit_reference_remediation.sql"


def test_reference_remediation_requires_exact_immutable_lineage() -> None:
    sql = MIGRATION.read_text()

    for required in (
        "previous_config.config_json - 'reference_set_id'",
        "replacement_config.config_json - 'reference_set_id'",
        "replacement_config.parent_version_id",
        "COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF",
        "replacement_reference.source_reference_set_id",
        "MODEL_A_EVALUATION_REJECTED",
        "MODEL_A_EVALUATION_FAILED",
    ):
        assert required in sql


def test_reference_remediation_rejects_live_leases_and_audits_cancellation() -> None:
    sql = MIGRATION.read_text()

    assert "task.lease_expires_at >= clock_timestamp()" in sql
    assert "RANDOM_BASELINE_REFERENCE_REMEDIATED" in sql
    assert "training_task_events" in sql
    assert "cancelled_task_count" in sql
    assert "failed_evaluation_count" in sql


def test_replacement_binds_only_the_approved_random_baseline_override() -> None:
    sql = MIGRATION.read_text()

    assert "binding.config_type <> 'RANDOM_BASELINE'" in sql
    assert "replacement_config.config_version_id" in sql
    assert "bound_count < 20" in sql
    assert "create_cross_fit_execution" in sql
    assert "training_cross_fit_reference_remediations" in sql
    assert "reject_training_append_only_mutation" in sql
