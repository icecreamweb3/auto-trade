from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection


@dataclass(frozen=True, slots=True)
class OptimizerTrialContext:
    optimizer_run_id: UUID
    iteration_id: UUID
    trial_number: int
    candidate_parameters: Mapping[str, object]
    candidate_content_hash: str
    search_space_config_version_id: UUID
    search_space_semver: str
    search_space_config: Mapping[str, object]
    train_objective: Decimal | None
    train_evidence_hash: str | None


class DatabaseOptimizerTrialStore:
    """Expose one leased trial and its TRAIN-only aggregate objective."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(
        self, task_id: UUID, lease_token: UUID
    ) -> OptimizerTrialContext:
        result = await self._connection.execute(
            text(
                """
                SELECT optimizer_run_id, iteration_id, trial_number,
                       candidate_parameters, candidate_content_hash,
                       search_space_config_version_id, search_space_semver,
                       search_space_config, train_objective, train_evidence_hash
                FROM strategy_training.training_optimizer_trial_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = result.mappings().one()
        objective = row["train_objective"]
        evidence_hash = row["train_evidence_hash"]
        return OptimizerTrialContext(
            optimizer_run_id=cast(UUID, row["optimizer_run_id"]),
            iteration_id=cast(UUID, row["iteration_id"]),
            trial_number=int(row["trial_number"]),
            candidate_parameters=cast(Mapping[str, object], row["candidate_parameters"]),
            candidate_content_hash=str(row["candidate_content_hash"]),
            search_space_config_version_id=cast(
                UUID, row["search_space_config_version_id"]
            ),
            search_space_semver=str(row["search_space_semver"]),
            search_space_config=cast(Mapping[str, object], row["search_space_config"]),
            train_objective=None if objective is None else Decimal(str(objective)),
            train_evidence_hash=None if evidence_hash is None else str(evidence_hash),
        )

    async def record_result(
        self,
        *,
        task_id: UUID,
        lease_token: UUID,
        trial_state: str,
        train_objective: Decimal | None,
        rejection_codes: tuple[str, ...],
        train_evidence_hash: str | None,
        result_hash: str,
    ) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_optimizer_trial_result(
                    :task_id, :lease_token, :trial_state, :train_objective,
                    CAST(:rejection_codes AS jsonb), :train_evidence_hash,
                    :result_hash
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "trial_state": trial_state,
                "train_objective": train_objective,
                "rejection_codes": json.dumps(rejection_codes, separators=(",", ":")),
                "train_evidence_hash": train_evidence_hash,
                "result_hash": result_hash,
            },
        )
        return cast(UUID, result.scalar_one())
