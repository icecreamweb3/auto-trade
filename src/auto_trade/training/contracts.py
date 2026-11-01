from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from types import MappingProxyType
from uuid import UUID


class TrainingContractError(ValueError):
    """Base error for a rejected training-domain operation."""


class InvalidTimeBoundaryError(TrainingContractError):
    """A timestamp or duration violates the UTC partition contract."""


class InvalidStateTransitionError(TrainingContractError):
    """A lifecycle state transition is not allowed."""


class EntrySourceNotAllowedError(TrainingContractError):
    """An entry-event source cannot be used in the requested workflow."""


class PartitionKind(StrEnum):
    TRAIN = "TRAIN"
    VALIDATION = "VALIDATION"
    WEAK_HOLDOUT = "WEAK_HOLDOUT"
    TEST = "TEST"


class DatasetStatus(StrEnum):
    BUILDING = "BUILDING"
    READY = "READY"
    STALE = "STALE"
    SUPERSEDED = "SUPERSEDED"
    INVALID = "INVALID"
    ARCHIVED = "ARCHIVED"


class ExperimentStatus(StrEnum):
    DRAFT = "DRAFT"
    RUNNING = "RUNNING"
    PAUSED = "PAUSED"
    STOPPED = "STOPPED"


class IterationStatus(StrEnum):
    CREATED = "CREATED"
    VALIDATING = "VALIDATING"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    REJECTED = "REJECTED"
    CANCELLED = "CANCELLED"


class ModelStatus(StrEnum):
    DRAFT = "DRAFT"
    LOCKED = "LOCKED"
    SHADOW = "SHADOW"
    RETIRED = "RETIRED"


class TestStatus(StrEnum):
    DRAFT = "DRAFT"
    SEALED = "SEALED"
    CONSUMED = "CONSUMED"
    COMPROMISED = "COMPROMISED"


class EntrySource(StrEnum):
    MODEL_A_SIGNAL = "MODEL_A_SIGNAL"
    LOCKED_MODEL_A_VALIDATION_SIGNAL = "LOCKED_MODEL_A_VALIDATION_SIGNAL"
    CROSS_FIT_MODEL_A_CANDIDATE = "CROSS_FIT_MODEL_A_CANDIDATE"
    CROSS_FIT_MODEL_A = "CROSS_FIT_MODEL_A"
    FIXED_BASELINE_MODEL_A = "FIXED_BASELINE_MODEL_A"
    ORACLE_ENTRY_BENCHMARK = "ORACLE_ENTRY_BENCHMARK"
    ADVERSE_OR_RANGE_CONTROL = "ADVERSE_OR_RANGE_CONTROL"
    IN_SAMPLE_MODEL_A = "IN_SAMPLE_MODEL_A"


class EntryUse(StrEnum):
    MODEL_B_PROTOTYPE = "MODEL_B_PROTOTYPE"
    GO_NO_GO = "GO_NO_GO"
    MODEL_B_TRAIN = "MODEL_B_TRAIN"
    VALIDATION = "VALIDATION"
    END_TO_END_TEST = "END_TO_END_TEST"
    ORACLE_BENCHMARK = "ORACLE_BENCHMARK"


class RejectionCode(StrEnum):
    INVALID_TIME_RANGE = "INVALID_TIME_RANGE"
    LABEL_OUTSIDE_PARTITION = "LABEL_OUTSIDE_PARTITION"
    CONFIG_NOT_READY = "CONFIG_NOT_READY"
    DATASET_NOT_READY = "DATASET_NOT_READY"
    DATA_DEPENDENCY_UNAVAILABLE = "DATA_DEPENDENCY_UNAVAILABLE"
    SOURCE_NOT_ALLOWED = "SOURCE_NOT_ALLOWED"
    INVALID_STATE_TRANSITION = "INVALID_STATE_TRANSITION"
    RESOURCE_BUDGET_EXCEEDED = "RESOURCE_BUDGET_EXCEEDED"
    VALIDATION_BUDGET_EXCEEDED = "VALIDATION_BUDGET_EXCEEDED"
    INSUFFICIENT_POWER = "INSUFFICIENT_POWER"
    TEST_ALREADY_CONSUMED = "TEST_ALREADY_CONSUMED"


class Direction(StrEnum):
    LONG = "LONG"
    SHORT = "SHORT"


