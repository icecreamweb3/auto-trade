from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from datetime import datetime
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.contracts import Direction
from auto_trade.training.simulator import (
    ExitDecision,
    FixedExitResult,
    PortfolioDisposition,
    PortfolioResult,
    SimulationBar,
)


def _json_text(value: object) -> str:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
        allow_nan=False,
    )


def _hash(value: object) -> str:
    return hashlib.sha256(_json_text(value).encode()).hexdigest()


@dataclass(frozen=True, slots=True)
class SafeExitEpisode:
    exit_episode_id: str
    model_b_sample_id: str
    direction: Direction
    entry_time: datetime
    entry_reference_price: Decimal
    maximum_end_at: datetime
    interval_seconds: int


@dataclass(frozen=True, slots=True)
class AsOfSimulationBar:
    decision_feature_snapshot_id: UUID
    bar: SimulationBar


class DatabaseModelBWorkerStore:
    """The model-B connection only sees security-barrier views and controlled functions."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_episode(self, model_b_sample_id: str) -> SafeExitEpisode:
        result = await self._connection.execute(
            text(
                """
                SELECT exit_episode_id, model_b_sample_id, direction,
                       entry_time, entry_reference_price,
                       maximum_end_at, interval_seconds
                FROM strategy_training.model_b_entry_inputs
                WHERE model_b_sample_id = :model_b_sample_id AND status = 'RUNNING'
                """
            ),
            {"model_b_sample_id": model_b_sample_id},
        )
        row = cast(Mapping[str, object], result.mappings().one())
        return SafeExitEpisode(
            str(row["exit_episode_id"]),
            str(row["model_b_sample_id"]),
            Direction(str(row["direction"])),
            cast(datetime, row["entry_time"]),
            Decimal(str(row["entry_reference_price"])),
            cast(datetime, row["maximum_end_at"]),
            int(str(row["interval_seconds"])),
        )

    async def load_bar(
        self,
        episode: SafeExitEpisode,
        decision_time: datetime,
    ) -> AsOfSimulationBar:
        result = await self._connection.execute(
            text(
                """
                SELECT decision_feature_snapshot_id, open_time, close_time,
                       open_price, high_price, low_price, close_price,
                       quote_volume, volatility_percent
                FROM strategy_training.model_b_market_asof(
                    :model_b_sample_id, :decision_time, :interval_seconds
                )
                """
            ),
            {
                "model_b_sample_id": episode.model_b_sample_id,
                "decision_time": decision_time,
                "interval_seconds": episode.interval_seconds,
            },
        )
        row = cast(Mapping[str, object], result.mappings().one())
        return AsOfSimulationBar(
            cast(UUID, row["decision_feature_snapshot_id"]),
            SimulationBar(
                cast(datetime, row["open_time"]),
                cast(datetime, row["close_time"]),
                Decimal(str(row["open_price"])),
                Decimal(str(row["high_price"])),
                Decimal(str(row["low_price"])),
                Decimal(str(row["close_price"])),
                Decimal(str(row["quote_volume"])),
                Decimal(str(row["volatility_percent"])),
                Decimal(0),
            ),
        )

    async def record_decision(
        self,
        episode: SafeExitEpisode,
        snapshot_id: UUID,
        decision: ExitDecision,
        direction: Direction,
    ) -> None:
        state = {
            "direction": direction.value,
            "stop_after": decision.stop_price_after,
            "stop_before": decision.stop_price_before,
        }
        payload = {
            "action": decision.action.value,
            "decision_time": decision.decision_time,
            "episode": episode.exit_episode_id,
            "fill_price": decision.fill_price,
            "position_state": state,
            "reason": decision.reason,
            "reference_price": decision.reference_price,
            "sequence_no": decision.sequence_no,
            "slippage_basis_points": decision.slippage_basis_points,
            "snapshot_id": snapshot_id,
        }
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_exit_decision(
                    :exit_episode_id, :sequence_no, :decision_time,
                    :snapshot_id, :action, :reason_code,
                    CAST(:position_state AS jsonb), :reference_price,
                    :fill_price, :slippage_basis_points, :decision_hash
                )
                """
            ),
            {
                "exit_episode_id": episode.exit_episode_id,
                "sequence_no": decision.sequence_no,
                "decision_time": decision.decision_time,
                "snapshot_id": snapshot_id,
                "action": decision.action.value,
                "reason_code": decision.reason,
                "position_state": _json_text(state),
                "reference_price": decision.reference_price,
                "fill_price": decision.fill_price,
                "slippage_basis_points": decision.slippage_basis_points,
                "decision_hash": _hash(payload),
            },
        )


