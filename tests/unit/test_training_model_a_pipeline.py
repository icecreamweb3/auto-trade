from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest

from auto_trade.strategies.feature_scan import FactorResult, StrategySignal
from auto_trade.training.contracts import Direction, Partition, PartitionKind
from auto_trade.training.model_a_pipeline import (
    BaselineCandidate,
    BaselineStratum,
    ModelAPipelineError,
    OpportunityRule,
    OutcomeBar,
    adapt_fixed_baseline_signal,
    calculate_entry_outcome,
    classify_opportunity,
    select_matched_random_baseline,
)


def _time(hour: int) -> datetime:
    return datetime(2026, 6, 1, hour, tzinfo=UTC)


def _adapted_signal():
    signal = StrategySignal(
        symbol="btcusdt",
        open_time=_time(1),
        close_price=Decimal("100"),
        factors={
            "available_factor": FactorResult(
                passed=True,
                value=Decimal("2.5"),
                threshold=">= 2",
                metrics={"window": 4},
                score=Decimal("80"),
                weight=Decimal("10"),
                contribution=Decimal("8"),
            ),
            "missing_factor": FactorResult(
                passed=False,
                value=None,
                threshold=">= 1",
                reason="OI unavailable",
                available=False,
            ),
        },
        score=Decimal("75"),
        grade="A",
        coverage_percent=Decimal("80"),
        trigger_reason="fixture",
    )
    return adapt_fixed_baseline_signal(
        signal,
        dataset_version_id=uuid4(),
        generating_version_id=uuid4(),
        instrument_id=1,
        interval_seconds=300,
        pool_evaluation_id=uuid4(),
        ticker_pool_rule_version_id=uuid4(),
        factor_registry_version_id=uuid4(),
        scan_parameters_version_id=uuid4(),
        input_fingerprint="a" * 64,
        entry_price=Decimal("101"),
    )


def test_feature_scan_adapter_preserves_diagnostics_and_next_bar_entry() -> None:
    adapted = _adapted_signal()
    assert adapted.event.symbol == "BTCUSDT"
    assert adapted.event.entry_time == adapted.event.signal_time + timedelta(minutes=5)
    assert adapted.event.theoretical_signal_price == Decimal("100")
    assert adapted.event.entry_price == Decimal("101")
    assert len(adapted.event.entry_event_id) == 64
    assert [factor.factor_name for factor in adapted.factors] == [
        "available_factor",
        "missing_factor",
    ]
    missing = adapted.factors[1]
    assert not missing.available
    assert missing.value is None
    assert missing.reason == "OI unavailable"


def test_feature_scan_adapter_is_deterministic_for_same_versions_and_signal() -> None:
    signal = StrategySignal(
        "BTCUSDT",
        _time(1),
        Decimal("100"),
        {"factor": FactorResult(True, Decimal(1), ">= 1")},
    )
    identifiers = {
        "dataset_version_id": uuid4(),
        "generating_version_id": uuid4(),
        "pool_evaluation_id": uuid4(),
        "ticker_pool_rule_version_id": uuid4(),
        "factor_registry_version_id": uuid4(),
        "scan_parameters_version_id": uuid4(),
    }
    first = adapt_fixed_baseline_signal(
        signal,
        instrument_id=1,
        interval_seconds=300,
        input_fingerprint="a" * 64,
        entry_price=Decimal("101"),
        **identifiers,
    )
    second = adapt_fixed_baseline_signal(
        signal,
        instrument_id=1,
        interval_seconds=300,
        input_fingerprint="a" * 64,
        entry_price=Decimal("101"),
        **identifiers,
    )
    assert first == second


def _partition() -> Partition:
    return Partition(
        PartitionKind.TRAIN,
        datetime(2026, 6, 1, tzinfo=UTC),
        datetime(2026, 6, 2, tzinfo=UTC),
    )


def test_complete_long_outcome_has_time_safe_mfe_mae_and_endpoint_return() -> None:
    outcome = calculate_entry_outcome(
        entry_event_id="e" * 64,
        partition=_partition(),
        entry_time=_time(1),
        entry_price=Decimal("100"),
        direction=Direction.LONG,
        label_window_end_at=_time(1) + timedelta(minutes=15),
        interval_seconds=300,
        bars=(
            OutcomeBar(
                _time(1) + timedelta(minutes=5), Decimal("103"), Decimal("99"), Decimal("102")
            ),
            OutcomeBar(
                _time(1) + timedelta(minutes=10), Decimal("105"), Decimal("98"), Decimal("104")
            ),
            OutcomeBar(
                _time(1) + timedelta(minutes=15), Decimal("104"), Decimal("101"), Decimal("103")
            ),
        ),
    )
    assert outcome.is_complete
    assert outcome.mfe_percent == Decimal("5.00")
    assert outcome.mae_percent == Decimal("2.00")
    assert outcome.return_percent == Decimal("3.00")
    assert outcome.mfe_reached_at == _time(1) + timedelta(minutes=10)
    assert outcome.endpoint_observed_at == outcome.label_window_end_at


