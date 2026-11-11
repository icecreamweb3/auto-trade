"""PORTFOLIO_EVALUATION v1 evaluator task handler."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from decimal import Decimal, InvalidOperation

from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.orchestrator import ExecutorKind, TaskLease
from auto_trade.training.portfolio_evaluation_repository import (
    DatabasePortfolioEvaluationStore,
    EvaluationEpisode,
    EvaluationReplayStep,
    ExistingExitOutcome,
    ExistingPortfolioRun,
    PortfolioEvaluationContext,
)
from auto_trade.training.simulation_repository import DatabaseSimulationEvaluatorStore
from auto_trade.training.simulator import (
    ExitDecision,
    FeeModel,
    FixedExitPolicy,
    FixedExitReplay,
    FixedExitResult,
    PortfolioCandidate,
    PortfolioResult,
    PortfolioRules,
    SimulationContractError,
    SlippageModel,
    exit_decision_position_state,
    fixed_exit_policy_from_config,
    simulate_portfolio,
)


class PortfolioEvaluationError(SimulationContractError):
    """Stored replay evidence cannot produce a governed portfolio result."""


def parse_portfolio_evaluation_payload(payload: Mapping[str, object]) -> None:
    allowed = {"task_type", "payload_version"}
    unexpected = sorted(set(payload) - allowed)
    if unexpected:
        raise PortfolioEvaluationError(
            "unexpected PORTFOLIO_EVALUATION fields: " + ", ".join(unexpected)
        )
    if payload.get("task_type") != "PORTFOLIO_EVALUATION" or payload.get("payload_version") != 1:
        raise PortfolioEvaluationError("PORTFOLIO_EVALUATION requires payload_version 1")


def _decimal(config: Mapping[str, object], field: str) -> Decimal:
    value = config.get(field)
    if isinstance(value, bool) or value is None:
        raise PortfolioEvaluationError(f"trusted evaluation config is missing {field}")
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError) as error:
        raise PortfolioEvaluationError(f"trusted evaluation config has invalid {field}") from error


def _models(
    context: PortfolioEvaluationContext,
) -> tuple[FixedExitPolicy, FeeModel, SlippageModel, PortfolioRules]:
    try:
        policy = fixed_exit_policy_from_config(
            context.exit_rule_version_id, context.exit_rule_config
        )
    except SimulationContractError as error:
        raise PortfolioEvaluationError(f"invalid frozen exit rules: {error}") from error
    taker_rate = _decimal(context.fee_model_config, "taker_rate")
    fee_model = FeeModel(context.fee_model_version_id, taker_rate, taker_rate)
    slip_config = context.slippage_model_config
    slippage_model = SlippageModel(
        context.slippage_model_version_id,
        _decimal(slip_config, "base_basis_points"),
        _decimal(slip_config, "notional_coefficient"),
        _decimal(slip_config, "reference_notional"),
        _decimal(slip_config, "liquidity_coefficient"),
        _decimal(slip_config, "volatility_coefficient"),
        _decimal(slip_config, "maximum_basis_points"),
    )
    portfolio_config = context.portfolio_rule_config
    maximum_concurrent = _decimal(portfolio_config, "maximum_concurrent_positions")
    if maximum_concurrent != maximum_concurrent.to_integral_value():
        raise PortfolioEvaluationError("maximum_concurrent_positions must be integral")
    rules = PortfolioRules(
        context.portfolio_rule_version_id,
        _decimal(portfolio_config, "initial_capital"),
        _decimal(portfolio_config, "notional_per_trade"),
        int(maximum_concurrent),
    )
    return policy, fee_model, slippage_model, rules


def _canonical_hash(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
            allow_nan=False,
        ).encode()
    ).hexdigest()


def _assert_decision_matches(
    episode: EvaluationEpisode,
    step: EvaluationReplayStep,
    generated: ExitDecision,
) -> None:
    recorded = step.recorded
    state = exit_decision_position_state(episode.direction, generated)
    payload = {
        "action": generated.action.value,
        "decision_time": generated.decision_time,
        "episode": episode.exit_episode_id,
        "fill_price": generated.fill_price,
        "position_state": state,
        "reason": generated.reason,
        "reference_price": generated.reference_price,
        "sequence_no": generated.sequence_no,
        "slippage_basis_points": generated.slippage_basis_points,
        "snapshot_id": step.snapshot_id,
    }
    if (
        recorded.sequence_no != generated.sequence_no
        or recorded.decision_time != generated.decision_time
        or recorded.action is not generated.action
        or recorded.reason != generated.reason
        or recorded.direction is not episode.direction
        or recorded.stop_before != generated.stop_price_before
        or recorded.stop_after != generated.stop_price_after
        or recorded.reference_price != generated.reference_price
        or recorded.fill_price != generated.fill_price
        or recorded.slippage_basis_points != generated.slippage_basis_points
        or recorded.decision_hash != _canonical_hash(payload)
    ):
        raise PortfolioEvaluationError(
            f"stored model-B decision diverges at sequence {generated.sequence_no}"
        )


def _replay_episode(
    episode: EvaluationEpisode,
    steps: tuple[EvaluationReplayStep, ...],
    *,
    policy: FixedExitPolicy,
    fee_model: FeeModel,
    slippage_model: SlippageModel,
    notional: Decimal,
) -> FixedExitResult:
    if not steps:
        raise PortfolioEvaluationError("decided episode has no replay evidence")
    replay = FixedExitReplay(
        entry_event_id=episode.entry_event_id,
        direction=episode.direction,
        entry_time=episode.entry_time,
        entry_reference_price=episode.entry_reference_price,
        notional=notional,
        policy=policy,
        fee_model=fee_model,
        slippage_model=slippage_model,
    )
    for step in steps:
        if replay.result is not None:
            raise PortfolioEvaluationError("stored decisions continue after terminal exit")
        generated = replay.step(step.bar)
        _assert_decision_matches(episode, step, generated)
    if replay.result is None:
        raise PortfolioEvaluationError("stored decisions have no terminal exit")
    if replay.result.exit_time > episode.maximum_end_at:
        raise PortfolioEvaluationError("replayed exit exceeds episode holding boundary")
    return replay.result


def _assert_outcome_matches(existing: ExistingExitOutcome, result: FixedExitResult) -> None:
    if (
        existing.exit_time != result.exit_time
        or existing.exit_price != result.exit_fill_price
        or existing.exit_reason != result.exit_reason.value
        or existing.gross_pnl != result.gross_pnl
        or existing.entry_fee != result.entry_fee
        or existing.exit_fee != result.exit_fee
        or existing.funding_total != result.funding_total
        or existing.slippage_total != result.slippage_total
        or existing.net_pnl != result.net_pnl
        or existing.result_hash != result.result_hash
    ):
        raise PortfolioEvaluationError("stored exit outcome diverges from replay")


def _assert_portfolio_matches(existing: ExistingPortfolioRun, result: PortfolioResult) -> None:
    if (
        existing.status != "COMPLETE"
        or existing.final_balance != result.final_balance
        or existing.maximum_drawdown_percent != result.maximum_drawdown_percent
        or existing.peak_occupied_capital != result.peak_occupied_capital
        or existing.result_hash != result.result_hash
    ):
        raise PortfolioEvaluationError("stored portfolio run diverges from replay")


class PortfolioEvaluationTaskHandler:
    def __init__(self, connection: AsyncConnection) -> None:
        self._store = DatabasePortfolioEvaluationStore(connection)
        self._evaluator_store = DatabaseSimulationEvaluatorStore(connection)

    async def __call__(self, lease: TaskLease) -> str:
        if lease.executor_kind is not ExecutorKind.EVALUATOR:
            raise PortfolioEvaluationError("PORTFOLIO_EVALUATION requires EVALUATOR executor")
        parse_portfolio_evaluation_payload(lease.payload)
        try:
            return await self._evaluate(lease)
        except PortfolioEvaluationError:
            raise
        except (KeyError, ValueError) as error:
            raise PortfolioEvaluationError("stored portfolio replay evidence is invalid") from error

    async def _evaluate(self, lease: TaskLease) -> str:
        context = await self._store.load_context(lease.task_id, lease.lease_token)
        policy, fee_model, slippage_model, rules = _models(context)
        episodes = await self._store.load_episodes(context.model_b_iteration_id)
        if not episodes:
            raise PortfolioEvaluationError("portfolio evaluation requires episodes")

        candidates: list[PortfolioCandidate] = []
        episode_ids_by_entry: dict[str, str] = {}
        for episode in episodes:
            result = _replay_episode(
                episode,
                await self._store.load_replay_steps(episode),
                policy=policy,
                fee_model=fee_model,
                slippage_model=slippage_model,
                notional=rules.notional_per_trade,
            )
            existing_outcome = await self._store.load_existing_outcome(episode.exit_episode_id)
            if existing_outcome is None:
                await self._evaluator_store.record_outcome(episode.exit_episode_id, result)
            else:
                _assert_outcome_matches(existing_outcome, result)
            candidates.append(
                PortfolioCandidate(
                    episode.entry_event_id,
                    episode.instrument_id,
                    episode.symbol,
                    episode.source,
                    result,
                )
            )
            episode_ids_by_entry[episode.entry_event_id] = episode.exit_episode_id

        portfolio_result = simulate_portfolio(candidates=tuple(candidates), rules=rules)
        existing_run = await self._store.load_existing_portfolio_run(
            context.model_b_iteration_id, context.portfolio_rule_version_id
        )
        if existing_run is None:
            await self._evaluator_store.persist_portfolio(
                model_b_iteration_id=context.model_b_iteration_id,
                portfolio_rule_version_id=context.portfolio_rule_version_id,
                fee_model_version_id=context.fee_model_version_id,
                slippage_model_version_id=context.slippage_model_version_id,
                episode_ids_by_entry=episode_ids_by_entry,
                result=portfolio_result,
            )
        else:
            _assert_portfolio_matches(existing_run, portfolio_result)
        await self._store.finalize_candidate_objective_if_applicable(
            lease.task_id,
            lease.lease_token,
            context.model_b_iteration_id,
        )
        return portfolio_result.result_hash
