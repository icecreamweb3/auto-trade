"""Database adapter for lease-bound Cross-fit runtime facts."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection


@dataclass(frozen=True, slots=True)
class CrossFitOptimizerScope:
    execution_id: UUID
    lease_token: UUID
    fold_number: int
    optimizer_run_id: UUID
    optimizer_role: str
    effective_train_start_at: datetime
    effective_train_end_at: datetime
    prediction_start_at: datetime
    prediction_end_at: datetime


@dataclass(frozen=True, slots=True)
class CrossFitGateFacts:
    execution_id: UUID
    lease_token: UUID
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


class DatabaseCrossFitStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def prepare_optimizer_pair(
        self, task_id: UUID, lease_token: UUID
    ) -> tuple[str, str]:
        result = await self._connection.execute(
            text(
                """
                SELECT action, result_hash
                FROM strategy_training.prepare_cross_fit_optimizer_pair(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = result.mappings().one()
        return str(row["action"]), str(row["result_hash"])

    async def finalize_fold(self, task_id: UUID, lease_token: UUID) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_cross_fit_fold(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())

    async def finalize_candidate_corpus(
        self, task_id: UUID, lease_token: UUID
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_cross_fit_candidate_corpus(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())

    async def finalize_model_b_fold(
        self, task_id: UUID, lease_token: UUID
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_cross_fit_model_b_fold_task(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())

    async def finalize_model_b_gate(
        self, task_id: UUID, lease_token: UUID
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_cross_fit_model_b_gate_task(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())

    async def register_optimizer_scope(self, scope: CrossFitOptimizerScope) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.register_cross_fit_optimizer_scope(
                    :execution_id, :lease_token, :fold_number,
                    :optimizer_run_id, :optimizer_role,
                    :effective_train_start_at, :effective_train_end_at,
                    :prediction_start_at, :prediction_end_at
                )
                """
            ),
            {
                "execution_id": scope.execution_id,
                "lease_token": scope.lease_token,
                "fold_number": scope.fold_number,
                "optimizer_run_id": scope.optimizer_run_id,
                "optimizer_role": scope.optimizer_role,
                "effective_train_start_at": scope.effective_train_start_at,
                "effective_train_end_at": scope.effective_train_end_at,
                "prediction_start_at": scope.prediction_start_at,
                "prediction_end_at": scope.prediction_end_at,
            },
        )

    async def record_go_no_go(self, facts: CrossFitGateFacts) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_cross_fit_go_no_go(
                    :execution_id, :lease_token, :tpe_optimizer_run_id,
                    :random_optimizer_run_id, :tpe_mean, :random_mean,
                    :excess_mean, :p_value, :model_a_ci_lower_bound,
                    :model_a_ci_upper_bound, :model_b_net_expectancy,
                    :model_b_stressed_ci_lower_bound,
                    :model_b_stress_multiplier, :effective_day_count,
                    :effective_fold_count
                )
                """
            ),
            {
                "execution_id": facts.execution_id,
                "lease_token": facts.lease_token,
                "tpe_optimizer_run_id": facts.tpe_optimizer_run_id,
                "random_optimizer_run_id": facts.random_optimizer_run_id,
                "tpe_mean": facts.tpe_mean,
                "random_mean": facts.random_mean,
                "excess_mean": facts.excess_mean,
                "p_value": facts.p_value,
                "model_a_ci_lower_bound": facts.model_a_ci_lower_bound,
                "model_a_ci_upper_bound": facts.model_a_ci_upper_bound,
                "model_b_net_expectancy": facts.model_b_net_expectancy,
                "model_b_stressed_ci_lower_bound": (
                    facts.model_b_stressed_ci_lower_bound
                ),
                "model_b_stress_multiplier": facts.model_b_stress_multiplier,
                "effective_day_count": facts.effective_day_count,
                "effective_fold_count": facts.effective_fold_count,
            },
        )
        return cast(UUID, result.scalar_one())
