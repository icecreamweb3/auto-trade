from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
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
    REDUCE = "REDUCE"
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
class PartialTakeProfitLevel:
    trigger_profit_percent: Decimal
    close_fraction: Decimal

    def __post_init__(self) -> None:
        _positive(self.trigger_profit_percent, "trigger_profit_percent")
        _positive(self.close_fraction, "close_fraction")
        if self.close_fraction >= 1:
            raise SimulationContractError("partial close_fraction must be below one")


@dataclass(frozen=True, slots=True)
class StopScheduleLevel:
    trigger_profit_percent: Decimal
    locked_profit_percent: Decimal

    def __post_init__(self) -> None:
        _positive(self.trigger_profit_percent, "trigger_profit_percent")
        _non_negative(self.locked_profit_percent, "locked_profit_percent")
        if self.locked_profit_percent >= self.trigger_profit_percent:
            raise SimulationContractError("locked profit must remain below its trigger")


@dataclass(frozen=True, slots=True)
class FixedExitPolicy:
    version_id: UUID
    stop_loss_percent: Decimal
    take_profit_percent: Decimal
    trailing_activation_percent: Decimal
    trailing_distance_percent: Decimal
    max_holding: timedelta
    conflict_policy: IntrabarConflictPolicy
    model_family: str = "RULE_BASED_EXIT_V1"
    partial_take_profit_levels: tuple[PartialTakeProfitLevel, ...] = ()
    stop_schedule_levels: tuple[StopScheduleLevel, ...] = ()
    high_water_trailing_activation_percent: Decimal = Decimal(0)
    high_water_max_drawdown_percent: Decimal = Decimal(0)
    return_basis: str = "ENTRY_FILL_PRICE_PERCENT"
    partial_fraction_basis: str = "REMAINING_POSITION"
    rule_activation_timing: str = "NEXT_BAR"

    def __post_init__(self) -> None:
        _positive(self.stop_loss_percent, "stop_loss_percent")
        _non_negative(self.trailing_activation_percent, "trailing_activation_percent")
        _non_negative(self.trailing_distance_percent, "trailing_distance_percent")
        if self.max_holding <= timedelta(0):
            raise SimulationContractError("max_holding must be positive")
        if self.conflict_policy is not IntrabarConflictPolicy.WORST_CASE:
            raise SimulationContractError("5m prototype requires WORST_CASE conflicts")
        if self.model_family == "RULE_BASED_EXIT_V1":
            _positive(self.take_profit_percent, "take_profit_percent")
            if bool(self.trailing_activation_percent) != bool(self.trailing_distance_percent):
                raise SimulationContractError(
                    "trailing activation and distance must both be zero or positive"
                )
            if self.partial_take_profit_levels or self.stop_schedule_levels:
                raise SimulationContractError("V1 policy cannot contain V2 schedules")
            return
        if self.model_family != "RULE_BASED_EXIT_V2":
            raise SimulationContractError("unsupported rule-based exit model family")
        if (
            self.take_profit_percent != 0
            or self.trailing_activation_percent != 0
            or self.trailing_distance_percent != 0
        ):
            raise SimulationContractError("V2 policy cannot mix V1 exit parameters")
        if self.return_basis != "ENTRY_FILL_PRICE_PERCENT":
            raise SimulationContractError("V2 return basis must use the entry fill price")
        if self.partial_fraction_basis != "REMAINING_POSITION":
            raise SimulationContractError("V2 partial exits must use remaining position")
        if self.rule_activation_timing != "NEXT_BAR":
            raise SimulationContractError("V2 stop changes must activate on the next bar")
        if not self.partial_take_profit_levels or not self.stop_schedule_levels:
            raise SimulationContractError("V2 requires partial-profit and stop schedules")
        partial_triggers = tuple(
            level.trigger_profit_percent for level in self.partial_take_profit_levels
        )
        stop_triggers = tuple(level.trigger_profit_percent for level in self.stop_schedule_levels)
        if partial_triggers != tuple(sorted(set(partial_triggers))):
            raise SimulationContractError("partial-profit triggers must strictly increase")
        if stop_triggers != tuple(sorted(set(stop_triggers))):
            raise SimulationContractError("stop-schedule triggers must strictly increase")
        locked = tuple(level.locked_profit_percent for level in self.stop_schedule_levels)
        if locked != tuple(sorted(locked)):
            raise SimulationContractError("locked profits cannot move backward")
        _positive(
            self.high_water_trailing_activation_percent,
            "high_water_trailing_activation_percent",
        )
        _positive(self.high_water_max_drawdown_percent, "high_water_max_drawdown_percent")
        if self.high_water_max_drawdown_percent >= self.high_water_trailing_activation_percent:
            raise SimulationContractError("high-water drawdown must be below activation")


