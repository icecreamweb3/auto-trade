from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/074_training_l0_opportunity_universe_indexes.sql"


def test_l0_uses_indexed_frozen_revisions_and_point_in_time_pool_index() -> None:
    sql = MIGRATION.read_text()

    assert "CREATE TEMP TABLE training_l0_opportunity_revisions" in sql
    assert "ON COMMIT DROP" in sql
    assert "CREATE UNIQUE INDEX ix_training_l0_opportunity_revisions_instrument_time" in sql
    assert "ANALYZE training_l0_opportunity_revisions" in sql
    assert "FROM training_l0_opportunity_revisions future" in sql
    assert "ix_training_historical_pool_dataset_instrument_time" in sql
    assert "dataset_version_id, instrument_id, evaluation_at DESC" in sql
    assert "training_historical_pool_evaluations evaluation" in sql


def test_l0_optimization_preserves_frozen_path_and_point_in_time_semantics() -> None:
    sql = MIGRATION.read_text()

    assert "bar.effective_at <= dataset_record.source_as_of_at" in sql
    assert "evaluation.evaluation_at <= signal.open_time" in sql
    assert "future.open_time >= candidate.entry_time" in sql
    assert "future.close_time <= candidate.entry_time" in sql
    assert "+ dataset_record.label_horizon_duration" in sql
    assert "ORDER BY future.close_time" in sql
    assert "INCOMPLETE_PATH" in sql
