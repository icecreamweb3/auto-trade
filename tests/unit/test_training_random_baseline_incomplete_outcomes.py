from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/073_training_random_baseline_incomplete_outcomes.sql"


def test_incomplete_outcomes_are_explicit_coverage_exclusions() -> None:
    sql = MIGRATION.read_text()

    assert "JOIN strategy_training.training_entry_outcomes outcome" in sql
    assert "OR NOT outcome.is_complete" in sql
    assert "'ENTRY_OUTCOME_' || outcome.incomplete_reason" in sql
    assert "'by_exclusion_reason'" in sql
    assert "FROM entries GROUP BY signal_time::date) grouped" in sql
