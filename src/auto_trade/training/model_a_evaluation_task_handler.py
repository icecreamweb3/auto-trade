"""MODEL_A_EVALUATION v1 governed task handler."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import cast

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_a_evaluation_repository import (
    DatabaseModelAEvaluationStore,
)
from auto_trade.training.model_a_pipeline import ModelAPipelineError, calculate_entry_outcome
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _sha256(payload: object) -> str:
    return hashlib.sha256(
        json.dumps(
            payload,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode()
    ).hexdigest()


def _event_id(value: object) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise ModelAPipelineError("entry_event_ids must contain lowercase SHA-256 values")
    return value


@dataclass(frozen=True, slots=True)
class ModelAEvaluationTaskPayload:
    entry_event_ids: tuple[str, ...]


def parse_model_a_evaluation_payload(
    payload: Mapping[str, object],
) -> ModelAEvaluationTaskPayload:
    allowed = {"task_type", "payload_version", "entry_event_ids"}
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise ModelAPipelineError(
            "unexpected MODEL_A_EVALUATION fields: " + ", ".join(unexpected)
        )
    if payload.get("task_type") != "MODEL_A_EVALUATION" or payload.get(
        "payload_version"
    ) != 1:
        raise ModelAPipelineError("MODEL_A_EVALUATION requires payload_version 1")
    raw_ids = payload.get("entry_event_ids")
    if not isinstance(raw_ids, list) or not raw_ids:
        raise ModelAPipelineError("entry_event_ids must be a non-empty array")
    event_ids = tuple(_event_id(value) for value in cast(list[object], raw_ids))
    if event_ids != tuple(sorted(set(event_ids))):
        raise ModelAPipelineError("entry_event_ids must be unique and sorted")
    return ModelAEvaluationTaskPayload(event_ids)


class ModelAEvaluationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseModelAEvaluationStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise ModelAPipelineError("MODEL_A_EVALUATION requires EVALUATOR executor")
        payload = parse_model_a_evaluation_payload(lease.payload)
        evidence: list[dict[str, object]] = []
        for entry_event_id in payload.entry_event_ids:
            context = await self._store.load_context(
                lease.task_id, lease.lease_token, entry_event_id
            )
            existing = await self._store.load_existing_evidence(entry_event_id)
            if existing is None:
                bars = await self._store.load_outcome_bars(entry_event_id)
                outcome = calculate_entry_outcome(
                    entry_event_id=entry_event_id,
                    partition=context.partition,
                    entry_time=context.entry_time,
                    entry_price=context.entry_price,
                    direction=context.direction,
                    label_window_end_at=context.label_window_end_at,
                    interval_seconds=context.interval_seconds,
                    bars=bars,
                )
                await self._store.record_outcome(
                    outcome,
                    context.holding_rule_version_id,
                    context.interval_seconds,
                )
                is_complete = outcome.is_complete
                path_fingerprint = outcome.path_fingerprint
                opportunity_recorded = False
            else:
                is_complete = existing.is_complete
                path_fingerprint = existing.path_fingerprint
                opportunity_recorded = existing.opportunity_recorded
            if is_complete and not opportunity_recorded:
                await self._store.record_opportunity(
                    entry_event_id,
                    context.opportunity_definition_version_id,
                )
                opportunity_recorded = True
            evidence.append(
                {
                    "entry_event_id": entry_event_id,
                    "is_complete": is_complete,
                    "opportunity_recorded": opportunity_recorded,
                    "path_fingerprint": path_fingerprint,
                }
            )
        return _sha256({"payload_version": 1, "entries": evidence})