def _require_utc(value: datetime, *, field_name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise InvalidTimeBoundaryError(f"{field_name} must be timezone-aware UTC")
    return value.astimezone(UTC)


def _canonical_timestamp(value: datetime, *, field_name: str) -> str:
    normalized = _require_utc(value, field_name=field_name)
    return normalized.isoformat(timespec="microseconds").replace("+00:00", "Z")


def _positive_duration(value: timedelta, *, field_name: str) -> timedelta:
    if value <= timedelta(0):
        raise InvalidTimeBoundaryError(f"{field_name} must be greater than zero")
    return value


@dataclass(frozen=True, slots=True)
class Partition:
    kind: PartitionKind
    start_at: datetime
    end_at: datetime

    def __post_init__(self) -> None:
        start_at = _require_utc(self.start_at, field_name="start_at")
        end_at = _require_utc(self.end_at, field_name="end_at")
        if start_at >= end_at:
            raise InvalidTimeBoundaryError("partition start_at must be before end_at")
        object.__setattr__(self, "start_at", start_at)
        object.__setattr__(self, "end_at", end_at)

    def contains(self, value: datetime) -> bool:
        timestamp = _require_utc(value, field_name="value")
        return self.start_at <= timestamp < self.end_at

    def effective_entry_end(
        self,
        *,
        label_horizon: timedelta,
        max_holding_horizon: timedelta,
    ) -> datetime:
        label_horizon = _positive_duration(label_horizon, field_name="label_horizon")
        max_holding_horizon = _positive_duration(
            max_holding_horizon,
            field_name="max_holding_horizon",
        )
        entry_end = self.end_at - max(label_horizon, max_holding_horizon)
        if entry_end <= self.start_at:
            raise InvalidTimeBoundaryError("partition has no eligible entry window")
        return entry_end

    def assert_label_window(self, *, signal_time: datetime, label_window_end: datetime) -> None:
        signal_time = _require_utc(signal_time, field_name="signal_time")
        label_window_end = _require_utc(label_window_end, field_name="label_window_end")
        if not self.contains(signal_time):
            raise InvalidTimeBoundaryError("signal_time is outside the partition")
        if label_window_end <= signal_time:
            raise InvalidTimeBoundaryError("label_window_end must be after signal_time")
        if label_window_end > self.end_at:
            raise InvalidTimeBoundaryError("label_window_end exceeds partition_end")


@dataclass(frozen=True, slots=True)
class EntryEventIdentity:
    dataset_version_id: UUID
    generating_version_id: UUID
    symbol: str
    signal_time: datetime
    entry_time: datetime
    direction: Direction

    def __post_init__(self) -> None:
        symbol = self.symbol.strip().upper()
        if not symbol:
            raise TrainingContractError("symbol must not be empty")
        signal_time = _require_utc(self.signal_time, field_name="signal_time")
        entry_time = _require_utc(self.entry_time, field_name="entry_time")
        if entry_time <= signal_time:
            raise InvalidTimeBoundaryError("entry_time must be after signal_time")
        object.__setattr__(self, "symbol", symbol)
        object.__setattr__(self, "signal_time", signal_time)
        object.__setattr__(self, "entry_time", entry_time)


def _sha256_json(payload: dict[str, str]) -> str:
    canonical = json.dumps(payload, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def build_entry_event_id(identity: EntryEventIdentity) -> str:
    """Build the deterministic fingerprint specified by the entry-event contract."""

    return _sha256_json(
        {
            "dataset_version_id": str(identity.dataset_version_id),
            "direction": identity.direction.value,
            "entry_time": _canonical_timestamp(identity.entry_time, field_name="entry_time"),
            "generating_version_id": str(identity.generating_version_id),
            "signal_time": _canonical_timestamp(identity.signal_time, field_name="signal_time"),
            "symbol": identity.symbol,
        }
    )


def build_test_scope_hash(
    *,
    start_at: datetime,
    end_at: datetime,
    ticker_pool_rule_version: str,
    controlled_purpose: str,
) -> str:
    """Hash only the stable TEST logical identity fields, never content/code versions."""

    start = _require_utc(start_at, field_name="start_at")
    end = _require_utc(end_at, field_name="end_at")
    if start >= end:
        raise InvalidTimeBoundaryError("TEST scope start_at must be before end_at")
    ticker_rule = ticker_pool_rule_version.strip()
    purpose = controlled_purpose.strip()
    if not ticker_rule or not purpose:
        raise TrainingContractError("TEST scope rule version and purpose are required")
    return _sha256_json(
        {
            "controlled_purpose": purpose,
            "end_at": _canonical_timestamp(end, field_name="end_at"),
            "start_at": _canonical_timestamp(start, field_name="start_at"),
            "ticker_pool_rule_version": ticker_rule,
        }
    )


_ENTRY_SOURCE_ALLOWLIST = MappingProxyType(
    {
        EntryUse.MODEL_B_PROTOTYPE: frozenset({EntrySource.FIXED_BASELINE_MODEL_A}),
        EntryUse.GO_NO_GO: frozenset({EntrySource.CROSS_FIT_MODEL_A_CANDIDATE}),
        EntryUse.MODEL_B_TRAIN: frozenset(
            {EntrySource.CROSS_FIT_MODEL_A, EntrySource.ADVERSE_OR_RANGE_CONTROL}
        ),
        EntryUse.VALIDATION: frozenset({EntrySource.LOCKED_MODEL_A_VALIDATION_SIGNAL}),
        EntryUse.END_TO_END_TEST: frozenset({EntrySource.MODEL_A_SIGNAL}),
        EntryUse.ORACLE_BENCHMARK: frozenset({EntrySource.ORACLE_ENTRY_BENCHMARK}),
    }
)


def assert_entry_source_allowed(*, source: EntrySource, usage: EntryUse) -> None:
    if source not in _ENTRY_SOURCE_ALLOWLIST[usage]:
        raise EntrySourceNotAllowedError(f"{source.value} is not allowed for {usage.value}")


_STATE_TRANSITIONS = MappingProxyType(
    {
        DatasetStatus: {
            DatasetStatus.BUILDING: frozenset({DatasetStatus.READY, DatasetStatus.INVALID}),
            DatasetStatus.READY: frozenset({DatasetStatus.STALE}),
            DatasetStatus.STALE: frozenset(
                {DatasetStatus.SUPERSEDED, DatasetStatus.ARCHIVED}
            ),
            DatasetStatus.SUPERSEDED: frozenset({DatasetStatus.ARCHIVED}),
            DatasetStatus.INVALID: frozenset({DatasetStatus.ARCHIVED}),
            DatasetStatus.ARCHIVED: frozenset(),
        },
        ExperimentStatus: {
            ExperimentStatus.DRAFT: frozenset({ExperimentStatus.RUNNING}),
            ExperimentStatus.RUNNING: frozenset(
                {ExperimentStatus.PAUSED, ExperimentStatus.STOPPED}
            ),
            ExperimentStatus.PAUSED: frozenset(
                {ExperimentStatus.RUNNING, ExperimentStatus.STOPPED}
            ),
            ExperimentStatus.STOPPED: frozenset(),
        },
        IterationStatus: {
            IterationStatus.CREATED: frozenset(
                {IterationStatus.VALIDATING, IterationStatus.CANCELLED}
            ),
            IterationStatus.VALIDATING: frozenset(
                {
                    IterationStatus.RUNNING,
                    IterationStatus.REJECTED,
                    IterationStatus.FAILED,
                    IterationStatus.CANCELLED,
                }
            ),
            IterationStatus.RUNNING: frozenset(
                {
                    IterationStatus.SUCCEEDED,
                    IterationStatus.FAILED,
                    IterationStatus.CANCELLED,
                }
            ),
            IterationStatus.SUCCEEDED: frozenset(),
            IterationStatus.FAILED: frozenset(),
            IterationStatus.REJECTED: frozenset(),
            IterationStatus.CANCELLED: frozenset(),
        },
        ModelStatus: {
            ModelStatus.DRAFT: frozenset({ModelStatus.LOCKED}),
            ModelStatus.LOCKED: frozenset({ModelStatus.SHADOW, ModelStatus.RETIRED}),
            ModelStatus.SHADOW: frozenset({ModelStatus.RETIRED}),
            ModelStatus.RETIRED: frozenset(),
        },
        TestStatus: {
            TestStatus.DRAFT: frozenset({TestStatus.SEALED, TestStatus.COMPROMISED}),
            TestStatus.SEALED: frozenset({TestStatus.CONSUMED, TestStatus.COMPROMISED}),
            TestStatus.CONSUMED: frozenset(),
            TestStatus.COMPROMISED: frozenset(),
        },
    }
)


type TrainingState = (
    DatasetStatus | ExperimentStatus | IterationStatus | ModelStatus | TestStatus
)


def assert_transition(current: TrainingState, target: TrainingState) -> None:
    if type(current) is not type(target):
        raise InvalidStateTransitionError("state types must match")
    transitions = _STATE_TRANSITIONS[type(current)]
    allowed = transitions[current]  # type: ignore[index]
    if target not in allowed:
        raise InvalidStateTransitionError(
            f"transition from {current.value} to {target.value} is not allowed"
        )
