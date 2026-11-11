"""Lease-bound persistence adapter for formal Model-B search finalization."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection


class DatabaseModelBFormalSearchStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def finalize(self, task_id: UUID, lease_token: UUID) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_model_b_formal_search(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())
