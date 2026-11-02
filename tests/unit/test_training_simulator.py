from __future__ import annotations

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest

from auto_trade.training.contracts import Direction, EntrySource
from auto_trade.training.simulator import (
    ExitAction,
    ExitReason,
    FeeModel,
    FixedExitPolicy,
    IntrabarConflictPolicy,
    PortfolioCandidate,
    PortfolioRules,
    SignalDisposition,
    SimulationBar,
    SimulationContractError,
    SlippageModel,
    simulate_fixed_exit,
    simulate_portfolio,
)


def _time(minutes: int) -> datetime:
    return datetime(2026, 6, 1, tzinfo=UTC) + timedelta(minutes=minutes)


def _bar(
    minute: int,
    *,
    open_price: str = "100",
    high: str = "101",
    low: str = "99",
    close: str = "100",
) -> SimulationBar:
    return SimulationBar(
        _time(minute),
        _time(minute + 5),
        Decimal(open_price),
        Decimal(high),
        Decimal(low),
        Decimal(close),
        Decimal("1000000"),
        Decimal("1"),
        Decimal("0"),
    )


def _policy(**overrides: object) -> FixedExitPolicy:
    values = {
        "version_id": uuid4(),
        "stop_loss_percent": Decimal("2"),
        "take_profit_percent": Decimal("3"),
        "trailing_activation_percent": Decimal("0"),
        "trailing_distance_percent": Decimal("0"),
        "max_holding": timedelta(minutes=10),
        "conflict_policy": IntrabarConflictPolicy.WORST_CASE,
    }
    values.update(overrides)
    return FixedExitPolicy(**values)  # type: ignore[arg-type]


def _fees() -> FeeModel:
    return FeeModel(uuid4(), Decimal("0.0004"), Decimal("0.0004"))


def _slippage() -> SlippageModel:
    return SlippageModel(
        uuid4(),
        Decimal("1"),
        Decimal("0"),
        Decimal("1000"),
        Decimal("0"),
        Decimal("0"),
        Decimal("10"),
    )


def test_same_bar_stop_and_target_uses_conservative_stop() -> None:
    result = simulate_fixed_exit(
        entry_event_id="a" * 64,
        direction=Direction.LONG,
        entry_time=_time(0),
        entry_reference_price=Decimal("100"),
        notional=Decimal("1000"),
        bars=(
            _bar(0, high="104", low="97", close="101"),
            _bar(5),
        ),
        policy=_policy(),
        fee_model=_fees(),
        slippage_model=_slippage(),
    )
    assert result.exit_reason is ExitReason.STOP_LOSS
    assert result.decisions[-1].action is ExitAction.EXIT
    assert result.entry_fill_price > result.entry_reference_price
    assert result.exit_fill_price < result.exit_reference_price
    assert result.net_pnl < result.gross_pnl


def test_trailing_stop_only_becomes_effective_on_next_bar() -> None:
    result = simulate_fixed_exit(
        entry_event_id="b" * 64,
        direction=Direction.LONG,
        entry_time=_time(0),
        entry_reference_price=Decimal("100"),
        notional=Decimal("1000"),
        bars=(
            _bar(0, high="103", low="99", close="102"),
            _bar(5, open_price="102", high="102", low="100", close="101"),
            _bar(10),
        ),
        policy=_policy(
            trailing_activation_percent=Decimal("1"),
            trailing_distance_percent=Decimal("1"),
            take_profit_percent=Decimal("10"),
            max_holding=timedelta(minutes=15),
        ),
        fee_model=_fees(),
        slippage_model=_slippage(),
    )
    assert result.decisions[0].action is ExitAction.MOVE_STOP
    assert result.exit_reason is ExitReason.TRAILING_STOP
    assert result.exit_time == _time(10)


