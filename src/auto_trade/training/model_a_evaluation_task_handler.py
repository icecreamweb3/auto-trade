"""MODEL_A_EVALUATION v1 governed task handler."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import timedelta
from typing import cast

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_a_evaluation_repository import (
    DatabaseModelAEvaluationStore,
)
from auto_trade.training.model_a_pipeline import (
    ModelAPipelineError,
    calculate_entry_outcome,
    select_matched_random_baseline,
)
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
    def __init__(
        self,
        connection: AsyncConnection,
        *,
        commit_interval: int | None = None,
    ) -> None:
        if commit_interval is not None and commit_interval <= 0:
            raise ValueError("commit_interval must be positive")
        self._store = DatabaseModelAEvaluationStore(connection)
        self._commit_interval = commit_interval

    async def _commit_progress(self, processed_count: int, *, force: bool = False) -> None:
        if self._commit_interval is None:
            return
        if force or processed_count % self._commit_interval == 0:
            await self._store.commit_progress()

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise ModelAPipelineError("MODEL_A_EVALUATION requires EVALUATOR executor")
        payload = parse_model_a_evaluation_payload(lease.payload)
        evidence: list[dict[str, object]] = []
        for processed_count, entry_event_id in enumerate(payload.entry_event_ids, 1):
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
                random_baseline_recorded = False
                random_baseline_excluded = False
                exclusion_evidence_hash: str | None = None
                random_outcome_hashes: list[str] = []
            else:
                is_complete = existing.is_complete
                path_fingerprint = existing.path_fingerprint
                opportunity_recorded = existing.opportunity_recorded
                random_baseline_recorded = existing.random_baseline_recorded
                random_baseline_excluded = existing.random_baseline_excluded
                exclusion_evidence_hash = (
                    existing.random_baseline_exclusion_evidence_hash
                )
                random_outcome_hashes = list(existing.random_outcome_hashes)
            if is_complete and not opportunity_recorded:
                await self._store.record_opportunity(
                    entry_event_id,
                    context.opportunity_definition_version_id,
                )
                opportunity_recorded = True
            if is_complete and not random_baseline_recorded and not random_baseline_excluded:
                baseline_context = await self._store.load_random_baseline_context(
                    lease.task_id, lease.lease_token, entry_event_id
                )
                candidates = await self._store.load_random_baseline_candidates(
                    lease.task_id, lease.lease_token, entry_event_id
                )
                if len(candidates) < baseline_context.minimum_frame_size:
                    exclusion_evidence_hash = (
                        await self._store.record_random_baseline_exclusion(
                            lease.task_id, lease.lease_token, entry_event_id
                        )
                    )
                    random_baseline_excluded = True
                    evidence.append(
                        {
                            "entry_event_id": entry_event_id,
                            "is_complete": is_complete,
                            "opportunity_recorded": opportunity_recorded,
                            "random_baseline_recorded": False,
                            "random_baseline_excluded": True,
                            "random_baseline_exclusion_reason": (
                                "RANDOM_BASELINE_FRAME_INSUFFICIENT"
                            ),
                            "random_baseline_exclusion_evidence_hash": exclusion_evidence_hash,
                            "random_outcome_hashes": (),
                            "path_fingerprint": path_fingerprint,
                        }
                    )
                    await self._commit_progress(processed_count)
                    continue
                selection = select_matched_random_baseline(
                    matched_entry_event_id=entry_event_id,
                    target=baseline_context.target,
                    candidates=candidates,
                    # The governed reference support is sealed only after the
                    # +/- exclusion window has been applied.  Applying it again
                    # here can shrink an otherwise sufficient frozen frame and
                    # makes the evaluator disagree with the database guard,
                    # which requires overlap_excluded_count = 0 for that frame.
                    signal_times_by_instrument={},
                    exclusion_window=timedelta(
                        seconds=baseline_context.exclusion_window_seconds
                    ),
                    sample_count=baseline_context.sample_count,
                    minimum_frame_size=baseline_context.minimum_frame_size,
                    random_seed=baseline_context.random_seed,
                )
                for candidate_id in selection.selected_candidate_ids:
                    candidate_context = (
                        await self._store.load_random_candidate_outcome_context(
                            lease.task_id,
                            lease.lease_token,
                            entry_event_id,
                            candidate_id,
                        )
                    )
                    candidate_bars = (
                        await self._store.load_random_candidate_outcome_bars(
                            lease.task_id,
                            lease.lease_token,
                            entry_event_id,
                            candidate_id,
                        )
                    )
                    candidate_outcome = calculate_entry_outcome(
                        entry_event_id=candidate_id,
                        partition=candidate_context.partition,
                        entry_time=candidate_context.entry_time,
                        entry_price=candidate_context.entry_price,
                        direction=candidate_context.direction,
                        label_window_end_at=candidate_context.label_window_end_at,
                        interval_seconds=candidate_context.interval_seconds,
                        bars=candidate_bars,
                    )
                    if not candidate_outcome.is_complete:
                        raise ModelAPipelineError(
                            "selected random-baseline candidate has an incomplete future path"
                        )
                    await self._store.record_random_candidate_outcome(
                        lease.task_id,
                        lease.lease_token,
                        entry_event_id,
                        candidate_outcome,
                        candidate_context.holding_rule_version_id,
                        candidate_context.interval_seconds,
                    )
                    random_outcome_hashes.append(candidate_outcome.path_fingerprint)
                await self._store.record_random_baseline(
                    selection,
                    baseline_context.config_version_id,
                    baseline_context.target,
                )
                random_baseline_recorded = True
            evidence.append(
                {
                    "entry_event_id": entry_event_id,
                    "is_complete": is_complete,
                    "opportunity_recorded": opportunity_recorded,
                    "random_baseline_recorded": random_baseline_recorded,
                    "random_baseline_excluded": random_baseline_excluded,
                    "random_baseline_exclusion_evidence_hash": exclusion_evidence_hash,
                    "random_outcome_hashes": tuple(random_outcome_hashes),
                    "path_fingerprint": path_fingerprint,
                }
            )
            await self._commit_progress(processed_count)
        coverage_status = await self._store.finalize_random_baseline_coverage(
            lease.task_id, lease.lease_token
        )
        await self._commit_progress(len(payload.entry_event_ids), force=True)
        return _sha256(
            {
                "payload_version": 1,
                "entries": evidence,
                "random_baseline_coverage_status": coverage_status,
            }
        )
