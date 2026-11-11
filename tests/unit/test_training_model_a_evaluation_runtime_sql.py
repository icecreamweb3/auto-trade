from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/104_training_model_a_evaluation_runtime.sql"


def test_evaluation_runtime_adds_reverse_evidence_index() -> None:
    sql = MIGRATION.read_text()

    assert "matched_entry_event_id,\n    candidate_id" in sql
    assert "INCLUDE (path_fingerprint, is_complete)" in sql


def test_evaluation_contexts_do_not_copy_large_task_payloads() -> None:
    sql = MIGRATION.read_text()

    assert "training_tasks%ROWTYPE" not in sql
    assert "SELECT task.iteration_id" in sql
    assert sql.count("task.lease_expires_at > clock_timestamp()") == 2


def test_frozen_reference_context_does_not_rebuild_unused_signal_times() -> None:
    sql = MIGRATION.read_text()

    assert "ARRAY[]::timestamptz[]" in sql
    assert "ARRAY(SELECT signal.signal_time" not in sql
    assert "config.semver::text NOT IN ('0.1.0', '0.1.1')" in sql
