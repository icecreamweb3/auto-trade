from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal
from typing import Protocol
from uuid import UUID

from auto_trade.training.contracts import Direction
from auto_trade.training.simulation_repository import (
    AsOfSimulationBar,
    SafeExitEpisode,
)
from auto_trade.training.simulator import (
    ExitDecision,
    FeeModel,
    FixedExitPolicy,
    FixedExitReplay,
    FixedExitResult,
    SlippageModel,
)


class ModelBReplayStore(Protocol):
    async def load_episode(self, model_b_sample_id: str) -> SafeExitEpisode: ...

    async def load_bar(
        self,
        episode: SafeExitEpisode,
        decision_time: datetime,
    ) -> AsOfSimulationBar: ...

    async def record_decision(
        self,
        episode: SafeExitEpisode,
        snapshot_id: UUID,
        decision: ExitDecision,
        direction: Direction,
    ) -> None: ...


class FixedExitReplayService:
    """Fetch one closed bar, decide, persist, then advance to the next boundary."""

    def __init__(self, store: ModelBReplayStore) -> None:
        self._store = store

    async def replay(
        self,
        *,
        model_b_sample_id: str,
        entry_event_id: str,
        notional: Decimal,
        policy: FixedExitPolicy,
        fee_model: FeeModel,
        slippage_model: SlippageModel,
    ) -> FixedExitResult:
        episode = await self._store.load_episode(model_b_sample_id)
        replay = FixedExitReplay(
            entry_event_id=entry_event_id,
            direction=episode.direction,
            entry_time=episode.entry_time,
            entry_reference_price=episode.entry_reference_price,
            notional=notional,
            policy=policy,
            fee_model=fee_model,
            slippage_model=slippage_model,
        )
        decision_time = episode.entry_time + timedelta(seconds=episode.interval_seconds)
        while decision_time <= episode.maximum_end_at:
            as_of_bar = await self._store.load_bar(episode, decision_time)
            decision = replay.step(as_of_bar.bar)
            await self._store.record_decision(
                episode,
                as_of_bar.decision_feature_snapshot_id,
                decision,
                episode.direction,
            )
            if replay.result is not None:
                return replay.result
            decision_time += timedelta(seconds=episode.interval_seconds)
        raise RuntimeError("maximum holding boundary was reached without an exit decision")
