from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from auto_trade.training.contracts import EntrySource
from auto_trade.training.cross_fit_prediction_task_handler import (
    CrossFitPredictionError,
    CrossFitPredictionTaskHandler,
    _pool_at,
)
from auto_trade.training.model_a_candidate_scan_repository import (
    CandidateScanContext,
    PoolEvaluation,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _context(*, existing_batch_hash: str | None = None) -> CandidateScanContext:
    return CandidateScanContext(
        iteration_id=uuid4(),
        dataset_version_id=uuid4(),
        interval_seconds=300,
        eligible_start_at=datetime(2026, 9, 1, tzinfo=UTC),
        eligible_end_at=datetime(2026, 9, 3, tzinfo=UTC),
        ticker_pool_rule_version_id=uuid4(),
        factor_registry_version_id=uuid4(),
        factor_registry_config={"factors": ["single_bar_price_rise"]},
        scan_parameters_version_id=uuid4(),
        scan_parameters_config={
            "strategy_parameters": {
                "required_factors": ["single_bar_price_rise"],
                "factor_weights": {"single_bar_price_rise": "1"},
            }
        },
        candidate_parameters={"signal_score_threshold": 70},
        dataset_root_fingerprint="a" * 64,
        maximum_signal_count=100,
        existing_batch_hash=existing_batch_hash,
        entry_source=EntrySource.CROSS_FIT_MODEL_A_CANDIDATE,
    )


def _lease(*, executor_kind: ExecutorKind = ExecutorKind.WORKER) -> TaskLease:
    return TaskLease(
        uuid4(),
        executor_kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": "CROSS_FIT_PREDICT", "payload_version": 1},
    )


def test_prediction_pool_membership_expires_after_one_day() -> None:
    evaluated_at = datetime(2026, 9, 1, tzinfo=UTC)
    evaluation = PoolEvaluation(uuid4(), evaluated_at)

    assert _pool_at((evaluation,), evaluated_at + timedelta(hours=23)) == evaluation
    assert _pool_at((evaluation,), evaluated_at + timedelta(days=1)) is None


@pytest.mark.asyncio
async def test_prediction_accepts_auditable_zero_event_batch() -> None:
    handler = CrossFitPredictionTaskHandler(AsyncMock())
    handler._store.load_context = AsyncMock(return_value=_context())  # type: ignore[method-assign]
    handler._store.load_instruments = AsyncMock(return_value=())  # type: ignore[method-assign]
    handler._store.complete = AsyncMock(return_value="b" * 64)  # type: ignore[method-assign]
    lease = _lease()

    assert await handler(lease) == "b" * 64
    handler._store.complete.assert_awaited_once_with(  # type: ignore[attr-defined]
        lease.task_id, lease.lease_token, ()
    )


@pytest.mark.asyncio
async def test_prediction_retry_returns_frozen_batch_without_rescanning() -> None:
    handler = CrossFitPredictionTaskHandler(AsyncMock())
    handler._store.load_context = AsyncMock(  # type: ignore[method-assign]
        return_value=_context(existing_batch_hash="c" * 64)
    )
    handler._store.load_instruments = AsyncMock()  # type: ignore[method-assign]

    assert await handler(_lease()) == "c" * 64
    handler._store.load_instruments.assert_not_awaited()  # type: ignore[attr-defined]


@pytest.mark.asyncio
async def test_prediction_requires_worker_and_exact_payload() -> None:
    handler = CrossFitPredictionTaskHandler(AsyncMock())
    with pytest.raises(CrossFitPredictionError, match="WORKER"):
        await handler(_lease(executor_kind=ExecutorKind.EVALUATOR))

    lease = _lease()
    invalid = TaskLease(
        lease.task_id,
        lease.executor_kind,
        lease.lease_token,
        lease.attempt_number,
        lease.lease_expires_at,
        lease.checkpoint_sequence,
        {**lease.payload, "fold": 1},
    )
    with pytest.raises(CrossFitPredictionError, match="exact v1"):
        await handler(invalid)
