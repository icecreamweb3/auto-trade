from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/106_training_cross_fit_protocol_retirement_guard.sql"


def test_active_cross_fit_execution_blocks_protocol_retirement() -> None:
    sql = MIGRATION.read_text()

    assert "OLD.config_type = 'CROSS_FIT_PROTOCOL'" in sql
    assert "OLD.status = 'READY'" in sql
    assert "NEW.status = 'RETIRED'" in sql
    assert "execution.protocol_config_version_id = OLD.config_version_id" in sql
    assert "execution.completed_at IS NULL" in sql
    assert "ERRCODE = '23514'" in sql


def test_protocol_retirement_guard_runs_for_status_updates() -> None:
    sql = MIGRATION.read_text()

    assert "BEFORE UPDATE OF status" in sql
    assert "WHEN (OLD.status IS DISTINCT FROM NEW.status)" in sql
    assert "guard_active_cross_fit_protocol_retirement()" in sql
