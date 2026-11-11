from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/105_training_l0_cross_fit_budget.sql"


def test_cross_fit_l0_uses_frozen_optimizer_scope_budget() -> None:
    sql = MIGRATION.read_text()

    assert "training_cross_fit_optimizer_scopes" in sql
    assert "scope.wall_clock_budget_seconds" in sql
    assert "optimizer.started_at" in sql
    assert "resource_budget_value ->> 'optimizer_run_id'" in sql
    assert "optimizer.experiment_id = iteration_experiment_id" in sql


def test_non_cross_fit_l0_keeps_explicit_iteration_budget_fallback() -> None:
    sql = MIGRATION.read_text()

    assert "resource_budget_value ->> 'maximum_wall_clock_seconds'" in sql
    assert "budget_started_at := task_record.started_at" in sql


def test_l0_timeout_is_remaining_budget_not_a_fresh_task_budget() -> None:
    sql = MIGRATION.read_text()

    assert "clock_timestamp() - budget_started_at" in sql
    assert "model-A L0 wall-clock budget exhausted" in sql
    assert "set_config(" in sql
    assert "'statement_timeout', remaining_milliseconds::text, true" in sql
