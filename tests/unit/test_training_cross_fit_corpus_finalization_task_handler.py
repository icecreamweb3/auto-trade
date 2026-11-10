from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from auto_trade.training.cross_fit_corpus_finalization_task_handler import (
    CrossFitCorpusFinalizationError,
    CrossFitCorpusFinalizationTaskHandler,
    parse_cross_fit_corpus_finalization_payload,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _lease(*, executor: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(), executor, uuid4(), 1, datetime.now(UTC) + timedelta(minutes=5), 0,
        {"task_type": "CROSS_FIT_FINALIZE_CORPUS", "payload_version": 1,
         "execution_id": str(uuid4())},
    )


def test_corpus_payload_is_exact() -> None:
    lease = _lease()
    assert parse_cross_fit_corpus_finalization_payload(lease.payload)
    with pytest.raises(CrossFitCorpusFinalizationError, match="exact v1"):
        parse_cross_fit_corpus_finalization_payload({**lease.payload, "extra": True})


@pytest.mark.asyncio
async def test_corpus_finalization_requires_evaluator_and_hash() -> None:
    handler = CrossFitCorpusFinalizationTaskHandler(AsyncMock())
    with pytest.raises(CrossFitCorpusFinalizationError, match="EVALUATOR"):
        await handler(_lease(executor=ExecutorKind.WORKER))
    handler._store.finalize_candidate_corpus = AsyncMock(  # type: ignore[method-assign]
        return_value="a" * 64
    )
    assert await handler(_lease()) == "a" * 64
