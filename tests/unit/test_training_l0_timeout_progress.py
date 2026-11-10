from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/075_training_l0_timeout_progress.sql"


def test_l0_timeout_uses_remaining_iteration_wall_clock_budget() -> None:
    sql = MIGRATION.read_text()

    assert "configure_training_l0_statement_timeout" in sql
    assert "maximum_wall_clock_seconds" in sql
    assert "budget_seconds IS NULL OR budget_seconds <= 0" in sql
    assert "clock_timestamp() - task_record.started_at" in sql
    assert "set_config('statement_timeout', remaining_milliseconds::text, true)" in sql
    assert "ERRCODE = '57014'" in sql


def test_l0_logs_queryable_bottleneck_stages_with_counts_and_durations() -> None:
    sql = MIGRATION.read_text()

    for stage in (
        "KLINES_FREEZE_STARTED",
        "KLINES_FREEZE_COMPLETED",
        "KLINE_INDEX_COMPLETED",
        "CANDIDATES_COMPLETED",
        "PATH_AGGREGATION_STARTED",
        "PATH_AGGREGATION_COMPLETED",
        "UNIVERSE_SEALED",
        "UNIVERSE_REUSED",
    ):
        assert stage in sql
    assert "stage_seconds" in sql
    assert "total_seconds" in sql
    assert "GET DIAGNOSTICS revision_count = ROW_COUNT" in sql
    assert "GET DIAGNOSTICS candidate_count = ROW_COUNT" in sql