def fixed_exit_policy_from_config(
    version_id: UUID,
    config: Mapping[str, object],
) -> FixedExitPolicy:
    """Parse a frozen governed config without rewriting legacy V1 evidence."""

    def decimal(field: str, source: Mapping[str, object] = config) -> Decimal:
        value = source.get(field)
        if isinstance(value, bool) or value is None:
            raise SimulationContractError(f"trusted EXIT_RULES is missing {field}")
        try:
            return Decimal(str(value))
        except (ValueError, ArithmeticError) as error:
            raise SimulationContractError(f"trusted EXIT_RULES has invalid {field}") from error

    try:
        conflict = IntrabarConflictPolicy(str(config["intrabar_conflict_policy"]))
        max_holding = timedelta(seconds=int(decimal("max_holding_seconds")))
    except (KeyError, ValueError, OverflowError) as error:
        raise SimulationContractError("trusted EXIT_RULES has invalid boundaries") from error
    family = str(config.get("model_family", "RULE_BASED_EXIT_V1"))
    if family == "RULE_BASED_EXIT_V1":
        return FixedExitPolicy(
            version_id,
            decimal("stop_loss_percent"),
            decimal("take_profit_percent"),
            decimal("trailing_activation_percent"),
            decimal("trailing_distance_percent"),
            max_holding,
            conflict,
        )
    partial = config.get("partial_take_profit")
    stop_schedule = config.get("stop_schedule")
    if not isinstance(partial, Mapping) or not isinstance(stop_schedule, Mapping):
        raise SimulationContractError("V2 EXIT_RULES schedules must be objects")
    raw_partial_levels = partial.get("levels")
    raw_stop_levels = stop_schedule.get("levels")
    if not isinstance(raw_partial_levels, list) or not isinstance(raw_stop_levels, list):
        raise SimulationContractError("V2 EXIT_RULES levels must be arrays")
    try:
        partial_levels = tuple(
            PartialTakeProfitLevel(
                decimal("trigger_profit_percent", level),
                decimal("close_fraction", level),
            )
            for level in raw_partial_levels
            if isinstance(level, Mapping)
        )
        stop_levels = tuple(
            StopScheduleLevel(
                decimal("trigger_profit_percent", level),
                decimal("locked_profit_percent", level),
            )
            for level in raw_stop_levels
            if isinstance(level, Mapping)
        )
    except SimulationContractError:
        raise
    if len(partial_levels) != len(raw_partial_levels) or len(stop_levels) != len(raw_stop_levels):
        raise SimulationContractError("V2 EXIT_RULES level entries must be objects")
    return FixedExitPolicy(
        version_id,
        decimal("initial_stop_loss_percent"),
        Decimal(0),
        Decimal(0),
        Decimal(0),
        max_holding,
        conflict,
        family,
        partial_levels,
        stop_levels,
        decimal("high_water_trailing_activation_percent", stop_schedule),
        decimal("high_water_max_drawdown_percent", stop_schedule),
        str(config.get("return_basis", "")),
        str(partial.get("fraction_basis", "")),
        str(config.get("rule_activation_timing", "")),
    )


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


@dataclass(frozen=True, slots=True, repr=False)
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
    fills: tuple[ExitFill, ...] = ()
    remaining_quantity_after: Decimal | None = None

    def __repr__(self) -> str:
        fields = (
            f"sequence_no={self.sequence_no!r}, decision_time={self.decision_time!r}, "
            f"action={self.action!r}, reason={self.reason!r}, "
            f"stop_price_before={self.stop_price_before!r}, "
            f"stop_price_after={self.stop_price_after!r}, "
            f"reference_price={self.reference_price!r}, fill_price={self.fill_price!r}, "
            f"slippage_basis_points={self.slippage_basis_points!r}"
        )
        if self.fills or self.remaining_quantity_after is not None:
            fields += (
                f", fills={self.fills!r}, "
                f"remaining_quantity_after={self.remaining_quantity_after!r}"
            )
        return f"ExitDecision({fields})"


@dataclass(frozen=True, slots=True)
class ExitFill:
    fill_time: datetime
    reference_price: Decimal
    fill_price: Decimal
    quantity: Decimal
    fee: Decimal
    slippage_cost: Decimal
    reason: str


