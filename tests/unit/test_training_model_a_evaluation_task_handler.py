from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.training.contracts import Direction, Partition, PartitionKind
from auto_trade.training.model_a_evaluation_repository import (
    EntryEvaluationContext,
    ExistingEntryEvidence,
    RandomBaselineEvaluationContext,
    RandomCandidateOutcomeContext,
)
from auto_trade.training.model_a_evaluation_task_handler import (
    ModelAEvaluationTaskHandler,
    parse_model_a_evaluation_payload,
)
from auto_trade.training.model_a_pipeline import (
    BaselineCandidate,
    BaselineStratum,
    ModelAPipelineError,
    OutcomeBar,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease

ENTRY_ID = "a" * 64
CANDIDATE_ID = "d" * 64


def payload(*entry_ids: str) -> dict[str, object]:
    return {
        "task_type": "MODEL_A_EVALUATION",
        "payload_version": 1,
        "entry_event_ids": list(entry_ids or (ENTRY_ID,)),
    }


def lease(value: dict[str, object], kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        value,
    )


def context() -> EntryEvaluationContext:
    start = datetime(2026, 6, 1, tzinfo=UTC)
    return EntryEvaluationContext(
        ENTRY_ID,
        Partition(PartitionKind.TRAIN, start, start + timedelta(days=1)),
        start + timedelta(hours=1),
        Decimal("100"),
        Direction.LONG,
        start + timedelta(hours=1, minutes=5),
        300,
        uuid4(),
        uuid4(),
    )


def baseline_context() -> RandomBaselineEvaluationContext:
    target = BaselineStratum(1, "pool-v1", "UTC-01", "VOL-2", "LIQ-3", "BTC-UP")
    return RandomBaselineEvaluationContext(
        uuid4(), 1, 1, 0, 42, target, ()
    )


def baseline_candidates() -> tuple[BaselineCandidate, ...]:
    baseline = baseline_context()
    return (
        BaselineCandidate(CANDIDATE_ID, context().entry_time, baseline.target),
    )


def random_candidate_context() -> RandomCandidateOutcomeContext:
    base = context()
    return RandomCandidateOutcomeContext(
        CANDIDATE_ID,
        base.partition,
        base.entry_time,
        base.entry_price,
        base.direction,
        base.label_window_end_at,
        base.interval_seconds,
        base.holding_rule_version_id,
    )


def test_payload_requires_sorted_unique_sha256_ids() -> None:
    assert parse_model_a_evaluation_payload(payload()).entry_event_ids == (ENTRY_ID,)
    with pytest.raises(ModelAPipelineError, match="unique and sorted"):
        parse_model_a_evaluation_payload(payload("b" * 64, ENTRY_ID))
    with pytest.raises(ModelAPipelineError, match="SHA-256"):
        parse_model_a_evaluation_payload(payload("not-an-id"))


def test_payload_rejects_future_or_baseline_inputs() -> None:
    value = payload()
    value["future_bars"] = []
    with pytest.raises(ModelAPipelineError, match="unexpected"):
        parse_model_a_evaluation_payload(value)


@pytest.mark.asyncio
async def test_fresh_complete_outcome_records_label_and_opportunity(monkeypatch) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context())
    store.load_existing_evidence = AsyncMock(return_value=None)
    store.load_outcome_bars = AsyncMock(
        return_value=(
            OutcomeBar(
                context().label_window_end_at,
                Decimal("105"),
                Decimal("99"),
                Decimal("104"),
            ),
        )
    )
    store.record_outcome = AsyncMock()
    store.record_opportunity = AsyncMock()
    store.load_random_baseline_context = AsyncMock(return_value=baseline_context())
    store.load_random_baseline_candidates = AsyncMock(return_value=baseline_candidates())
    store.load_random_candidate_outcome_context = AsyncMock(
        return_value=random_candidate_context()
    )
    store.load_random_candidate_outcome_bars = AsyncMock(
        return_value=(
            OutcomeBar(
                context().label_window_end_at,
                Decimal("103"),
                Decimal("98"),
                Decimal("102"),
            ),
        )
    )
    store.record_random_candidate_outcome = AsyncMock()
    store.record_random_baseline = AsyncMock()
    store.finalize_random_baseline_coverage = AsyncMock(return_value="READY")
    monkeypatch.setattr(
        "auto_trade.training.model_a_evaluation_task_handler.DatabaseModelAEvaluationStore",
        lambda _connection: store,
    )

    result = await ModelAEvaluationTaskHandler(MagicMock())(lease(payload()))

    assert len(result) == 64
    store.load_context.assert_awaited_once()
    store.record_outcome.assert_awaited_once()
    store.record_opportunity.assert_awaited_once()
    store.record_random_baseline.assert_awaited_once()
    store.record_random_candidate_outcome.assert_awaited_once()


