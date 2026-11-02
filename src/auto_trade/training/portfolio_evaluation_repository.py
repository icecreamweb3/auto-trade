"""Lease-bound evidence access for PORTFOLIO_EVALUATION tasks."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.contracts import Direction, EntrySource
from auto_trade.training.simulator import ExitAction, SimulationBar


@dataclass(frozen=True, slots=True)
class PortfolioEvaluationContext:
    model_b_iteration_id: UUID
    exit_rule_version_id: UUID
    exit_rule_config: Mapping[str, object]
    fee_model_version_id: UUID
    fee_model_config: Mapping[str, object]
    slippage_model_version_id: UUID
    slippage_model_config: Mapping[str, object]
    portfolio_rule_version_id: UUID
    portfolio_rule_config: Mapping[str, object]


@dataclass(frozen=True, slots=True)
class EvaluationEpisode:
    exit_episode_id: str
    model_b_sample_id: str
    entry_event_id: str
    instrument_id: int
    symbol: str
    source: EntrySource
    direction: Direction
    entry_time: datetime
    entry_reference_price: Decimal
    maximum_end_at: datetime
    interval_seconds: int


@dataclass(frozen=True, slots=True)
class RecordedExitDecision:
    sequence_no: int
    decision_time: datetime
    snapshot_id: UUID
    action: ExitAction
    reason: str
    direction: Direction
    stop_before: Decimal
    stop_after: Decimal
    reference_price: Decimal | None
    fill_price: Decimal | None
    slippage_basis_points: Decimal | None
    decision_hash: str


@dataclass(frozen=True, slots=True)
class EvaluationReplayStep:
    snapshot_id: UUID
    bar: SimulationBar
    recorded: RecordedExitDecision


@dataclass(frozen=True, slots=True)
class ExistingExitOutcome:
    exit_time: datetime
    exit_price: Decimal
    exit_reason: str
    gross_pnl: Decimal
    entry_fee: Decimal
    exit_fee: Decimal
    funding_total: Decimal
    slippage_total: Decimal
    net_pnl: Decimal
    result_hash: str


@dataclass(frozen=True, slots=True)
class ExistingPortfolioRun:
    status: str
    final_balance: Decimal | None
    maximum_drawdown_percent: Decimal | None
    peak_occupied_capital: Decimal | None
    result_hash: str | None


def _optional_decimal(value: object) -> Decimal | None:
    return None if value is None else Decimal(str(value))


class DatabasePortfolioEvaluationStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(
        self, task_id: UUID, lease_token: UUID
    ) -> PortfolioEvaluationContext:
        result = await self._connection.execute(
            text(
                """
                SELECT model_b_iteration_id,
                       exit_rule_version_id, exit_rule_config,
                       fee_model_version_id, fee_model_config,
                       slippage_model_version_id, slippage_model_config,
                       portfolio_rule_version_id, portfolio_rule_config
                FROM strategy_training.training_portfolio_evaluation_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = cast(Mapping[str, object], result.mappings().one())
        return PortfolioEvaluationContext(
            cast(UUID, row["model_b_iteration_id"]),
            cast(UUID, row["exit_rule_version_id"]),
            cast(Mapping[str, object], row["exit_rule_config"]),
            cast(UUID, row["fee_model_version_id"]),
            cast(Mapping[str, object], row["fee_model_config"]),
            cast(UUID, row["slippage_model_version_id"]),
            cast(Mapping[str, object], row["slippage_model_config"]),
            cast(UUID, row["portfolio_rule_version_id"]),
            cast(Mapping[str, object], row["portfolio_rule_config"]),
        )

    async def load_episodes(self, iteration_id: UUID) -> tuple[EvaluationEpisode, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT episode.exit_episode_id, episode.model_b_sample_id,
                       sample.entry_event_id, entry.instrument_id, entry.symbol,
                       entry.source, episode.direction, episode.entry_time,
                       episode.entry_reference_price, episode.maximum_end_at,
                       episode.interval_seconds
                FROM strategy_training.training_exit_episode_inputs episode
                JOIN strategy_training.training_model_b_sample_map sample
                  ON sample.model_b_sample_id = episode.model_b_sample_id
                JOIN strategy_training.training_entry_events entry
                  ON entry.entry_event_id = sample.entry_event_id
                WHERE episode.model_b_iteration_id = :iteration_id
                  AND episode.status = 'DECIDED'
                ORDER BY episode.entry_time, sample.entry_event_id
                """
            ),
            {"iteration_id": iteration_id},
        )
        return tuple(
            EvaluationEpisode(
                str(row["exit_episode_id"]),
                str(row["model_b_sample_id"]),
                str(row["entry_event_id"]),
                int(str(row["instrument_id"])),
                str(row["symbol"]),
                EntrySource(str(row["source"])),
                Direction(str(row["direction"])),
                cast(datetime, row["entry_time"]),
                Decimal(str(row["entry_reference_price"])),
                cast(datetime, row["maximum_end_at"]),
                int(str(row["interval_seconds"])),
            )
            for row in result.mappings().all()
        )

    async def load_replay_steps(
        self, episode: EvaluationEpisode
    ) -> tuple[EvaluationReplayStep, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT snapshot.decision_feature_snapshot_id,
                       snapshot.last_closed_bar_at, snapshot.interval_seconds,
                       snapshot.feature_json,
                       decision.sequence_no, decision.decision_time,
                       decision.action, decision.reason_code,
                       decision.position_state, decision.reference_price,
                       decision.fill_price, decision.slippage_basis_points,
                       decision.decision_hash
                FROM strategy_training.training_decision_feature_snapshots snapshot
                LEFT JOIN strategy_training.training_exit_decisions decision
                  ON decision.decision_feature_snapshot_id =
                     snapshot.decision_feature_snapshot_id
                 AND decision.exit_episode_id = snapshot.exit_episode_id
                WHERE snapshot.exit_episode_id = :exit_episode_id
                ORDER BY snapshot.decision_time
                """
            ),
            {"exit_episode_id": episode.exit_episode_id},
        )
        steps: list[EvaluationReplayStep] = []
        for row in result.mappings().all():
            if row["sequence_no"] is None:
                raise ValueError("decision snapshot has no recorded decision")
            features = cast(Mapping[str, object], row["feature_json"])
            state = cast(Mapping[str, object], row["position_state"])
            close_time = cast(datetime, row["last_closed_bar_at"])
            interval_seconds = int(str(row["interval_seconds"]))
            snapshot_id = cast(UUID, row["decision_feature_snapshot_id"])
            recorded = RecordedExitDecision(
                int(str(row["sequence_no"])),
                cast(datetime, row["decision_time"]),
                snapshot_id,
                ExitAction(str(row["action"])),
                str(row["reason_code"]),
                Direction(str(state["direction"])),
                Decimal(str(state["stop_before"])),
                Decimal(str(state["stop_after"])),
                _optional_decimal(row["reference_price"]),
                _optional_decimal(row["fill_price"]),
                _optional_decimal(row["slippage_basis_points"]),
                str(row["decision_hash"]),
            )
            steps.append(
                EvaluationReplayStep(
                    snapshot_id,
                    SimulationBar(
                        close_time - timedelta(seconds=interval_seconds),
                        close_time,
                        Decimal(str(features["open_price"])),
                        Decimal(str(features["high_price"])),
                        Decimal(str(features["low_price"])),
                        Decimal(str(features["close_price"])),
                        Decimal(str(features["quote_volume"])),
                        Decimal(str(features["volatility_percent"])),
                        Decimal(0),
                    ),
                    recorded,
                )
            )
        return tuple(steps)

    async def load_existing_outcome(
        self, exit_episode_id: str
    ) -> ExistingExitOutcome | None:
        result = await self._connection.execute(
            text(
                """
                SELECT exit_time, exit_price, exit_reason, gross_pnl,
                       entry_fee, exit_fee, funding_total, slippage_total,
                       net_pnl, result_hash
                FROM strategy_training.training_exit_outcomes
                WHERE exit_episode_id = :exit_episode_id
                """
            ),
            {"exit_episode_id": exit_episode_id},
        )
        row = result.mappings().one_or_none()
        if row is None:
            return None
        return ExistingExitOutcome(
            cast(datetime, row["exit_time"]),
            Decimal(str(row["exit_price"])),
            str(row["exit_reason"]),
            Decimal(str(row["gross_pnl"])),
            Decimal(str(row["entry_fee"])),
            Decimal(str(row["exit_fee"])),
            Decimal(str(row["funding_total"])),
            Decimal(str(row["slippage_total"])),
            Decimal(str(row["net_pnl"])),
            str(row["result_hash"]),
        )

    async def load_existing_portfolio_run(
        self, iteration_id: UUID, portfolio_rule_version_id: UUID
    ) -> ExistingPortfolioRun | None:
        result = await self._connection.execute(
            text(
                """
                SELECT status, final_balance, maximum_drawdown_percent,
                       peak_occupied_capital, result_hash
                FROM strategy_training.training_portfolio_runs
                WHERE model_b_iteration_id = :iteration_id
                  AND portfolio_rule_version_id = :portfolio_rule_version_id
                """
            ),
            {
                "iteration_id": iteration_id,
                "portfolio_rule_version_id": portfolio_rule_version_id,
            },
        )
        row = result.mappings().one_or_none()
        if row is None:
            return None
        return ExistingPortfolioRun(
            str(row["status"]),
            _optional_decimal(row["final_balance"]),
            _optional_decimal(row["maximum_drawdown_percent"]),
            _optional_decimal(row["peak_occupied_capital"]),
            None if row["result_hash"] is None else str(row["result_hash"]),
        )