def exit_decision_position_state(direction: Direction, decision: ExitDecision) -> dict[str, object]:
    state: dict[str, object] = {
        "direction": direction.value,
        "stop_after": decision.stop_price_after,
        "stop_before": decision.stop_price_before,
    }
    if decision.remaining_quantity_after is not None:
        state["remaining_quantity_after"] = decision.remaining_quantity_after
        state["fills"] = [
            {
                "fee": fill.fee,
                "fill_price": fill.fill_price,
                "fill_time": fill.fill_time,
                "quantity": fill.quantity,
                "reason": fill.reason,
                "reference_price": fill.reference_price,
                "slippage_cost": fill.slippage_cost,
            }
            for fill in decision.fills
        ]
    return state


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
    exit_fills: tuple[ExitFill, ...]
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
        self.remaining_quantity: Decimal | None = None
        self.stop: Decimal | None = None
        self.hard_stop: Decimal | None = None
        self.target: Decimal | None = None
        self.funding_total = Decimal(0)
        self.exit_fills: list[ExitFill] = []
        self._next_partial_level = 0
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
            self.remaining_quantity = self.quantity
            self.stop = _initial_stop(
                self.entry_fill, self.direction, self.policy.stop_loss_percent
            )
            self.hard_stop = self.stop
            if self.policy.model_family == "RULE_BASED_EXIT_V1":
                self.target = _target(
                    self.entry_fill, self.direction, self.policy.take_profit_percent
                )
        elif bar.open_time != self._last_close_time:
            raise SimulationContractError("simulation bars must be contiguous and ordered")
        if bar.open_time >= self.holding_end:
            raise SimulationContractError("bar starts after the maximum holding boundary")
        assert self.quantity is not None
        assert self.remaining_quantity is not None
        assert self.stop is not None
        assert self.hard_stop is not None
        assert self.entry_fill is not None
        funding_direction = Decimal(1) if self.direction is Direction.LONG else Decimal(-1)
        self.funding_total += (
            self.remaining_quantity * bar.close_price * bar.funding_rate * funding_direction
        )
        stop_hit = (
            bar.low_price <= self.stop
            if self.direction is Direction.LONG
            else bar.high_price >= self.stop
        )
        target_hit = False
        if self.target is not None:
            target_hit = (
                bar.high_price >= self.target
                if self.direction is Direction.LONG
                else bar.low_price <= self.target
            )
        exit_reference: Decimal | None = None
        exit_reason: ExitReason | None = None
        decision_fills: list[ExitFill] = []
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
            assert self.target is not None
            exit_reference = self.target
            exit_reason = ExitReason.TAKE_PROFIT
        elif self.policy.model_family == "RULE_BASED_EXIT_V2":
            decision_fills.extend(self._apply_partial_take_profits(bar))
        if exit_reason is None and bar.close_time >= self.holding_end:
            exit_reference = bar.close_price
            exit_reason = ExitReason.MAX_HOLDING
        sequence = len(self.decisions) + 1
        if exit_reason is not None:
            assert exit_reference is not None
            assert self.remaining_quantity > 0
            exit_bps = self.slippage_model.basis_points(
                notional=self.remaining_quantity * exit_reference,
                available_quote_notional=bar.available_quote_notional,
                volatility_percent=bar.volatility_percent,
            )
            exit_fill = _adverse_fill(exit_reference, self.direction, exit_bps, entering=False)
            terminal_fill = self._exit_fill(
                min(bar.close_time, self.holding_end),
                exit_reference,
                exit_fill,
                self.remaining_quantity,
                exit_bps,
                exit_reason.value,
            )
            decision_fills.append(terminal_fill)
            self.exit_fills.extend(decision_fills)
            self.remaining_quantity = Decimal(0)
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
                tuple(decision_fills) if self.policy.model_family == "RULE_BASED_EXIT_V2" else (),
                self.remaining_quantity
                if self.policy.model_family == "RULE_BASED_EXIT_V2"
                else None,
            )
            self.decisions.append(decision)
            self.result = self._build_result(decision, exit_reason)
        else:
            new_stop = self._next_stop(bar)
            if decision_fills:
                self.exit_fills.extend(decision_fills)
                action = ExitAction.REDUCE
                reason = (
                    "PARTIAL_TAKE_PROFIT_AND_STOP_SCHEDULE"
                    if new_stop != self.stop
                    else "PARTIAL_TAKE_PROFIT"
                )
                reference_price = self._weighted_fill_value(decision_fills, "reference_price")
                fill_price = self._weighted_fill_value(decision_fills, "fill_price")
                slip_bps = sum(
                    (
                        fill.slippage_cost
                        / (fill.quantity * fill.reference_price)
                        * Decimal(10_000)
                        * fill.quantity
                        for fill in decision_fills
                    ),
                    start=Decimal(0),
                ) / sum((fill.quantity for fill in decision_fills), start=Decimal(0))
            else:
                action = ExitAction.MOVE_STOP if new_stop != self.stop else ExitAction.HOLD
                reason = "TRAILING_RULE" if action is ExitAction.MOVE_STOP else "NO_EXIT_TRIGGER"
                reference_price = None
                fill_price = None
                slip_bps = None
            decision = ExitDecision(
                sequence,
                bar.close_time,
                action,
                reason,
                self.stop,
                new_stop,
                reference_price,
                fill_price,
                slip_bps,
                tuple(decision_fills) if self.policy.model_family == "RULE_BASED_EXIT_V2" else (),
                self.remaining_quantity
                if self.policy.model_family == "RULE_BASED_EXIT_V2"
                else None,
            )
            self.decisions.append(decision)
            self.stop = new_stop
        self._last_close_time = bar.close_time
        return decision

    def _apply_partial_take_profits(self, bar: SimulationBar) -> list[ExitFill]:
        assert self.entry_fill is not None
        assert self.remaining_quantity is not None
        fills: list[ExitFill] = []
        levels = self.policy.partial_take_profit_levels
        while self._next_partial_level < len(levels):
            level = levels[self._next_partial_level]
            reference = _target(self.entry_fill, self.direction, level.trigger_profit_percent)
            crossed = (
                bar.high_price >= reference
                if self.direction is Direction.LONG
                else bar.low_price <= reference
            )
            if not crossed:
                break
            quantity = self.remaining_quantity * level.close_fraction
            bps = self.slippage_model.basis_points(
                notional=quantity * reference,
                available_quote_notional=bar.available_quote_notional,
                volatility_percent=bar.volatility_percent,
            )
            fill_price = _adverse_fill(reference, self.direction, bps, entering=False)
            fills.append(
                self._exit_fill(
                    bar.close_time,
                    reference,
                    fill_price,
                    quantity,
                    bps,
                    f"PARTIAL_TAKE_PROFIT_{self._next_partial_level + 1}",
                )
            )
            self.remaining_quantity -= quantity
            self._next_partial_level += 1
        return fills

    def _next_stop(self, bar: SimulationBar) -> Decimal:
        assert self.entry_fill is not None
        assert self.stop is not None
        if self.policy.model_family == "RULE_BASED_EXIT_V1":
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
            return new_stop
        favorable_price = bar.high_price if self.direction is Direction.LONG else bar.low_price
        favorable_profit = (
            (favorable_price - self.entry_fill) / self.entry_fill * 100
            if self.direction is Direction.LONG
            else (self.entry_fill - favorable_price) / self.entry_fill * 100
        )
        locked_profit: Decimal | None = None
        for level in self.policy.stop_schedule_levels:
            if favorable_profit >= level.trigger_profit_percent:
                locked_profit = level.locked_profit_percent
        if favorable_profit >= self.policy.high_water_trailing_activation_percent:
            high_water_lock = favorable_profit - self.policy.high_water_max_drawdown_percent
            locked_profit = max(locked_profit or Decimal(0), high_water_lock)
        if locked_profit is None:
            return self.stop
        scheduled_stop = _target(self.entry_fill, self.direction, locked_profit)
        return (
            max(self.stop, scheduled_stop)
            if self.direction is Direction.LONG
            else min(self.stop, scheduled_stop)
        )

    def _exit_fill(
        self,
        fill_time: datetime,
        reference_price: Decimal,
        fill_price: Decimal,
        quantity: Decimal,
        slippage_basis_points: Decimal,
        reason: str,
    ) -> ExitFill:
        return ExitFill(
            fill_time,
            reference_price,
            fill_price,
            quantity,
            quantity * fill_price * self.fee_model.exit_taker_rate,
            quantity * abs(fill_price - reference_price),
            reason,
        )

    @staticmethod
    def _weighted_fill_value(fills: list[ExitFill], field: str) -> Decimal:
        quantity = sum((fill.quantity for fill in fills), start=Decimal(0))
        return (
            sum(
                (getattr(fill, field) * fill.quantity for fill in fills),
                start=Decimal(0),
            )
            / quantity
        )

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
        exit_fee = sum((fill.fee for fill in self.exit_fills), start=Decimal(0))
        gross_pnl = sum(
            (
                (
                    fill.quantity * (fill.fill_price - self.entry_fill)
                    if self.direction is Direction.LONG
                    else fill.quantity * (self.entry_fill - fill.fill_price)
                )
                for fill in self.exit_fills
            ),
            start=Decimal(0),
        )
        entry_slippage = self.quantity * abs(self.entry_fill - self.entry_reference_price)
        exit_slippage = sum((fill.slippage_cost for fill in self.exit_fills), start=Decimal(0))
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
        if self.policy.model_family == "RULE_BASED_EXIT_V2":
            payload["exit_fills"] = self.exit_fills
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
            tuple(self.exit_fills),
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