def test_timeout_exit_is_deterministic_and_includes_fees() -> None:
    kwargs = {
        "entry_event_id": "c" * 64,
        "direction": Direction.LONG,
        "entry_time": _time(0),
        "entry_reference_price": Decimal("100"),
        "notional": Decimal("1000"),
        "bars": (_bar(0), _bar(5, close="101")),
        "policy": _policy(),
        "fee_model": _fees(),
        "slippage_model": _slippage(),
    }
    first = simulate_fixed_exit(**kwargs)
    second = simulate_fixed_exit(**kwargs)
    assert first == second
    assert first.exit_reason is ExitReason.MAX_HOLDING
    assert first.result_hash == second.result_hash
    assert first.entry_fee > 0 and first.exit_fee > 0


def test_incomplete_holding_path_fails_closed() -> None:
    with pytest.raises(SimulationContractError, match="without a governed exit"):
        simulate_fixed_exit(
            entry_event_id="d" * 64,
            direction=Direction.LONG,
            entry_time=_time(0),
            entry_reference_price=Decimal("100"),
            notional=Decimal("1000"),
            bars=(_bar(0),),
            policy=_policy(),
            fee_model=_fees(),
            slippage_model=_slippage(),
        )


def _exit_result(identity: str, start_minute: int, duration_minutes: int = 10):
    return simulate_fixed_exit(
        entry_event_id=identity,
        direction=Direction.LONG,
        entry_time=_time(start_minute),
        entry_reference_price=Decimal("100"),
        notional=Decimal("1000"),
        bars=tuple(
            _bar(minute)
            for minute in range(
                start_minute,
                start_minute + duration_minutes,
                5,
            )
        ),
        policy=_policy(max_holding=timedelta(minutes=duration_minutes)),
        fee_model=_fees(),
        slippage_model=_slippage(),
    )


def test_portfolio_enforces_existing_ticker_concurrency_and_capital() -> None:
    candidates = (
        PortfolioCandidate(
            "a" * 64,
            1,
            "AAAUSDT",
            EntrySource.FIXED_BASELINE_MODEL_A,
            _exit_result("a" * 64, 0, 15),
        ),
        PortfolioCandidate(
            "b" * 64,
            1,
            "AAAUSDT",
            EntrySource.FIXED_BASELINE_MODEL_A,
            _exit_result("b" * 64, 5),
        ),
        PortfolioCandidate(
            "c" * 64,
            2,
            "BBBUSDT",
            EntrySource.FIXED_BASELINE_MODEL_A,
            _exit_result("c" * 64, 5),
        ),
        PortfolioCandidate(
            "d" * 64,
            3,
            "CCCUSDT",
            EntrySource.FIXED_BASELINE_MODEL_A,
            _exit_result("d" * 64, 5),
        ),
    )
    result = simulate_portfolio(
        candidates=candidates,
        rules=PortfolioRules(uuid4(), Decimal("2000"), Decimal("1000"), 2),
    )
    assert [item.disposition for item in result.dispositions] == [
        SignalDisposition.ACCEPTED,
        SignalDisposition.REJECTED_EXISTING_POSITION,
        SignalDisposition.ACCEPTED,
        SignalDisposition.REJECTED_CONCURRENCY,
    ]
    assert result.peak_occupied_capital == Decimal("2000")
    assert result.equity_points[-1].open_position_count == 0


def test_portfolio_processes_exit_before_entry_at_same_timestamp() -> None:
    first = PortfolioCandidate(
        "a" * 64,
        1,
        "AAAUSDT",
        EntrySource.FIXED_BASELINE_MODEL_A,
        _exit_result("a" * 64, 0),
    )
    next_trade = PortfolioCandidate(
        "b" * 64,
        1,
        "AAAUSDT",
        EntrySource.FIXED_BASELINE_MODEL_A,
        _exit_result("b" * 64, 10),
    )
    result = simulate_portfolio(
        candidates=(next_trade, first),
        rules=PortfolioRules(uuid4(), Decimal("2000"), Decimal("1000"), 1),
    )
    assert all(
        disposition.disposition is SignalDisposition.ACCEPTED for disposition in result.dispositions
    )
    assert (
        result.result_hash
        == simulate_portfolio(
            candidates=(first, next_trade),
            rules=PortfolioRules(result.rules_version_id, Decimal("2000"), Decimal("1000"), 1),
        ).result_hash
    )
