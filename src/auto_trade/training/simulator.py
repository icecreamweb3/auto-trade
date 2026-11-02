from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from auto_trade.training.contracts import (
    Direction,
    EntrySource,
    EntryUse,
    TrainingContractError,
    assert_entry_source_allowed,
)


class SimulationContractError(TrainingContractError):
    """A simulation input or transition violates the frozen B-stage contract."""


class ExitReason(StrEnum):
    STOP_LOSS = "STOP_LOSS"
    TAKE_PROFIT = "TAKE_PROFIT"
    TRAILING_STOP = "TRAILING_STOP"
    MAX_HOLDING = "MAX_HOLDING"


class ExitAction(StrEnum):
    HOLD = "HOLD"
    MOVE_STOP = "MOVE_STOP"
    EXIT = "EXIT"


class IntrabarConflictPolicy(StrEnum):
    WORST_CASE = "WORST_CASE"


class SignalDisposition(StrEnum):
    ACCEPTED = "ACCEPTED"
    REJECTED_CAPITAL = "REJECTED_CAPITAL"
    REJECTED_CONCURRENCY = "REJECTED_CONCURRENCY"
    REJECTED_EXISTING_POSITION = "REJECTED_EXISTING_POSITION"


def _utc(value: datetime, field_name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise SimulationContractError(f"{field_name} must be timezone-aware UTC")
    return value.astimezone(UTC)


def _finite(value: Decimal, field_name: str) -> Decimal:
    if not value.is_finite():
        raise SimulationContractError(f"{field_name} must be finite")
    return value


def _positive(value: Decimal, field_name: str) -> Decimal:
    if _finite(value, field_name) <= 0:
        raise SimulationContractError(f"{field_name} must be positive")
    return value


def _non_negative(value: Decimal, field_name: str) -> Decimal:
    if _finite(value, field_name) < 0:
        raise SimulationContractError(f"{field_name} must be non-negative")
    return value


def _canonical_hash(value: object) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
        allow_nan=False,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


@dataclass(frozen=True, slots=True)
class FeeModel:
    version_id: UUID
    entry_taker_rate: Decimal
    exit_taker_rate: Decimal

    def __post_init__(self) -> None:
        _non_negative(self.entry_taker_rate, "entry_taker_rate")
        _non_negative(self.exit_taker_rate, "exit_taker_rate")


@dataclass(frozen=True, slots=True)
class SlippageModel:
    version_id: UUID
    base_basis_points: Decimal
    notional_coefficient: Decimal
    reference_notional: Decimal
    liquidity_coefficient: Decimal
    volatility_coefficient: Decimal
    maximum_basis_points: Decimal

    def __post_init__(self) -> None:
        _non_negative(self.base_basis_points, "base_basis_points")
        _non_negative(self.notional_coefficient, "notional_coefficient")
        _positive(self.reference_notional, "reference_notional")
        _non_negative(self.liquidity_coefficient, "liquidity_coefficient")
        _non_negative(self.volatility_coefficient, "volatility_coefficient")
        _non_negative(self.maximum_basis_points, "maximum_basis_points")
        if self.maximum_basis_points < self.base_basis_points:
            raise SimulationContractError("maximum slippage must cover base slippage")

    def basis_points(
        self,
        *,
        notional: Decimal,
        available_quote_notional: Decimal,
        volatility_percent: Decimal,
    ) -> Decimal:
        _positive(notional, "notional")
        _positive(available_quote_notional, "available_quote_notional")
        _non_negative(volatility_percent, "volatility_percent")
        estimated = (
            self.base_basis_points
            + self.notional_coefficient * notional / self.reference_notional
            + self.liquidity_coefficient * notional / available_quote_notional
            + self.volatility_coefficient * volatility_percent
        )
        return min(estimated, self.maximum_basis_points)


@dataclass(frozen=True, slots=True)
class FixedExitPolicy:
    version_id: UUID
    stop_loss_percent: Decimal
    take_profit_percent: Decimal
    trailing_activation_percent: Decimal
    trailing_distance_percent: Decimal
    max_holding: timedelta
    conflict_policy: IntrabarConflictPolicy

    def __post_init__(self) -> None:
        _positive(self.stop_loss_percent, "stop_loss_percent")
        _positive(self.take_profit_percent, "take_profit_percent")
        _non_negative(self.trailing_activation_percent, "trailing_activation_percent")
        _non_negative(self.trailing_distance_percent, "trailing_distance_percent")
        if bool(self.trailing_activation_percent) != bool(self.trailing_distance_percent):
            raise SimulationContractError(
                "trailing activation and distance must both be zero or positive"
            )
        if self.max_holding <= timedelta(0):
            raise SimulationContractError("max_holding must be positive")
        if self.conflict_policy is not IntrabarConflictPolicy.WORST_CASE:
            raise SimulationContractError("5m prototype requires WORST_CASE conflicts")


@dataclass(frozen=True, slots=True)
class SimulationBar:
    open_time: datetime
    close_time: datetime
    open_price: Decimal
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal
    available_quote_notional: Decimal
    volatility_percent: Decimal
    funding_rate: Decimal

    def __post_init__(self) -> None:
        object.__setattr__(self, "open_time", _utc(self.open_time, "open_time"))
        object.__setattr__(self, "close_time", _utc(self.close_time, "close_time"))
        if self.close_time <= self.open_time:
            raise SimulationContractError("bar close_time must follow open_time")
        for name in ("open_price", "high_price", "low_price", "close_price"):
            _positive(getattr(self, name), name)
        if self.low_price > min(self.open_price, self.close_price, self.high_price):
            raise SimulationContractError("bar low is inconsistent with OHLC")
        if self.high_price < max(self.open_price, self.close_price, self.low_price):
            raise SimulationContractError("bar high is inconsistent with OHLC")
        _positive(self.available_quote_notional, "available_quote_notional")
        _non_negative(self.volatility_percent, "volatility_percent")
        _finite(self.funding_rate, "funding_rate")


@dataclass(frozen=True, slots=True)
class ExitDecision:
    sequence_no: int
    decision_time: datetime
    action: ExitAction
    reason: str
    stop_price_before: Decimal
    stop_price_after: Decimal
    reference_price: Decimal | None
    fill_price: Decimal | None
    slippage_basis_points: Decimal | None


@dataclass(frozen=True, slots=True)
class FixedExitResult:
    entry_event_id: str
    direction: Direction
    entry_time: datetime
    entry_reference_price: Decimal
    entry_fill_price: Decimal
    exit_time: datetime
    exit_reference_price: Decimal
    exit_fill_price: Decimal
    exit_reason: ExitReason
    quantity: Decimal
    notional: Decimal
    gross_pnl: Decimal
    entry_fee: Decimal
    exit_fee: Decimal
    funding_total: Decimal
    entry_slippage: Decimal
    exit_slippage: Decimal
    slippage_total: Decimal
    net_pnl: Decimal
    decisions: tuple[ExitDecision, ...]
    result_hash: str


@dataclass(frozen=True, slots=True)
class PortfolioRules:
    version_id: UUID
    initial_capital: Decimal
    notional_per_trade: Decimal
    maximum_concurrent_positions: int

    def __post_init__(self) -> None:
        _positive(self.initial_capital, "initial_capital")
        _positive(self.notional_per_trade, "notional_per_trade")
        if self.maximum_concurrent_positions <= 0:
            raise SimulationContractError("maximum_concurrent_positions must be positive")


@dataclass(frozen=True, slots=True)
class PortfolioCandidate:
    entry_event_id: str
    instrument_id: int
    symbol: str
    source: EntrySource
    exit_result: FixedExitResult

    def __post_init__(self) -> None:
        if self.instrument_id <= 0 or not self.symbol.strip():
            raise SimulationContractError("portfolio candidate instrument is invalid")
        if self.exit_result.entry_event_id != self.entry_event_id:
            raise SimulationContractError("portfolio candidate/result identity mismatch")
        assert_entry_source_allowed(source=self.source, usage=EntryUse.MODEL_B_PROTOTYPE)


@dataclass(frozen=True, slots=True)
class PortfolioDisposition:
    entry_event_id: str
    entry_time: datetime
    disposition: SignalDisposition
    capital_before: Decimal
    occupied_before: Decimal
    open_positions_before: int


@dataclass(frozen=True, slots=True)
class PortfolioEquityPoint:
    observed_at: datetime
    balance: Decimal
    occupied_capital: Decimal
    available_capital: Decimal
    open_position_count: int
    peak_balance: Decimal
    drawdown_percent: Decimal
    event_type: str
    entry_event_id: str


@dataclass(frozen=True, slots=True)
class PortfolioResult:
    rules_version_id: UUID
    dispositions: tuple[PortfolioDisposition, ...]
    accepted_trades: tuple[FixedExitResult, ...]
    equity_points: tuple[PortfolioEquityPoint, ...]
    final_balance: Decimal
    maximum_drawdown_percent: Decimal
    peak_occupied_capital: Decimal
    result_hash: str


def _adverse_fill(
    reference_price: Decimal,
    direction: Direction,
    basis_points: Decimal,
    *,
    entering: bool,
) -> Decimal:
    fraction = basis_points / Decimal(10_000)
    price_increases_cost = (direction is Direction.LONG) == entering
    multiplier = Decimal(1) + fraction if price_increases_cost else Decimal(1) - fraction
    return reference_price * multiplier


def _initial_stop(entry: Decimal, direction: Direction, percent: Decimal) -> Decimal:
    fraction = percent / 100
    return entry * (Decimal(1) - fraction if direction is Direction.LONG else Decimal(1) + fraction)


def _target(entry: Decimal, direction: Direction, percent: Decimal) -> Decimal:
    fraction = percent / 100
    return entry * (Decimal(1) + fraction if direction is Direction.LONG else Decimal(1) - fraction)


class FixedExitReplay:
    """Online state machine: each action is decided before the next bar is visible."""

    def __init__(
        self,
        *,
        entry_event_id: str,
        direction: Direction,
        entry_time: datetime,
        entry_reference_price: Decimal,
        notional: Decimal,
        policy: FixedExitPolicy,
        fee_model: FeeModel,
        slippage_model: SlippageModel,
    ) -> None:
        if len(entry_event_id) != 64 or any(
            character not in "0123456789abcdef" for character in entry_event_id
        ):
            raise SimulationContractError("entry_event_id must be a lowercase SHA-256")
        self.entry_event_id = entry_event_id
        self.direction = direction
        self.entry_time = _utc(entry_time, "entry_time")
        self.entry_reference_price = _positive(entry_reference_price, "entry_reference_price")
        self.notional = _positive(notional, "notional")
        self.policy = policy
        self.fee_model = fee_model
        self.slippage_model = slippage_model
        self.holding_end = self.entry_time + policy.max_holding
        self.entry_fill: Decimal | None = None
        self.quantity: Decimal | None = None
        self.stop: Decimal | None = None
        self.hard_stop: Decimal | None = None
        self.target: Decimal | None = None
        self.funding_total = Decimal(0)
        self.decisions: list[ExitDecision] = []
        self.result: FixedExitResult | None = None
        self._last_close_time: datetime | None = None

    def step(self, bar: SimulationBar) -> ExitDecision:
        if self.result is not None:
            raise SimulationContractError("cannot append a bar after the governed exit")
        if self._last_close_time is None:
            if bar.open_time != self.entry_time:
                raise SimulationContractError("first bar must open exactly at entry_time")
            entry_bps = self.slippage_model.basis_points(
                notional=self.notional,
                available_quote_notional=bar.available_quote_notional,
                volatility_percent=bar.volatility_percent,
            )
            self.entry_fill = _adverse_fill(
                self.entry_reference_price,
                self.direction,
                entry_bps,
                entering=True,
            )
            self.quantity = self.notional / self.entry_fill
            self.stop = _initial_stop(
                self.entry_fill, self.direction, self.policy.stop_loss_percent
            )
            self.hard_stop = self.stop
            self.target = _target(self.entry_fill, self.direction, self.policy.take_profit_percent)
        elif bar.open_time != self._last_close_time:
            raise SimulationContractError("simulation bars must be contiguous and ordered")
        if bar.open_time >= self.holding_end:
            raise SimulationContractError("bar starts after the maximum holding boundary")
        assert self.quantity is not None
        assert self.stop is not None
        assert self.hard_stop is not None
        assert self.target is not None
        assert self.entry_fill is not None
        funding_direction = Decimal(1) if self.direction is Direction.LONG else Decimal(-1)
        self.funding_total += self.quantity * bar.close_price * bar.funding_rate * funding_direction
        stop_hit = (
            bar.low_price <= self.stop
            if self.direction is Direction.LONG
            else bar.high_price >= self.stop
        )
        target_hit = (
            bar.high_price >= self.target
            if self.direction is Direction.LONG
            else bar.low_price <= self.target
        )
        exit_reference: Decimal | None = None
        exit_reason: ExitReason | None = None
        if stop_hit:
            exit_reference = (
                min(bar.open_price, self.stop)
                if self.direction is Direction.LONG
                else max(bar.open_price, self.stop)
            )
            exit_reason = (
                ExitReason.STOP_LOSS if self.stop == self.hard_stop else ExitReason.TRAILING_STOP
            )
        elif target_hit:
            exit_reference = self.target
            exit_reason = ExitReason.TAKE_PROFIT
        elif bar.close_time >= self.holding_end:
            exit_reference = bar.close_price
            exit_reason = ExitReason.MAX_HOLDING
        sequence = len(self.decisions) + 1
        if exit_reason is not None:
            assert exit_reference is not None
            exit_bps = self.slippage_model.basis_points(
                notional=self.quantity * exit_reference,
                available_quote_notional=bar.available_quote_notional,
                volatility_percent=bar.volatility_percent,
            )
            exit_fill = _adverse_fill(exit_reference, self.direction, exit_bps, entering=False)
            decision = ExitDecision(
                sequence,
                min(bar.close_time, self.holding_end),
                ExitAction.EXIT,
                exit_reason.value,
                self.stop,
                self.stop,
                exit_reference,
                exit_fill,
                exit_bps,
            )
            self.decisions.append(decision)
            self.result = self._build_result(decision, exit_reason)
        else:
            new_stop = self.stop
            if self.policy.trailing_activation_percent > 0:
                activation = _target(
                    self.entry_fill,
                    self.direction,
                    self.policy.trailing_activation_percent,
                )
                if self.direction is Direction.LONG and bar.high_price >= activation:
                    new_stop = max(
                        self.stop,
                        bar.high_price * (Decimal(1) - self.policy.trailing_distance_percent / 100),
                    )
                elif self.direction is Direction.SHORT and bar.low_price <= activation:
                    new_stop = min(
                        self.stop,
                        bar.low_price * (Decimal(1) + self.policy.trailing_distance_percent / 100),
                    )
            action = ExitAction.MOVE_STOP if new_stop != self.stop else ExitAction.HOLD
            decision = ExitDecision(
                sequence,
                bar.close_time,
                action,
                "TRAILING_RULE" if action is ExitAction.MOVE_STOP else "NO_EXIT_TRIGGER",
                self.stop,
                new_stop,
                None,
                None,
                None,
            )
            self.decisions.append(decision)
            self.stop = new_stop
        self._last_close_time = bar.close_time
        return decision

    def _build_result(
        self, exit_decision: ExitDecision, exit_reason: ExitReason
    ) -> FixedExitResult:
        assert self.entry_fill is not None
        assert self.quantity is not None
        assert exit_decision.fill_price is not None
        assert exit_decision.reference_price is not None
        exit_fill = exit_decision.fill_price
        exit_reference = exit_decision.reference_price
        entry_fee = self.notional * self.fee_model.entry_taker_rate
        exit_fee = self.quantity * exit_fill * self.fee_model.exit_taker_rate
        gross_pnl = (
            self.quantity * (exit_fill - self.entry_fill)
            if self.direction is Direction.LONG
            else self.quantity * (self.entry_fill - exit_fill)
        )
        entry_slippage = self.quantity * abs(self.entry_fill - self.entry_reference_price)
        exit_slippage = self.quantity * abs(exit_fill - exit_reference)
        slippage_total = entry_slippage + exit_slippage
        net_pnl = gross_pnl - entry_fee - exit_fee - self.funding_total
        payload = {
            "decisions": self.decisions,
            "entry_event_id": self.entry_event_id,
            "entry_fill_price": self.entry_fill,
            "exit_fill_price": exit_fill,
            "exit_reason": exit_reason.value,
            "fee_model_version_id": self.fee_model.version_id,
            "funding_total": self.funding_total,
            "net_pnl": net_pnl,
            "policy_version_id": self.policy.version_id,
            "slippage_model_version_id": self.slippage_model.version_id,
        }
        return FixedExitResult(
            self.entry_event_id,
            self.direction,
            self.entry_time,
            self.entry_reference_price,
            self.entry_fill,
            exit_decision.decision_time,
            exit_reference,
            exit_fill,
            exit_reason,
            self.quantity,
            self.notional,
            gross_pnl,
            entry_fee,
            exit_fee,
            self.funding_total,
            entry_slippage,
            exit_slippage,
            slippage_total,
            net_pnl,
            tuple(self.decisions),
            _canonical_hash(payload),
        )


def simulate_fixed_exit(
    *,
    entry_event_id: str,
    direction: Direction,
    entry_time: datetime,
    entry_reference_price: Decimal,
    notional: Decimal,
    bars: tuple[SimulationBar, ...],
    policy: FixedExitPolicy,
    fee_model: FeeModel,
    slippage_model: SlippageModel,
) -> FixedExitResult:
    if not bars:
        raise SimulationContractError("fixed exit requires a complete holding path")
    replay = FixedExitReplay(
        entry_event_id=entry_event_id,
        direction=direction,
        entry_time=entry_time,
        entry_reference_price=entry_reference_price,
        notional=notional,
        policy=policy,
        fee_model=fee_model,
        slippage_model=slippage_model,
    )
    for bar in bars:
        replay.step(bar)
        if replay.result is not None:
            return replay.result
    raise SimulationContractError("holding path ended without a governed exit")


def simulate_portfolio(
    *,
    candidates: tuple[PortfolioCandidate, ...],
    rules: PortfolioRules,
) -> PortfolioResult:
    identities = [candidate.entry_event_id for candidate in candidates]
    if len(identities) != len(set(identities)):
        raise SimulationContractError("portfolio candidate IDs must be unique")
    ordered = tuple(
        sorted(
            candidates,
            key=lambda candidate: (
                candidate.exit_result.entry_time,
                candidate.entry_event_id,
            ),
        )
    )
    balance = rules.initial_capital
    peak_balance = balance
    maximum_drawdown = Decimal(0)
    peak_occupied = Decimal(0)
    open_candidates: list[PortfolioCandidate] = []
    dispositions: list[PortfolioDisposition] = []
    accepted: list[FixedExitResult] = []
    equity: list[PortfolioEquityPoint] = []

    def occupied_capital() -> Decimal:
        return sum(
            (candidate.exit_result.notional for candidate in open_candidates),
            start=Decimal(0),
        )

    def record_equity(observed_at: datetime, event_type: str, entry_event_id: str) -> None:
        nonlocal peak_balance, maximum_drawdown, peak_occupied
        occupied = occupied_capital()
        peak_occupied = max(peak_occupied, occupied)
        peak_balance = max(peak_balance, balance)
        drawdown = (peak_balance - balance) / peak_balance * 100 if peak_balance > 0 else Decimal(0)
        maximum_drawdown = max(maximum_drawdown, drawdown)
        equity.append(
            PortfolioEquityPoint(
                observed_at,
                balance,
                occupied,
                balance - occupied,
                len(open_candidates),
                peak_balance,
                drawdown,
                event_type,
                entry_event_id,
            )
        )

    def settle_through(timestamp: datetime) -> None:
        nonlocal balance
        closing = sorted(
            (
                candidate
                for candidate in open_candidates
                if candidate.exit_result.exit_time <= timestamp
            ),
            key=lambda candidate: (
                candidate.exit_result.exit_time,
                candidate.entry_event_id,
            ),
        )
        for candidate in closing:
            open_candidates.remove(candidate)
            balance += candidate.exit_result.net_pnl
            record_equity(
                candidate.exit_result.exit_time,
                "EXIT",
                candidate.entry_event_id,
            )

    for candidate in ordered:
        result = candidate.exit_result
        if result.notional != rules.notional_per_trade:
            raise SimulationContractError("trade notional differs from frozen portfolio rules")
        settle_through(result.entry_time)
        occupied_before = occupied_capital()
        open_before = len(open_candidates)
        disposition = SignalDisposition.ACCEPTED
        if any(
            open_candidate.instrument_id == candidate.instrument_id
            for open_candidate in open_candidates
        ):
            disposition = SignalDisposition.REJECTED_EXISTING_POSITION
        elif open_before >= rules.maximum_concurrent_positions:
            disposition = SignalDisposition.REJECTED_CONCURRENCY
        elif balance - occupied_before < rules.notional_per_trade:
            disposition = SignalDisposition.REJECTED_CAPITAL
        dispositions.append(
            PortfolioDisposition(
                candidate.entry_event_id,
                result.entry_time,
                disposition,
                balance,
                occupied_before,
                open_before,
            )
        )
        if disposition is SignalDisposition.ACCEPTED:
            open_candidates.append(candidate)
            accepted.append(result)
            record_equity(result.entry_time, "ENTRY", candidate.entry_event_id)

    if open_candidates:
        settle_through(max(candidate.exit_result.exit_time for candidate in open_candidates))
    payload = {
        "accepted_trade_hashes": [trade.result_hash for trade in accepted],
        "dispositions": dispositions,
        "equity_points": equity,
        "rules_version_id": rules.version_id,
    }
    return PortfolioResult(
        rules.version_id,
        tuple(dispositions),
        tuple(accepted),
        tuple(equity),
        balance,
        maximum_drawdown,
        peak_occupied,
        _canonical_hash(payload),
    )
