"""Lease-bound finalization of the fixed Cross-fit candidate corpus."""

from __future__ import annotations

from collections.abc import Mapping
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.cross_fit_repository import DatabaseCrossFitStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class CrossFitCorpusFinalizationError(RuntimeError):
    """The candidate-corpus task or its result is invalid."""


def parse_cross_fit_corpus_finalization_payload(
    payload: Mapping[str, object],
) -> UUID:
    if set(payload) != {"task_type", "payload_version", "execution_id"}:
        raise CrossFitCorpusFinalizationError(
            "CROSS_FIT_FINALIZE_CORPUS requires an exact v1 payload"
        )
    if payload.get("task_type") != "CROSS_FIT_FINALIZE_CORPUS" or payload.get(
        "payload_version"
    ) != 1:
        raise CrossFitCorpusFinalizationError(
            "CROSS_FIT_FINALIZE_CORPUS requires payload_version 1"
        )
    try:
        return UUID(str(payload["execution_id"]))
    except (TypeError, ValueError) as error:
        raise CrossFitCorpusFinalizationError("execution_id must be a UUID") from error


class CrossFitCorpusFinalizationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseCrossFitStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise CrossFitCorpusFinalizationError(
                "CROSS_FIT_FINALIZE_CORPUS requires EVALUATOR executor"
            )
        parse_cross_fit_corpus_finalization_payload(lease.payload)
        result_hash = await self._store.finalize_candidate_corpus(
            lease.task_id, lease.lease_token
        )
        if len(result_hash) != 64 or any(
            character not in "0123456789abcdef" for character in result_hash
        ):
            raise CrossFitCorpusFinalizationError(
                "candidate corpus finalization returned an invalid evidence hash"
            )
        return result_hash
