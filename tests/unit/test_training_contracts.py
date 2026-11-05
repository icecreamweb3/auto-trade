from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import UUID

import pytest

from auto_trade.training.contracts import (
    DatasetStatus,
    Direction,
    EntryEventIdentity,
    EntrySource,
    EntrySourceNotAllowedError,
    EntryUse,
    InvalidStateTransitionError,
    InvalidTimeBoundaryError,
    IterationStatus,
    ModelStatus,
    Partition,
    PartitionKind,
    assert_entry_source_allowed,
    assert_transition,
    build_entry_event_id,
    build_test_scope_hash,
)
from auto_trade.training.contracts import TestStatus as TrainingTestStatus


def utc_datetime(day: int, hour: int = 0) -> datetime:
    return datetime(2026, 8, day, hour, tzinfo=UTC)


def test_partition_is_left_closed_and_right_open() -> None:
    partition = Partition(PartitionKind.TRAIN, utc_datetime(1), utc_datetime(31))

    assert partition.contains(utc_datetime(1))
    assert partition.contains(utc_datetime(30, 23))
    assert not partition.contains(utc_datetime(31))


def test_partition_rejects_non_utc_and_invalid_ranges() -> None:
    with pytest.raises(InvalidTimeBoundaryError, match="timezone-aware UTC"):
        Partition(PartitionKind.TRAIN, datetime(2026, 8, 1), utc_datetime(31))

    with pytest.raises(InvalidTimeBoundaryError, match="before"):
        Partition(PartitionKind.TRAIN, utc_datetime(31), utc_datetime(1))


def test_effective_entry_end_uses_larger_label_or_holding_horizon() -> None:
    partition = Partition(PartitionKind.TRAIN, utc_datetime(1), utc_datetime(31))

    assert partition.effective_entry_end(
        label_horizon=timedelta(hours=24),
        max_holding_horizon=timedelta(hours=36),
    ) == datetime(2026, 8, 29, 12, tzinfo=UTC)


def test_label_window_may_equal_but_not_exceed_partition_end() -> None:
    partition = Partition(PartitionKind.TRAIN, utc_datetime(1), utc_datetime(31))

    partition.assert_label_window(signal_time=utc_datetime(30), label_window_end=utc_datetime(31))
    with pytest.raises(InvalidTimeBoundaryError, match="exceeds"):
        partition.assert_label_window(
            signal_time=utc_datetime(30),
            label_window_end=datetime(2026, 8, 31, 0, 0, 1, tzinfo=UTC),
        )


@pytest.mark.parametrize(
    ("source", "usage"),
    [
        (EntrySource.IN_SAMPLE_MODEL_A, EntryUse.MODEL_A_DISCOVERY),
        (EntrySource.FIXED_BASELINE_MODEL_A, EntryUse.MODEL_B_PROTOTYPE),
        (EntrySource.CROSS_FIT_MODEL_A_CANDIDATE, EntryUse.GO_NO_GO),
        (EntrySource.CROSS_FIT_MODEL_A, EntryUse.MODEL_B_TRAIN),
        (EntrySource.ADVERSE_OR_RANGE_CONTROL, EntryUse.MODEL_B_TRAIN),
        (EntrySource.LOCKED_MODEL_A_VALIDATION_SIGNAL, EntryUse.VALIDATION),
        (EntrySource.MODEL_A_SIGNAL, EntryUse.END_TO_END_TEST),
    ],
)
def test_entry_source_allowlist_accepts_only_workflow_sources(
    source: EntrySource,
    usage: EntryUse,
) -> None:
    assert_entry_source_allowed(source=source, usage=usage)


@pytest.mark.parametrize(
    "usage",
    [EntryUse.MODEL_B_TRAIN, EntryUse.VALIDATION, EntryUse.END_TO_END_TEST],
)
def test_cross_fit_candidate_cannot_enter_formal_workflows(usage: EntryUse) -> None:
    with pytest.raises(EntrySourceNotAllowedError):
        assert_entry_source_allowed(
            source=EntrySource.CROSS_FIT_MODEL_A_CANDIDATE,
            usage=usage,
        )


