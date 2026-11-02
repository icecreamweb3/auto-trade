from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from uuid import UUID


class WeakHoldoutError(ValueError):
    """Weak holdout is diagnostic only and cannot promote a candidate."""


class WeakHoldoutState(StrEnum):
    DRAFT = "DRAFT"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"


@dataclass(frozen=True, slots=True)
class WeakHoldoutRequest:
    model_a_version_id: UUID
    model_b_version_id: UUID
    requested_by_user_id: UUID
    exposure_status: str = "DECLARED"

    def __post_init__(self) -> None:
        if self.exposure_status != "DECLARED":
            raise WeakHoldoutError("weak holdout must retain DECLARED exposure status")


@dataclass(frozen=True, slots=True)
class WeakHoldoutResult:
    run_id: UUID
    state: WeakHoldoutState
    can_promote: bool = False

    def __post_init__(self) -> None:
        if self.can_promote:
            raise WeakHoldoutError("weak holdout results cannot promote a model")

