from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/067_training_random_baseline_version_progression.sql"
BINDING_MIGRATION = (
    ROOT / "database/068_training_random_baseline_binding_progression.sql"
)
REBUILD_MIGRATION = (
    ROOT / "database/069_training_random_baseline_reference_rebuild.sql"
)
PROBABILITY_MIGRATION = (
    ROOT / "database/070_training_random_baseline_probability_precision.sql"
)


def test_new_reference_versions_are_not_pinned_to_0_1_2() -> None:
    sql = MIGRATION.read_text()

    assert "config.semver::text = '0.1.2'" not in sql
    assert "NEW.semver::text <> '0.1.2'" not in sql
    assert sql.count("NOT IN ('0.1.0', '0.1.1')") == 2
    assert "NEW.semver::text IN ('0.1.0', '0.1.1')" in sql


def test_frozen_policy_and_reference_binding_remain_mandatory() -> None:
    sql = MIGRATION.read_text()

    for required in (
        "'SEEDED_SHA256_PER_STRATUM'",
        "'EXCLUDE_AND_REPORT'",
        "'FEASIBILITY_AND_COVERAGE_ONLY_NO_OUTCOME_METRICS'",
        "'reference_set_id'",
        "minimum_valid_fold_count",
        "minimum_effective_day_count",
        "minimum_evaluable_events_per_fold",
    ):
        assert required in sql


def test_experiment_binding_accepts_new_reference_versions_only() -> None:
    sql = BINDING_MIGRATION.read_text()

    assert "config.semver::text = '0.1.2'" not in sql
    assert "config.semver::text NOT IN ('0.1.0', '0.1.1')" in sql
    assert "reference_set.status = 'READY'" in sql
    assert "config.status = 'READY'" in sql


def test_reference_rebuild_context_exposes_the_frozen_dataset() -> None:
    sql = REBUILD_MIGRATION.read_text()

    assert "training_model_a_candidate_scan_random_context" in sql
    assert "reference_set.dataset_version_id" in sql
    assert "reference_set.status = 'READY'" in sql
    assert "TO tb2_training_rw" in sql


def test_probability_guard_uses_persisted_numeric_scale() -> None:
    sql = PROBABILITY_MIGRATION.read_text()

    assert "expected_inclusion_probability numeric(18, 12)" in sql
    assert "selected_count::numeric / p_sampling_frame_size" in sql
    assert "p_inclusion_probability <> expected_inclusion_probability" in sql
