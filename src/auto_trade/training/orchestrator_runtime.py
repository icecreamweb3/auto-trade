from __future__ import annotations

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.training.governance_repository import DatabaseOrchestratorStore


class DatabaseOrchestratorRuntime:
    """Advance only state/task metadata; metric values never leave evaluator storage."""

    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine

    async def tick(self) -> tuple[tuple[UUID, str], ...]:
        async with self._engine.begin() as connection:
            store = DatabaseOrchestratorStore(connection)
            optimizer_actions = await store.advance_optimizer_runs()
            scan_actions = await store.advance_candidate_scans()
            l0_actions = await store.advance_model_a_l0_tasks()
            return optimizer_actions + scan_actions + l0_actions
