from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/076_training_l0_daily_pool_validity.sql"


def test_l0_daily_pool_evaluation_does_not_carry_into_later_days() -> None:
    sql = MIGRATION.read_text()

    assert "evaluation.evaluation_at <= signal.open_time" in sql
    assert (
        "signal.open_time < evaluation.evaluation_at + interval '1 day'" in sql
    )
    assert "ORDER BY evaluation.evaluation_at DESC LIMIT 1" in sql


def test_l0_daily_pool_fix_is_guarded_and_keeps_evaluator_only_execution() -> None:
    sql = MIGRATION.read_text()

    assert "pg_get_functiondef" in sql
    assert "does not match the reviewed pre-076 definition" in sql
    assert "REVOKE ALL ON FUNCTION" in sql
    assert "TO tb2_training_evaluator" in sql
