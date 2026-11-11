"""Lease-bound persistence for compiled Model-B optimizer candidates."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection


def _json_default(value: object) -> object:
    if isinstance(value, Decimal):
        return float(value)
    raise TypeError(f"unsupported JSON value: {type(value).__name__}")


def _json_text(value: object) -> str:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        default=_json_default,
        allow_nan=False,
    )


@dataclass(frozen=True, slots=True)
class ModelBCandidatePreparationContext:
    model_b_iteration_id: UUID
    optimizer_run_id: UUID
    search_space_config_version_id: UUID
    search_space_config: Mapping[str, object]
    base_exit_rule_version_id: UUID
    base_exit_rule_config: Mapping[str, object]
    candidate_parameters: Mapping[str, object]
    candidate_content_hash: str
    temporary_only: bool
    input_entry_event_ids: tuple[str, ...]
    existing_effective_hash: str | None


class DatabaseModelBCandidatePreparationStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(
        self, task_id: UUID, lease_token: UUID
    ) -> ModelBCandidatePreparationContext:
        result = await self._connection.execute(
            text(
                """
                SELECT model_b_iteration_id, optimizer_run_id,
                       search_space_config_version_id, search_space_config,
                       base_exit_rule_version_id, base_exit_rule_config,
                       candidate_parameters, candidate_content_hash,
                       temporary_only, input_entry_event_ids,
                       existing_effective_hash
                FROM strategy_training.training_model_b_candidate_preparation_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = cast(Mapping[str, object], result.mappings().one())
        raw_ids = cast(list[object], row["input_entry_event_ids"])
        return ModelBCandidatePreparationContext(
            cast(UUID, row["model_b_iteration_id"]),
            cast(UUID, row["optimizer_run_id"]),
            cast(UUID, row["search_space_config_version_id"]),
            cast(Mapping[str, object], row["search_space_config"]),
            cast(UUID, row["base_exit_rule_version_id"]),
            cast(Mapping[str, object], row["base_exit_rule_config"]),
            cast(Mapping[str, object], row["candidate_parameters"]),
            str(row["candidate_content_hash"]),
            bool(row["temporary_only"]),
            tuple(str(value) for value in raw_ids),
            None
            if row["existing_effective_hash"] is None
            else str(row["existing_effective_hash"]),
        )

    async def record_compiled_policy(
        self,
        *,
        task_id: UUID,
        lease_token: UUID,
        effective_exit_rule_config: Mapping[str, object],
        remaining_position_fraction: Decimal,
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_model_b_compiled_candidate_policy(
                    :task_id, :lease_token,
                    CAST(:effective_exit_rule_config AS jsonb),
                    :remaining_position_fraction
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "effective_exit_rule_config": _json_text(
                    effective_exit_rule_config
                ),
                "remaining_position_fraction": remaining_position_fraction,
            },
        )
        return str(result.scalar_one())

    async def create_episode(
        self, *, task_id: UUID, lease_token: UUID, entry_event_id: str
    ) -> None:
        await self._connection.execute(
            text(
                """
                SELECT *
                FROM strategy_training.create_training_model_b_candidate_exit_episode(
                    :task_id, :lease_token, :entry_event_id
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
            },
        )

    async def finalize(self, task_id: UUID, lease_token: UUID) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_model_b_candidate_preparation(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())
