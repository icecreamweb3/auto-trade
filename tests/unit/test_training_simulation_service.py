from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID, uuid4

from auto_trade.training.contracts import Direction
from auto_trade.training.simulation_repository import AsOfSimulationBar, SafeExitEpisode
from auto_trade.training.simulation_service import FixedExitReplayService
from auto_trade.training.simulator import (
    ExitAction,
    ExitDecision,
    FeeModel,
    FixedExitPolicy,
    IntrabarConflictPolicy,
    SimulationBar,
    SlippageModel,
)


class _ReplayStore:
    def __init__(self) -> None:
        self.events: list[str] = []
        self.entry_time = datetime(2026, 6, 1, tzinfo=UTC)

    async def load_episode(self, model_b_sample_id: str) -> SafeExitEpisode:
        self.events.append("episode")
        return SafeExitEpisode(
            "e" * 64,
            model_b_sample_id,
            Direction.LONG,
            self.entry_time,
            Decimal("100"),
            self.entry_time + timedelta(minutes=10),
            300,
        )

    async def load_bar(
        self, episode: SafeExitEpisode, decision_time: datetime
    ) -> AsOfSimulationBar:
        sequence = 1 if decision_time == self.entry_time + timedelta(minutes=5) else 2
        self.events.append(f"load-{sequence}")
        open_time = decision_time - timedelta(minutes=5)
        return AsOfSimulationBar(
            UUID(int=sequence),
            SimulationBar(
                open_time,
                decision_time,
                Decimal("100"),
                Decimal("101" if sequence == 1 else "104"),
                Decimal("99"),
                Decimal("100"),
                Decimal("1000000"),
                Decimal("1"),
                Decimal("0"),
            ),
        )

    async def record_decision(
        self,
        episode: SafeExitEpisode,
        snapshot_id: UUID,
        decision: ExitDecision,
        direction: Direction,
    ) -> None:
        self.events.append(f"record-{decision.sequence_no}-{decision.action.value}")


async def test_replay_persists_each_decision_before_loading_the_next_bar() -> None:
    store = _ReplayStore()
    result = await FixedExitReplayService(store).replay(
        model_b_sample_id="s" * 64,
        entry_event_id="a" * 64,
        notional=Decimal("1000"),
        policy=FixedExitPolicy(
            uuid4(),
            Decimal("2"),
            Decimal("3"),
            Decimal("0"),
            Decimal("0"),
            timedelta(minutes=10),
            IntrabarConflictPolicy.WORST_CASE,
        ),
        fee_model=FeeModel(uuid4(), Decimal("0.0004"), Decimal("0.0004")),
        slippage_model=SlippageModel(
            uuid4(),
            Decimal("1"),
            Decimal("0"),
            Decimal("1000"),
            Decimal("0"),
            Decimal("0"),
            Decimal("10"),
        ),
    )
    assert store.events == [
        "episode",
        "load-1",
        "record-1-HOLD",
        "load-2",
        "record-2-EXIT",
    ]
    assert result.decisions[0].action is ExitAction.HOLD
    assert result.decisions[-1].action is ExitAction.EXIT
