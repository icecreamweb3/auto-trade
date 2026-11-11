"""Compile one Model-B proposal and prepare its frozen replay corpus."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_b_candidate_policy import (
    ModelBCandidatePolicyError,
    compile_model_b_candidate_policy,
)
from auto_trade.training.model_b_candidate_preparation_repository import (
    DatabaseModelBCandidatePreparationStore,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


class ModelBCandidatePreparationError(RuntimeError):
    """A Model-B proposal cannot enter the governed replay boundary."""


class ModelBCandidatePreparationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabaseModelBCandidatePreparationStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise ModelBCandidatePreparationError(
                "MODEL_B_PREPARE_CANDIDATE requires EVALUATOR executor"
            )
        if lease.payload != {
            "task_type": "MODEL_B_PREPARE_CANDIDATE",
            "payload_version": 1,
        }:
            raise ModelBCandidatePreparationError(
                "MODEL_B_PREPARE_CANDIDATE requires exact v1 payload"
            )
        context = await self._store.load_context(lease.task_id, lease.lease_token)
        try:
            compiled = compile_model_b_candidate_policy(
                exit_rule_version_id=context.base_exit_rule_version_id,
                search_space_config=context.search_space_config,
                candidate=context.candidate_parameters,
            )
        except ModelBCandidatePolicyError as error:
            raise ModelBCandidatePreparationError(error.code) from error

        effective_hash = await self._store.record_compiled_policy(
            task_id=lease.task_id,
            lease_token=lease.lease_token,
            effective_exit_rule_config=compiled.effective_exit_rule_config,
            remaining_position_fraction=compiled.remaining_position_fraction,
        )
        if (
            context.existing_effective_hash is not None
            and context.existing_effective_hash != effective_hash
        ):
            raise ModelBCandidatePreparationError(
                "existing compiled policy differs from the candidate"
            )
        for entry_event_id in context.input_entry_event_ids:
            await self._store.create_episode(
                task_id=lease.task_id,
                lease_token=lease.lease_token,
                entry_event_id=entry_event_id,
            )
        return await self._store.finalize(lease.task_id, lease.lease_token)