def test_missing_label_bar_is_not_silently_converted_to_zero_or_loss() -> None:
    outcome = calculate_entry_outcome(
        entry_event_id="e" * 64,
        partition=_partition(),
        entry_time=_time(1),
        entry_price=Decimal("100"),
        direction=Direction.LONG,
        label_window_end_at=_time(1) + timedelta(minutes=15),
        interval_seconds=300,
        bars=(
            OutcomeBar(
                _time(1) + timedelta(minutes=5), Decimal("103"), Decimal("99"), Decimal("102")
            ),
            OutcomeBar(
                _time(1) + timedelta(minutes=15), Decimal("104"), Decimal("101"), Decimal("103")
            ),
        ),
    )
    assert not outcome.is_complete
    assert outcome.incomplete_reason == "MISSING_BARS"
    assert outcome.missing_bar_count == 1
    assert outcome.mfe_percent is None
    assert outcome.mae_percent is None
    assert outcome.return_percent is None


def test_short_outcome_uses_reversed_favorable_and_adverse_paths() -> None:
    outcome = calculate_entry_outcome(
        entry_event_id="e" * 64,
        partition=_partition(),
        entry_time=_time(1),
        entry_price=Decimal("100"),
        direction=Direction.SHORT,
        label_window_end_at=_time(1) + timedelta(minutes=5),
        interval_seconds=300,
        bars=(
            OutcomeBar(
                _time(1) + timedelta(minutes=5), Decimal("102"), Decimal("95"), Decimal("96")
            ),
        ),
    )
    assert outcome.mfe_percent == Decimal("5.00")
    assert outcome.mae_percent == Decimal("2.00")
    assert outcome.return_percent == Decimal("4.00")


def test_opportunity_truth_requires_complete_labels_and_explicit_rule() -> None:
    complete = calculate_entry_outcome(
        entry_event_id="e" * 64,
        partition=_partition(),
        entry_time=_time(1),
        entry_price=Decimal("100"),
        direction=Direction.LONG,
        label_window_end_at=_time(1) + timedelta(minutes=5),
        interval_seconds=300,
        bars=(
            OutcomeBar(
                _time(1) + timedelta(minutes=5), Decimal("106"), Decimal("99"), Decimal("104")
            ),
        ),
    )
    truth = classify_opportunity(
        complete,
        OpportunityRule(uuid4(), Decimal("5"), Decimal("2"), Decimal("3")),
    )
    assert truth.is_opportunity
    assert truth.reason_codes == ()

    incomplete = calculate_entry_outcome(
        entry_event_id="f" * 64,
        partition=_partition(),
        entry_time=_time(1),
        entry_price=Decimal("100"),
        direction=Direction.LONG,
        label_window_end_at=_time(1) + timedelta(minutes=5),
        interval_seconds=300,
        bars=(),
    )
    with pytest.raises(ModelAPipelineError, match="incomplete outcome"):
        classify_opportunity(
            incomplete,
            OpportunityRule(uuid4(), Decimal("5"), Decimal("2"), Decimal("3")),
        )


def test_matched_random_baseline_is_deterministic_and_excludes_signal_overlap() -> None:
    target = BaselineStratum(1, "pool-v1", "UTC-01", "VOL-2", "LIQ-3", "BTC-UP")
    candidates = (
        *(BaselineCandidate(f"candidate-{index}", _time(index), target) for index in range(1, 6)),
        BaselineCandidate(
            "wrong-regime",
            _time(6),
            BaselineStratum(1, "pool-v1", "UTC-01", "VOL-2", "LIQ-3", "BTC-DOWN"),
        ),
    )
    kwargs = {
        "matched_entry_event_id": "e" * 64,
        "target": target,
        "candidates": candidates,
        "signal_times_by_instrument": {1: (_time(2),)},
        "exclusion_window": timedelta(minutes=5),
        "sample_count": 2,
        "minimum_frame_size": 3,
        "random_seed": 42,
    }
    first = select_matched_random_baseline(**kwargs)
    second = select_matched_random_baseline(**kwargs)
    assert first == second
    assert first.sampling_frame_size == 4
    assert first.overlap_excluded_count == 1
    assert first.inclusion_probability == Decimal("0.5")
    assert "candidate-2" not in first.selected_candidate_ids
    assert "wrong-regime" not in first.selected_candidate_ids


def test_random_baseline_fails_closed_when_matched_frame_is_too_small() -> None:
    target = BaselineStratum(1, "pool-v1", "UTC-01", "VOL-2", "LIQ-3", "BTC-UP")
    with pytest.raises(ModelAPipelineError, match="below configured minimum"):
        select_matched_random_baseline(
            matched_entry_event_id="e" * 64,
            target=target,
            candidates=(BaselineCandidate("one", _time(1), target),),
            signal_times_by_instrument={},
            exclusion_window=timedelta(0),
            sample_count=1,
            minimum_frame_size=2,
            random_seed=1,
        )
