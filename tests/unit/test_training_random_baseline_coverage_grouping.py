from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/072_training_random_baseline_coverage_grouping.sql"


def test_date_distribution_groups_by_the_unformatted_date_expression() -> None:
    sql = MIGRATION.read_text()

    assert "FROM entries GROUP BY signal_time::date) grouped" in sql
    assert "FROM entries GROUP BY 1) grouped" not in sql
