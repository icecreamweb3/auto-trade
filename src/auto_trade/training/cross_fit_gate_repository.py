"""Database evidence adapter for the Q-036 runtime gate."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import date
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.evaluator import FoldMetric, ModelBGateMetric


@dataclass(frozen=True, slots=True)
class CrossFitGateContext:
    execution_id: UUID
    execution_lease_token: UUID
    protocol_config_version_id: UUID
    corpus_hash: str
    model_b_evidence_hash: str
    tpe_optimizer_run_id: UUID
    random_optimizer_run_id: UUID
    alpha: Decimal
    confidence_level: Decimal
    minimum_effective_days: int
    minimum_effective_folds: int
    bootstrap_replicates: int
    random_seed: int
    model_a_point_threshold: Decimal
    model_a_ci_lower_threshold: Decimal
    model_b_point_threshold: Decimal
    model_b_stress_multiplier: Decimal
    model_a_metrics: tuple[FoldMetric, ...]
    model_b_metrics: tuple[ModelBGateMetric, ...]


@dataclass(frozen=True, slots=True)
class CrossFitGateRecord:
    execution_id: UUID
    execution_lease_token: UUID
    tpe_optimizer_run_id: UUID
    random_optimizer_run_id: UUID
    tpe_mean: Decimal
    random_mean: Decimal
    excess_mean: Decimal
    p_value: Decimal
    model_a_ci_lower_bound: Decimal
    model_a_ci_upper_bound: Decimal
    model_b_net_expectancy: Decimal
    model_b_stressed_ci_lower_bound: Decimal
    model_b_stress_multiplier: Decimal
    effective_day_count: int
    effective_fold_count: int


class DatabaseCrossFitGateStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(self, task_id: UUID, lease_token: UUID) -> CrossFitGateContext:
        result = await self._connection.execute(
            text(
                """
                SELECT *
                FROM strategy_training.training_cross_fit_gate_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        rows = result.mappings().all()
        if not rows:
            raise LookupError("Q-036 gate context has no evidence rows")
        first = rows[0]
        model_a = tuple(
            FoldMetric(
                int(row["fold_number"]),
                cast(date, row["prediction_day"]),
                str(row["symbol"]),
                float(row["tpe_value"]),
                float(row["random_value"]),
            )
            for row in rows
        )
        model_b = tuple(
            ModelBGateMetric(
                cast(date, row["prediction_day"]),
                str(row["symbol"]),
                float(row["model_b_net_expectancy"]),
                float(row["model_b_stressed_net_expectancy"]),
            )
            for row in rows
        )
        return CrossFitGateContext(
            cast(UUID, first["execution_id"]),
            cast(UUID, first["execution_lease_token"]),
            cast(UUID, first["protocol_config_version_id"]),
            str(first["corpus_hash"]),
            str(first["model_b_evidence_hash"]),
            cast(UUID, first["tpe_optimizer_run_id"]),
            cast(UUID, first["random_optimizer_run_id"]),
            Decimal(str(first["alpha"])),
            Decimal(str(first["confidence_level"])),
            int(first["minimum_effective_days"]),
            int(first["minimum_effective_folds"]),
            int(first["bootstrap_replicates"]),
            int(first["random_seed"]),
            Decimal(str(first["model_a_point_threshold"])),
            Decimal(str(first["model_a_ci_lower_threshold"])),
            Decimal(str(first["model_b_point_threshold"])),
            Decimal(str(first["model_b_stress_multiplier"])),
            model_a,
            model_b,
        )

    async def record_gate(self, facts: CrossFitGateRecord) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_cross_fit_go_no_go(
                    :execution_id, :execution_lease_token,
                    :tpe_optimizer_run_id, :random_optimizer_run_id,
                    :tpe_mean, :random_mean, :excess_mean, :p_value,
                    :model_a_ci_lower_bound, :model_a_ci_upper_bound,
                    :model_b_net_expectancy, :model_b_stressed_ci_lower_bound,
                    :model_b_stress_multiplier, :effective_day_count,
                    :effective_fold_count
                )
                """
            ),
            asdict(facts),
        )
        return cast(UUID, result.scalar_one())

    async def apply_gate(
        self, execution_id: UUID, lease_token: UUID, evaluation_id: UUID
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.apply_cross_fit_go_no_go(
                    :execution_id, :lease_token, :evaluation_id
                )
                """
            ),
            {
                "execution_id": execution_id,
                "lease_token": lease_token,
                "evaluation_id": evaluation_id,
            },
        )
        return str(result.scalar_one())

    async def promote_corpus(self, execution_id: UUID, lease_token: UUID) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.promote_cross_fit_corpus(
                    :execution_id, :lease_token
                )
                """
            ),
            {"execution_id": execution_id, "lease_token": lease_token},
        )
        return cast(UUID, result.scalar_one())
