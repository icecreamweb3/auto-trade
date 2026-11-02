from __future__ import annotations

from dataclasses import replace
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import UUID, uuid4

import pytest

from auto_trade.training.contracts import Direction, EntrySource
from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.portfolio_evaluation_repository import (
    EvaluationEpisode,
    EvaluationReplayStep,
    ExistingExitOutcome,
    ExistingPortfolioRun,
    PortfolioEvaluationContext,
    RecordedExitDecision,
)
from auto_trade.training.portfolio_evaluation_task_handler import (
    PortfolioEvaluationError,
    PortfolioEvaluationTaskHandler,
    _canonical_hash,
    parse_portfolio_evaluation_payload,
)
from auto_trade.training.simulator import (
    FeeModel,
    FixedExitPolicy,
    FixedExitReplay,
    IntrabarConflictPolicy,
    PortfolioCandidate,
    PortfolioRules,
    SimulationBar,
    SlippageModel,
    simulate_portfolio,
)

ENTRY_ID = "a" * 64
EPISODE_ID = "b" * 64
SAMPLE_ID = "c" * 64
EXIT_ID = UUID("10000000-0000-0000-0000-000000000001")
FEE_ID = UUID("10000000-0000-0000-0000-000000000002")
SLIP_ID = UUID("10000000-0000-0000-0000-000000000003")
PORTFOLIO_ID = UUID("10000000-0000-0000-0000-000000000004")


def payload() -> dict[str, object]:
    return {"task_type": "PORTFOLIO_EVALUATION", "payload_version": 1}


def lease(kind: ExecutorKind = ExecutorKind.EVALUATOR) -> TaskLease:
    return TaskLease(
        uuid4(),
        kind,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        payload(),
    )


def context() -> PortfolioEvaluationContext:
    return PortfolioEvaluationContext(
        uuid4(),
        EXIT_ID,
        {
            "stop_loss_percent": 2,
            "take_profit_percent": 3,
            "trailing_activation_percent": 0,
            "trailing_distance_percent": 0,
            "max_holding_seconds": 600,
            "intrabar_conflict_policy": "WORST_CASE",
        },
        FEE_ID,
        {"maker_rate": "0.0002", "taker_rate": "0.0004"},
        SLIP_ID,
        {
            "base_basis_points": 1,
            "notional_coefficient": 0,
            "reference_notional": 1000,
            "liquidity_coefficient": 0,
            "volatility_coefficient": 0,
            "maximum_basis_points": 10,
        },
        PORTFOLIO_ID,
        {
            "initial_capital": 2000,
            "notional_per_trade": 1000,
            "maximum_concurrent_positions": 1,
        },
    )


def evidence():
    entry_time = datetime(2026, 6, 1, tzinfo=UTC)
    episode = EvaluationEpisode(
        EPISODE_ID,
        SAMPLE_ID,
        ENTRY_ID,
        1,
        "TESTUSDT",
        EntrySource.FIXED_BASELINE_MODEL_A,
        Direction.LONG,
        entry_time,
        Decimal("100"),
        entry_time + timedelta(minutes=10),
        300,
    )
    policy = FixedExitPolicy(
        EXIT_ID,
        Decimal("2"),
        Decimal("3"),
        Decimal(0),
        Decimal(0),
        timedelta(minutes=10),
        IntrabarConflictPolicy.WORST_CASE,
    )
    fee = FeeModel(FEE_ID, Decimal("0.0004"), Decimal("0.0004"))
    slippage = SlippageModel(
        SLIP_ID,
        Decimal(1),
        Decimal(0),
        Decimal(1000),
        Decimal(0),
        Decimal(0),
        Decimal(10),
    )
    bar = SimulationBar(
        entry_time,
        entry_time + timedelta(minutes=5),
        Decimal("100"),
        Decimal("104"),
        Decimal("99"),
        Decimal("103"),
        Decimal("1000000"),
        Decimal("5"),
        Decimal(0),
    )
    replay = FixedExitReplay(
        entry_event_id=ENTRY_ID,
        direction=Direction.LONG,
        entry_time=entry_time,
        entry_reference_price=Decimal("100"),
        notional=Decimal("1000"),
        policy=policy,
        fee_model=fee,
        slippage_model=slippage,
    )
    decision = replay.step(bar)
    assert replay.result is not None
    snapshot_id = UUID("20000000-0000-0000-0000-000000000001")
    state = {
        "direction": "LONG",
        "stop_after": decision.stop_price_after,
        "stop_before": decision.stop_price_before,
    }
    decision_hash = _canonical_hash(
        {
            "action": decision.action.value,
            "decision_time": decision.decision_time,
            "episode": EPISODE_ID,
            "fill_price": decision.fill_price,
            "position_state": state,
            "reason": decision.reason,
            "reference_price": decision.reference_price,
            "sequence_no": decision.sequence_no,
            "slippage_basis_points": decision.slippage_basis_points,
            "snapshot_id": snapshot_id,
        }
    )
    recorded = RecordedExitDecision(
        decision.sequence_no,
        decision.decision_time,
        snapshot_id,
        decision.action,
        decision.reason,
        Direction.LONG,
        decision.stop_price_before,
        decision.stop_price_after,
        decision.reference_price,
        decision.fill_price,
        decision.slippage_basis_points,
        decision_hash,
    )
    return episode, EvaluationReplayStep(snapshot_id, bar, recorded), replay.result