@pytest.mark.asyncio
async def test_retry_reuses_existing_evidence_without_rewriting(monkeypatch) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context())
    store.load_existing_evidence = AsyncMock(
        return_value=ExistingEntryEvidence("c" * 64, True, True, True)
    )
    store.finalize_random_baseline_coverage = AsyncMock(return_value="READY")
    store.load_outcome_bars = AsyncMock()
    store.record_outcome = AsyncMock()
    store.record_opportunity = AsyncMock()
    store.load_random_baseline_context = AsyncMock()
    store.load_random_baseline_candidates = AsyncMock()
    store.record_random_baseline = AsyncMock()
    store.finalize_random_baseline_coverage = AsyncMock(
        return_value="INSUFFICIENT_POWER"
    )
    monkeypatch.setattr(
        "auto_trade.training.model_a_evaluation_task_handler.DatabaseModelAEvaluationStore",
        lambda _connection: store,
    )

    result = await ModelAEvaluationTaskHandler(MagicMock())(lease(payload()))

    assert len(result) == 64
    store.load_outcome_bars.assert_not_awaited()
    store.record_outcome.assert_not_awaited()
    store.record_opportunity.assert_not_awaited()
    store.record_random_baseline.assert_not_awaited()


@pytest.mark.asyncio
async def test_incomplete_outcome_never_creates_opportunity_truth(monkeypatch) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context())
    store.load_existing_evidence = AsyncMock(return_value=None)
    store.load_outcome_bars = AsyncMock(return_value=())
    store.record_outcome = AsyncMock()
    store.record_opportunity = AsyncMock()
    store.load_random_baseline_context = AsyncMock()
    store.load_random_baseline_candidates = AsyncMock()
    store.record_random_baseline = AsyncMock()
    store.finalize_random_baseline_coverage = AsyncMock(
        return_value="INSUFFICIENT_POWER"
    )
    monkeypatch.setattr(
        "auto_trade.training.model_a_evaluation_task_handler.DatabaseModelAEvaluationStore",
        lambda _connection: store,
    )

    await ModelAEvaluationTaskHandler(MagicMock())(lease(payload()))

    store.record_outcome.assert_awaited_once()
    store.record_opportunity.assert_not_awaited()
    store.record_random_baseline.assert_not_awaited()


@pytest.mark.asyncio
async def test_insufficient_reference_frame_is_excluded_without_failing_task(
    monkeypatch,
) -> None:
    store = MagicMock()
    store.load_context = AsyncMock(return_value=context())
    store.load_existing_evidence = AsyncMock(
        return_value=ExistingEntryEvidence("c" * 64, True, True, False, False)
    )
    insufficient = baseline_context()
    insufficient = RandomBaselineEvaluationContext(
        insufficient.config_version_id,
        5,
        5,
        86400,
        42,
        insufficient.target,
        (),
    )
    store.load_random_baseline_context = AsyncMock(return_value=insufficient)
    store.load_random_baseline_candidates = AsyncMock(return_value=())
    store.record_random_baseline_exclusion = AsyncMock(return_value="e" * 64)
    store.record_random_baseline = AsyncMock()
    store.finalize_random_baseline_coverage = AsyncMock(
        return_value="INSUFFICIENT_POWER"
    )
    monkeypatch.setattr(
        "auto_trade.training.model_a_evaluation_task_handler.DatabaseModelAEvaluationStore",
        lambda _connection: store,
    )

    result = await ModelAEvaluationTaskHandler(MagicMock())(lease(payload()))

    assert len(result) == 64
    store.record_random_baseline_exclusion.assert_awaited_once()
    store.record_random_baseline.assert_not_awaited()


@pytest.mark.asyncio
async def test_handler_rejects_non_evaluator_lease(monkeypatch) -> None:
    monkeypatch.setattr(
        "auto_trade.training.model_a_evaluation_task_handler.DatabaseModelAEvaluationStore",
        lambda _connection: MagicMock(),
    )
    with pytest.raises(ModelAPipelineError, match="EVALUATOR"):
        await ModelAEvaluationTaskHandler(MagicMock())(
            lease(payload(), ExecutorKind.WORKER)
        )
