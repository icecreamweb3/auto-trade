from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.optuna_adapter import PriorTrial


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
    iteration_state: str
    iteration_rejection_code: str | None
    train_objective: Decimal | None
    train_evidence_hash: str | None


@dataclass(frozen=True, slots=True)
class OptimizerAskContext:
    optimizer_run_id: UUID
    trial_number: int
    optimizer_kind: str
    run_random_seed: int
    search_space_config_version_id: UUID
    search_space_semver: str
    search_space_content_hash: str
    search_space_config: Mapping[str, object]
    prior_trials: tuple[PriorTrial, ...]


class DatabaseOptimizerTrialStore:
    """Expose one leased trial and its TRAIN-only aggregate objective."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_ask_context(
        self, task_id: UUID, lease_token: UUID
    ) -> OptimizerAskContext:
        result = await self._connection.execute(
            text(
                """
                SELECT optimizer_run_id, trial_number, optimizer_kind,
                       run_random_seed, search_space_config_version_id,
                       search_space_semver, search_space_content_hash,
                       search_space_config, prior_trials
                FROM strategy_training.training_optimizer_ask_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = result.mappings().one()
        raw_prior = cast(list[Mapping[str, object]], row["prior_trials"])
        prior = tuple(
            PriorTrial(
                int(str(item["trial_number"])),
                cast(Mapping[str, object], item["candidate_parameters"]),
                str(item["trial_state"]),
                None
                if item.get("train_objective") is None
                else Decimal(str(item["train_objective"])),
            )
            for item in raw_prior
        )
        return OptimizerAskContext(
            cast(UUID, row["optimizer_run_id"]),
            int(row["trial_number"]),
            str(row["optimizer_kind"]),
            int(row["run_random_seed"]),
            cast(UUID, row["search_space_config_version_id"]),
            str(row["search_space_semver"]),
            str(row["search_space_content_hash"]),
            cast(Mapping[str, object], row["search_space_config"]),
            prior,
        )

    async def record_proposal(
        self,
        *,
        task_id: UUID,
        lease_token: UUID,
        sampler_seed: int,
        search_space_content_hash: str,
        candidate_parameters: Mapping[str, object],
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_optimizer_trial_proposal(
                    :task_id, :lease_token, :sampler_seed,
                    :search_space_content_hash, CAST(:candidate_parameters AS jsonb)
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "sampler_seed": sampler_seed,
                "search_space_content_hash": search_space_content_hash,
                "candidate_parameters": json.dumps(
                    candidate_parameters, sort_keys=True, separators=(",", ":")
                ),
            },
        )
        return str(result.scalar_one())

    async def load_context(
        self, task_id: UUID, lease_token: UUID
    ) -> OptimizerTrialContext:
        result = await self._connection.execute(
            text(
                """
                SELECT optimizer_run_id, iteration_id, trial_number,
                       candidate_parameters, candidate_content_hash,
                       search_space_config_version_id, search_space_semver,
                       search_space_config, iteration_state,
                       iteration_rejection_code, train_objective,
                       train_evidence_hash
                FROM strategy_training.training_optimizer_tell_context(
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
            iteration_state=str(row["iteration_state"]),
            iteration_rejection_code=(
                None
                if row["iteration_rejection_code"] is None
                else str(row["iteration_rejection_code"])
            ),
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
