"""OPTIMIZER_TRIAL v1 TRAIN-only tell handler."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.optimizer import CandidateStatus, TrialState, validate_candidate
from auto_trade.training.optimizer_trial_repository import DatabaseOptimizerTrialStore
from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.search_space import parse_versioned_search_space


class OptimizerTrialError(RuntimeError):
    """A trial cannot be told without its governed TRAIN evidence."""


def _sha256(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
            allow_nan=False,
        ).encode()
    ).hexdigest()


@dataclass(frozen=True, slots=True)
class OptimizerTrialTaskPayload:
    trial_number: int


def parse_optimizer_trial_payload(
    payload: Mapping[str, object],
) -> OptimizerTrialTaskPayload:
    allowed = {"task_type", "payload_version", "trial_number"}
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise OptimizerTrialError(
            "unexpected OPTIMIZER_TRIAL fields: " + ", ".join(unexpected)
        )
    if payload.get("task_type") != "OPTIMIZER_TRIAL" or payload.get(
        "payload_version"
    ) != 1:
        raise OptimizerTrialError("OPTIMIZER_TRIAL requires payload_version 1")
    trial_number = payload.get("trial_number")
    if isinstance(trial_number, bool) or not isinstance(trial_number, int) or trial_number < 0:
        raise OptimizerTrialError("trial_number must be a non-negative integer")
    return OptimizerTrialTaskPayload(trial_number)


class OptimizerTrialTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseOptimizerTrialStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.OPTIMIZER:
            raise OptimizerTrialError("OPTIMIZER_TRIAL requires OPTIMIZER executor")
        payload = parse_optimizer_trial_payload(lease.payload)
        context = await self._store.load_context(lease.task_id, lease.lease_token)
        if context.trial_number != payload.trial_number:
            raise OptimizerTrialError("payload trial_number differs from leased context")
        try:
            search_space = parse_versioned_search_space(
                context.search_space_semver, context.search_space_config
            )
        except ValueError as error:
            raise OptimizerTrialError("frozen SEARCH_SPACE is invalid") from error
        validation = validate_candidate(
            context.candidate_parameters, search_space.parameters
        )
        if validation.status is CandidateStatus.REJECTED:
            trial_state = TrialState.FAIL
            objective = None
            evidence_hash = None
            rejection_codes = validation.rejection_codes
        else:
            objective = context.train_objective
            evidence_hash = context.train_evidence_hash
            if objective is None or evidence_hash is None:
                raise OptimizerTrialError("valid candidate has no completed TRAIN objective")
            if not objective.is_finite():
                trial_state = TrialState.FAIL
                objective = None
                evidence_hash = None
                rejection_codes = ("TRAIN_OBJECTIVE_NON_FINITE",)
            else:
                trial_state = TrialState.COMPLETE
                rejection_codes = ()
        result_hash = _sha256(
            {
                "candidate_content_hash": context.candidate_content_hash,
                "optimizer_run_id": context.optimizer_run_id,
                "rejection_codes": rejection_codes,
                "search_space_config_version_id": context.search_space_config_version_id,
                "train_evidence_hash": evidence_hash,
                "train_objective": objective,
                "trial_number": context.trial_number,
                "trial_state": trial_state.value,
            }
        )
        await self._store.record_result(
            task_id=lease.task_id,
            lease_token=lease.lease_token,
            trial_state=trial_state.value,
            train_objective=objective,
            rejection_codes=rejection_codes,
            train_evidence_hash=evidence_hash,
            result_hash=result_hash,
        )
        return result_hash
