"""Lease-bound database inputs for governed MODEL_B_REPLAY tasks."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection


@dataclass(frozen=True, slots=True)
class ModelBReplayContext:
    model_b_sample_id: str
    entry_event_id: str
    exit_episode_id: str
    episode_status: str
    exit_rule_version_id: UUID
    exit_rule_config: Mapping[str, object]
    fee_model_version_id: UUID
    fee_model_config: Mapping[str, object]
    slippage_model_version_id: UUID
    slippage_model_config: Mapping[str, object]
    notional: Decimal


class DatabaseModelBReplayTaskStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(
        self,
        task_id: UUID,
        lease_token: UUID,
        model_b_sample_id: str,
    ) -> ModelBReplayContext:
        result = await self._connection.execute(
            text(
                """
                SELECT model_b_sample_id, entry_event_id, exit_episode_id,
                       episode_status, exit_rule_version_id, exit_rule_config,
                       fee_model_version_id, fee_model_config,
                       slippage_model_version_id, slippage_model_config,
                       notional
                FROM strategy_training.training_model_b_replay_context(
                    :task_id, :lease_token, :model_b_sample_id
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "model_b_sample_id": model_b_sample_id,
            },
        )
        row = cast(Mapping[str, object], result.mappings().one())
        return ModelBReplayContext(
            str(row["model_b_sample_id"]),
            str(row["entry_event_id"]),
            str(row["exit_episode_id"]),
            str(row["episode_status"]),
            cast(UUID, row["exit_rule_version_id"]),
            cast(Mapping[str, object], row["exit_rule_config"]),
            cast(UUID, row["fee_model_version_id"]),
            cast(Mapping[str, object], row["fee_model_config"]),
            cast(UUID, row["slippage_model_version_id"]),
            cast(Mapping[str, object], row["slippage_model_config"]),
            Decimal(str(row["notional"])),
        )

    async def load_terminal_decision_hash(self, exit_episode_id: str) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT decision_hash
                FROM strategy_training.model_b_decision_history
                WHERE exit_episode_id = :exit_episode_id AND action = 'EXIT'
                ORDER BY sequence_no DESC
                LIMIT 1
                """
            ),
            {"exit_episode_id": exit_episode_id},
        )
        return str(result.scalar_one())