@pytest.mark.parametrize("source", list(EntrySource))
def test_end_to_end_test_accepts_only_runtime_model_a_signal(source: EntrySource) -> None:
    if source is EntrySource.MODEL_A_SIGNAL:
        assert_entry_source_allowed(source=source, usage=EntryUse.END_TO_END_TEST)
    else:
        with pytest.raises(EntrySourceNotAllowedError):
            assert_entry_source_allowed(source=source, usage=EntryUse.END_TO_END_TEST)


def test_state_transitions_are_forward_only() -> None:
    assert_transition(DatasetStatus.BUILDING, DatasetStatus.READY)
    assert_transition(IterationStatus.CREATED, IterationStatus.VALIDATING)
    assert_transition(ModelStatus.DRAFT, ModelStatus.LOCKED)
    assert_transition(TrainingTestStatus.SEALED, TrainingTestStatus.CONSUMED)

    with pytest.raises(InvalidStateTransitionError):
        assert_transition(DatasetStatus.READY, DatasetStatus.BUILDING)
    with pytest.raises(InvalidStateTransitionError):
        assert_transition(ModelStatus.LOCKED, ModelStatus.DRAFT)
    with pytest.raises(InvalidStateTransitionError):
        assert_transition(TrainingTestStatus.CONSUMED, TrainingTestStatus.SEALED)


def test_entry_event_id_is_deterministic_and_version_specific() -> None:
    identity = EntryEventIdentity(
        dataset_version_id=UUID("10000000-0000-0000-0000-000000000001"),
        generating_version_id=UUID("20000000-0000-0000-0000-000000000001"),
        symbol="btcusdt",
        signal_time=utc_datetime(10, 12),
        entry_time=datetime(2026, 8, 10, 12, 5, tzinfo=UTC),
        direction=Direction.LONG,
    )

    first = build_entry_event_id(identity)
    second = build_entry_event_id(identity)
    changed_version = build_entry_event_id(
        EntryEventIdentity(
            dataset_version_id=identity.dataset_version_id,
            generating_version_id=UUID("20000000-0000-0000-0000-000000000002"),
            symbol=identity.symbol,
            signal_time=identity.signal_time,
            entry_time=identity.entry_time,
            direction=identity.direction,
        )
    )

    assert first == second
    assert len(first) == 64
    assert changed_version != first


def test_entry_event_id_matches_database_contract_for_unicode_symbol() -> None:
    identity = EntryEventIdentity(
        dataset_version_id=UUID("d3000000-0000-0000-0000-000000000001"),
        generating_version_id=UUID("d5000000-0000-0000-0000-000000000001"),
        symbol="币安人生USDT",
        signal_time=datetime(2026, 6, 10, 1, 0, tzinfo=UTC),
        entry_time=datetime(2026, 6, 10, 1, 5, tzinfo=UTC),
        direction=Direction.LONG,
    )

    assert build_entry_event_id(identity) == (
        "6bac89616a9486546c4c5ef967d458f230b8850bbe16824823c9e2c228ab034d"
    )


def test_test_scope_hash_excludes_content_and_code_by_contract() -> None:
    arguments = {
        "start_at": datetime(2026, 11, 1, tzinfo=UTC),
        "end_at": datetime(2026, 12, 1, tzinfo=UTC),
        "ticker_pool_rule_version": "ticker-pool-v1",
        "controlled_purpose": "FORMAL_END_TO_END_TEST",
    }

    assert build_test_scope_hash(**arguments) == build_test_scope_hash(**arguments)
    assert build_test_scope_hash(**arguments) != build_test_scope_hash(
        **{**arguments, "ticker_pool_rule_version": "ticker-pool-v2"}
    )
