from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection


class ValidationBudgetError(ValueError):
    """A validation reservation would exceed its immutable shared budget."""


@dataclass(frozen=True, slots=True)
class ValidationReservation:
    scope_id: UUID
    reservation_id: UUID
    model_family: str
    evaluation_count: int
    alpha_reserved: Decimal


@dataclass(slots=True)
class ValidationBudgetLedger:
    """Small deterministic mirror of the database reservation contract for tests."""

    max_evaluation_count: int
    alpha_total: Decimal
    reserved_evaluation_count: int = 0
    reserved_alpha: Decimal = Decimal("0")

    def reserve(self, *, evaluation_count: int, alpha: Decimal) -> None:
        if evaluation_count != 1 or alpha <= 0 or alpha >= 1:
            raise ValidationBudgetError("one positive evaluation and alpha in (0, 1) required")
        if (
            self.reserved_evaluation_count + evaluation_count > self.max_evaluation_count
            or self.reserved_alpha + alpha > self.alpha_total
        ):
            raise ValidationBudgetError("validation global budget exhausted")
        self.reserved_evaluation_count += evaluation_count
        self.reserved_alpha += alpha


class DatabaseValidationScopeStore:
    """Calls the row-locking database procedure; no VALIDATION read occurs here."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def reserve(
        self,
        *,
        scope_id: UUID,
        final_candidate_freeze_id: UUID,
        model_family: str,
        alpha_reserved: Decimal,
        request_id: UUID,
        actor_user_id: UUID,
    ) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.reserve_training_validation_budget(
                    :scope_id, :freeze_id, :model_family, :alpha,
                    :request_id, :actor_user_id
                )
                """
            ),
            {
                "scope_id": scope_id,
                "freeze_id": final_candidate_freeze_id,
                "model_family": model_family,
                "alpha": alpha_reserved,
                "request_id": request_id,
                "actor_user_id": actor_user_id,
            },
        )
        return cast(UUID, result.scalar_one())
