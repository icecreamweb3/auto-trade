from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/101_training_random_baseline_complete_paths.sql"


def test_complete_path_reference_keeps_legacy_audit_but_not_runtime_access() -> None:
    sql = MIGRATION.read_text()

    assert "LEGACY_UNFILTERED" in sql
    assert "COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF" in sql
    assert "source_reference_set_id" in sql
    assert "seal_training_random_baseline_reference_set_legacy" in sql
    assert "REVOKE EXECUTE ON FUNCTION" in sql
    assert "FROM tb2_training_rw" in sql


def test_candidate_path_evidence_is_snapshot_bound_and_append_only() -> None:
    sql = MIGRATION.read_text()

    for required in (
        "training_random_baseline_reference_candidate_paths",
        "dataset.source_as_of_at",
        "bar.effective_at <= candidate.source_as_of_at",
        "bar.quality_status = 'VALID'",
        "bar.is_closed",
        "expected_bar_count",
        "observed_bar_count",
        "endpoint_observed_at",
        "reject_training_append_only_mutation",
    ):
        assert required in sql


def test_new_ready_configs_and_bindings_require_complete_path_reference() -> None:
    sql = MIGRATION.read_text()

    assert "guard_training_random_baseline_complete_path_config" in sql
    assert "guard_training_random_baseline_complete_path_binding" in sql
    assert "READY RANDOM_BASELINE requires a complete-path reference set" in sql
    assert "new RANDOM_BASELINE binding requires a complete-path reference set" in sql
