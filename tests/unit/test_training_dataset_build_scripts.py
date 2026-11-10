from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_extended_train_wrapper_freezes_approved_range() -> None:
    script = (ROOT / "scripts/build-extended-train-dataset.sql").read_text()

    assert "\\set eligible_start '2026-08-01 00:00:00+00'" in script
    assert "\\set dataset_eligible_end '2026-09-15 00:00:00+00'" in script
    assert "\\set label_window_end '2026-09-16 00:00:00+00'" in script
    assert "\\set partition_end '2026-09-16 00:00:00+00'" in script
    assert "\\set supersedes_dataset_id ''" in script
    assert "\\ir build-august-train-dataset.sql" in script


def test_shared_train_builder_keeps_august_defaults_overridable() -> None:
    script = (ROOT / "scripts/build-august-train-dataset.sql").read_text()

    for variable in (
        "warmup_start",
        "dataset_eligible_end",
        "label_window_end",
        "partition_end",
        "source_as_of",
        "dataset_builder",
        "run_command",
    ):
        assert f"\\if :{{?{variable}}}" in script

    assert "NULLIF(:'supersedes_dataset_id', '')::uuid" in script
    assert "\\quit 3" in script