def install_stores(monkeypatch, *, retry: bool = False, forged: bool = False):
    replay_context = context()
    episode, step, result = evidence()
    if forged:
        step = replace(step, recorded=replace(step.recorded, decision_hash="f" * 64))
    rules = PortfolioRules(PORTFOLIO_ID, Decimal(2000), Decimal(1000), 1)
    portfolio = simulate_portfolio(
        candidates=(
            PortfolioCandidate(
                ENTRY_ID,
                1,
                "TESTUSDT",
                EntrySource.FIXED_BASELINE_MODEL_A,
                result,
            ),
        ),
        rules=rules,
    )
    store = MagicMock()
    store.load_context = AsyncMock(return_value=replay_context)
    store.load_episodes = AsyncMock(return_value=(episode,))
    store.load_replay_steps = AsyncMock(return_value=(step,))
    store.load_existing_outcome = AsyncMock(
        return_value=(
            ExistingExitOutcome(
                result.exit_time,
                result.exit_fill_price,
                result.exit_reason.value,
                result.gross_pnl,
                result.entry_fee,
                result.exit_fee,
                result.funding_total,
                result.slippage_total,
                result.net_pnl,
                result.result_hash,
            )
            if retry
            else None
        )
    )
    store.load_existing_portfolio_run = AsyncMock(
        return_value=(
            ExistingPortfolioRun(
                "COMPLETE",
                portfolio.final_balance,
                portfolio.maximum_drawdown_percent,
                portfolio.peak_occupied_capital,
                portfolio.result_hash,
            )
            if retry
            else None
        )
    )
    evaluator = MagicMock()
    evaluator.record_outcome = AsyncMock()
    evaluator.persist_portfolio = AsyncMock()
    monkeypatch.setattr(
        "auto_trade.training.portfolio_evaluation_task_handler.DatabasePortfolioEvaluationStore",
        lambda _connection: store,
    )
    monkeypatch.setattr(
        "auto_trade.training.portfolio_evaluation_task_handler.DatabaseSimulationEvaluatorStore",
        lambda _connection: evaluator,
    )
    return store, evaluator, portfolio


def test_payload_rejects_all_injected_evidence() -> None:
    parse_portfolio_evaluation_payload(payload())
    for forbidden in ("model_b_sample_ids", "bars", "outcomes", "portfolio_rules"):
        value = payload()
        value[forbidden] = []
        with pytest.raises(PortfolioEvaluationError, match="unexpected"):
            parse_portfolio_evaluation_payload(value)


@pytest.mark.asyncio
async def test_fresh_evaluation_records_outcome_and_portfolio(monkeypatch) -> None:
    _store, evaluator, portfolio = install_stores(monkeypatch)

    result_hash = await PortfolioEvaluationTaskHandler(MagicMock())(lease())

    assert result_hash == portfolio.result_hash
    evaluator.record_outcome.assert_awaited_once()
    evaluator.persist_portfolio.assert_awaited_once()


@pytest.mark.asyncio
async def test_retry_verifies_existing_facts_without_rewriting(monkeypatch) -> None:
    _store, evaluator, portfolio = install_stores(monkeypatch, retry=True)

    result_hash = await PortfolioEvaluationTaskHandler(MagicMock())(lease())

    assert result_hash == portfolio.result_hash
    evaluator.record_outcome.assert_not_awaited()
    evaluator.persist_portfolio.assert_not_awaited()


@pytest.mark.asyncio
async def test_forged_decision_hash_is_rejected(monkeypatch) -> None:
    install_stores(monkeypatch, forged=True)
    with pytest.raises(PortfolioEvaluationError, match="decision diverges"):
        await PortfolioEvaluationTaskHandler(MagicMock())(lease())


@pytest.mark.asyncio
async def test_handler_requires_evaluator_executor(monkeypatch) -> None:
    install_stores(monkeypatch)
    with pytest.raises(PortfolioEvaluationError, match="EVALUATOR"):
        await PortfolioEvaluationTaskHandler(MagicMock())(
            lease(ExecutorKind.MODEL_B)
        )
