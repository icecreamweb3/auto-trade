from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "database/067_training_random_baseline_version_progression.sql"


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
