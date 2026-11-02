from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID

from auto_trade.training.contracts import EntrySource, Partition, TrainingContractError


class CrossFitContractError(TrainingContractError):
    """A Cross-fit fold would violate the no-look-ahead contract."""


def _utc(value: datetime, name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise CrossFitContractError(f"{name} must be timezone-aware UTC")
    return value.astimezone(UTC)


@dataclass(frozen=True, slots=True)
class CrossFitFold:
    fold_number: int
    raw_train_start_at: datetime
    raw_train_end_at: datetime
    effective_train_start_at: datetime
    effective_train_end_at: datetime
    prediction_start_at: datetime
    prediction_end_at: datetime
    warmup_start_at: datetime
    purge_start_at: datetime
    purge_end_at: datetime
    embargo_start_at: datetime
    embargo_end_at: datetime
    excluded_count: int
    model_version_id: UUID
    random_seed: int
    inner_validation_count: int = 0

    def __post_init__(self) -> None:
        for name in (
            "raw_train_start_at", "raw_train_end_at", "effective_train_start_at",
            "effective_train_end_at", "prediction_start_at", "prediction_end_at",
            "warmup_start_at", "purge_start_at", "purge_end_at",
            "embargo_start_at", "embargo_end_at",
        ):
            object.__setattr__(self, name, _utc(getattr(self, name), name))
        if self.fold_number <= 0 or self.excluded_count < 0 or self.inner_validation_count != 0:
            raise CrossFitContractError("invalid fold counters")
        if not (
            self.raw_train_start_at < self.raw_train_end_at
            and self.effective_train_start_at < self.effective_train_end_at
            and self.prediction_start_at < self.prediction_end_at
            and self.raw_train_start_at <= self.effective_train_start_at
            and self.effective_train_end_at <= self.purge_start_at
            and self.purge_start_at <= self.purge_end_at <= self.embargo_start_at
            and self.embargo_start_at <= self.embargo_end_at <= self.prediction_start_at
        ):
            raise CrossFitContractError("fold windows overlap or are out of order")

    @property
    def source(self) -> EntrySource:
        return EntrySource.CROSS_FIT_MODEL_A_CANDIDATE

    @property
    def fold_hash(self) -> str:
        payload = {
            "fold_number": self.fold_number,
            "raw_train_start": self.raw_train_start_at.isoformat(),
            "raw_train_end": self.raw_train_end_at.isoformat(),
            "effective_train_start": self.effective_train_start_at.isoformat(),
            "effective_train_end": self.effective_train_end_at.isoformat(),
            "prediction_start": self.prediction_start_at.isoformat(),
            "prediction_end": self.prediction_end_at.isoformat(),
            "model_version_id": str(self.model_version_id),
            "random_seed": self.random_seed,
        }
        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()


def plan_cross_fit_folds(
    *,
    train_partition: Partition,
    fold_count: int,
    train_window: timedelta,
    prediction_window: timedelta,
    purge: timedelta,
    embargo: timedelta,
    warmup: timedelta,
    model_version_id: UUID,
    random_seed: int,
) -> tuple[CrossFitFold, ...]:
    """Create deterministic forward folds; no fold has an inner VALIDATION window."""
    if train_partition.kind.value != "TRAIN":
        raise CrossFitContractError("Cross-fit requires a TRAIN partition")
    if fold_count <= 0:
        raise CrossFitContractError("fold_count must be positive")
    durations = (train_window, prediction_window, purge, embargo, warmup)
    if any(duration <= timedelta(0) for duration in durations):
        raise CrossFitContractError("fold durations must be positive")
    total = train_window + purge + embargo + prediction_window
    available = train_partition.end_at - train_partition.start_at
    if available < warmup + total + (fold_count - 1) * prediction_window:
        raise CrossFitContractError("TRAIN partition is too short for requested Cross-fit folds")

    folds: list[CrossFitFold] = []
    first_prediction = train_partition.start_at + warmup + train_window + purge + embargo
    for index in range(fold_count):
        prediction_start = first_prediction + index * prediction_window
        prediction_end = prediction_start + prediction_window
        raw_train_end = prediction_start - embargo - purge
        raw_train_start = raw_train_end - train_window
        effective_train_start = raw_train_start + warmup
        folds.append(
            CrossFitFold(
                fold_number=index + 1,
                raw_train_start_at=raw_train_start,
                raw_train_end_at=raw_train_end,
                effective_train_start_at=effective_train_start,
                effective_train_end_at=raw_train_end,
                prediction_start_at=prediction_start,
                prediction_end_at=prediction_end,
                warmup_start_at=raw_train_start,
                purge_start_at=raw_train_end,
                purge_end_at=prediction_start - embargo,
                embargo_start_at=prediction_start - embargo,
                embargo_end_at=prediction_start,
                excluded_count=0,
                model_version_id=model_version_id,
                random_seed=random_seed + index,
            )
        )
    return tuple(folds)