class DatabaseSimulationEvaluatorStore:
    """Evaluator-only writes for outcomes and normalized portfolio facts."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def create_episode(
        self,
        *,
        entry_event_id: str,
        model_b_iteration_id: UUID,
        exit_rule_version_id: UUID,
        fee_model_version_id: UUID,
        slippage_model_version_id: UUID,
    ) -> tuple[str, str]:
        result = await self._connection.execute(
            text(
                """
                SELECT created_exit_episode_id, created_model_b_sample_id
                FROM strategy_training.create_training_exit_episode(
                    :entry_event_id, :iteration_id, :exit_rule_id,
                    :fee_model_id, :slippage_model_id
                )
                """
            ),
            {
                "entry_event_id": entry_event_id,
                "iteration_id": model_b_iteration_id,
                "exit_rule_id": exit_rule_version_id,
                "fee_model_id": fee_model_version_id,
                "slippage_model_id": slippage_model_version_id,
            },
        )
        row = cast(Mapping[str, object], result.mappings().one())
        return str(row["created_exit_episode_id"]), str(row["created_model_b_sample_id"])

    async def record_outcome(self, exit_episode_id: str, result: FixedExitResult) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_exit_outcome(
                    :episode_id, :exit_time, :exit_price, :exit_reason,
                    :gross_pnl, :entry_fee, :exit_fee, :funding_total,
                    :slippage_total, :net_pnl,
                    CAST(:risk_codes AS jsonb), :result_hash
                )
                """
            ),
            {
                "episode_id": exit_episode_id,
                "exit_time": result.exit_time,
                "exit_price": result.exit_fill_price,
                "exit_reason": result.exit_reason.value,
                "gross_pnl": result.gross_pnl,
                "entry_fee": result.entry_fee,
                "exit_fee": result.exit_fee,
                "funding_total": result.funding_total,
                "slippage_total": result.slippage_total,
                "net_pnl": result.net_pnl,
                "risk_codes": "[]",
                "result_hash": result.result_hash,
            },
        )

    async def persist_portfolio(
        self,
        *,
        model_b_iteration_id: UUID,
        portfolio_rule_version_id: UUID,
        fee_model_version_id: UUID,
        slippage_model_version_id: UUID,
        episode_ids_by_entry: Mapping[str, str],
        result: PortfolioResult,
    ) -> UUID:
        run_result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.create_training_portfolio_run(
                    :iteration_id, :portfolio_rule_id,
                    :fee_model_id, :slippage_model_id
                )
                """
            ),
            {
                "iteration_id": model_b_iteration_id,
                "portfolio_rule_id": portfolio_rule_version_id,
                "fee_model_id": fee_model_version_id,
                "slippage_model_id": slippage_model_version_id,
            },
        )
        run_id = cast(UUID, run_result.scalar_one())
        for disposition in result.dispositions:
            await self._record_disposition(
                run_id,
                episode_ids_by_entry[disposition.entry_event_id],
                disposition,
            )
        for trade in result.accepted_trades:
            await self._record_trade(
                run_id,
                episode_ids_by_entry[trade.entry_event_id],
                trade,
            )
        for sequence, point in enumerate(result.equity_points, start=1):
            await self._connection.execute(
                text(
                    """
                    SELECT strategy_training.record_training_portfolio_equity_point(
                        :run_id, :sequence_no, :observed_at, :balance,
                        :occupied, :available, :open_count, :peak_balance,
                        :drawdown, :event_type, :entry_event_id, :point_hash
                    )
                    """
                ),
                {
                    "run_id": run_id,
                    "sequence_no": sequence,
                    "observed_at": point.observed_at,
                    "balance": point.balance,
                    "occupied": point.occupied_capital,
                    "available": point.available_capital,
                    "open_count": point.open_position_count,
                    "peak_balance": point.peak_balance,
                    "drawdown": point.drawdown_percent,
                    "event_type": point.event_type,
                    "entry_event_id": point.entry_event_id,
                    "point_hash": _hash(asdict(point)),
                },
            )
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_portfolio_run(
                    :run_id, :final_balance, :maximum_drawdown,
                    :peak_occupied, :result_hash
                )
                """
            ),
            {
                "run_id": run_id,
                "final_balance": result.final_balance,
                "maximum_drawdown": result.maximum_drawdown_percent,
                "peak_occupied": result.peak_occupied_capital,
                "result_hash": result.result_hash,
            },
        )
        return run_id

    async def _record_disposition(
        self,
        run_id: UUID,
        episode_id: str,
        disposition: PortfolioDisposition,
    ) -> None:
        values = cast(dict[str, object], asdict(disposition))
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_portfolio_disposition(
                    :run_id, :entry_event_id, :episode_id, :entry_time,
                    :disposition, :capital_before, :occupied_before,
                    :open_before, :disposition_hash
                )
                """
            ),
            {
                "run_id": run_id,
                "entry_event_id": values["entry_event_id"],
                "episode_id": episode_id,
                "entry_time": values["entry_time"],
                "disposition": str(values["disposition"]),
                "capital_before": values["capital_before"],
                "occupied_before": values["occupied_before"],
                "open_before": values["open_positions_before"],
                "disposition_hash": _hash(values),
            },
        )

    async def _record_trade(self, run_id: UUID, episode_id: str, trade: FixedExitResult) -> None:
        created = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_portfolio_trade(
                    :run_id, :entry_event_id, :episode_id,
                    :quantity, :notional, :trade_hash
                )
                """
            ),
            {
                "run_id": run_id,
                "entry_event_id": trade.entry_event_id,
                "episode_id": episode_id,
                "quantity": trade.quantity,
                "notional": trade.notional,
                "trade_hash": trade.result_hash,
            },
        )
        trade_id = cast(UUID, created.scalar_one())
        fills = (
            (
                1,
                "ENTRY",
                trade.entry_time,
                trade.entry_fill_price,
                trade.entry_fee,
                trade.entry_slippage,
            ),
            (
                2,
                "EXIT",
                trade.exit_time,
                trade.exit_fill_price,
                trade.exit_fee,
                trade.exit_slippage,
            ),
        )
        for sequence, side, fill_time, price, fee, slippage in fills:
            payload = {
                "fee": fee,
                "fill_time": fill_time,
                "price": price,
                "quantity": trade.quantity,
                "sequence": sequence,
                "side": side,
                "slippage": slippage,
                "trade_id": trade_id,
            }
            await self._connection.execute(
                text(
                    """
                    SELECT strategy_training.record_training_portfolio_fill(
                        :trade_id, :sequence_no, :side, :fill_time,
                        :price, :quantity, :fee, :slippage, :fill_hash
                    )
                    """
                ),
                {
                    "trade_id": trade_id,
                    "sequence_no": sequence,
                    "side": side,
                    "fill_time": fill_time,
                    "price": price,
                    "quantity": trade.quantity,
                    "fee": fee,
                    "slippage": slippage,
                    "fill_hash": _hash(payload),
                },
            )
