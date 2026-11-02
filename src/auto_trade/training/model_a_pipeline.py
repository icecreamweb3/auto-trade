from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID

from auto_trade.strategies.feature_scan import FactorResult, StrategySignal
from auto_trade.training.contracts import (
    Direction,
    EntryEventIdentity,
    EntrySource,
    Partition,
    TrainingContractError,
    build_entry_event_id,
)


class ModelAPipelineError(TrainingContractError):
    """A model-A fact cannot be produced without violating its contract."""


def _utc(value: datetime, field_name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise ModelAPipelineError(f"{field_name} must be timezone-aware UTC")
    return value.astimezone(UTC)


def _positive(value: Decimal, field_name: str) -> Decimal:
    if not value.is_finite() or value <= 0:
        raise ModelAPipelineError(f"{field_name} must be positive")
    return value


def _sha256(payload: object) -> str:
    serialized = json.dumps(
        payload,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
        allow_nan=False,
    )
    return hashlib.sha256(serialized.encode()).hexdigest()


def _require_sha(value: str, field_name: str) -> str:
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise ModelAPipelineError(f"{field_name} must be a lowercase SHA-256")
    return value


@dataclass(frozen=True, slots=True)
class FactorSnapshot:
    entry_event_id: str
    factor_name: str
    passed: bool
    available: bool
    value: Decimal | int | None
    threshold: str
    reason: str | None
    metrics: dict[str, Decimal | int | bool]
    score: Decimal
    weight: Decimal
    contribution: Decimal
    input_fingerprint: str

    @classmethod
    def from_result(
        cls,
        *,
        entry_event_id: str,
        factor_name: str,
        result: FactorResult,
        input_fingerprint: str,
    ) -> FactorSnapshot:
        if not factor_name.strip() or not result.threshold.strip():
            raise ModelAPipelineError("factor name and threshold must not be blank")
        if not result.available and result.value is not None:
            raise ModelAPipelineError("an unavailable factor cannot expose a measured value")
        return cls(
            entry_event_id=_require_sha(entry_event_id, "entry_event_id"),
            factor_name=factor_name,
            passed=result.passed,
            available=result.available,
            value=result.value,
            threshold=result.threshold,
            reason=result.reason,
            metrics=dict(result.metrics),
            score=result.score,
            weight=result.weight,
            contribution=result.contribution,
            input_fingerprint=_require_sha(input_fingerprint, "input_fingerprint"),
        )


@dataclass(frozen=True, slots=True)
class ModelAEntryEvent:
    entry_event_id: str
    dataset_version_id: UUID
    generating_version_id: UUID
    instrument_id: int
    symbol: str
    source: EntrySource
    signal_time: datetime
    entry_time: datetime
    direction: Direction
    trigger_score: Decimal
    coverage_percent: Decimal
    theoretical_signal_price: Decimal
    entry_price: Decimal
    pool_evaluation_id: UUID
    ticker_pool_rule_version_id: UUID
    factor_registry_version_id: UUID
    scan_parameters_version_id: UUID
    signal_payload_hash: str


@dataclass(frozen=True, slots=True)
class AdaptedModelASignal:
    event: ModelAEntryEvent
    factors: tuple[FactorSnapshot, ...]


def adapt_fixed_baseline_signal(
    signal: StrategySignal,
    *,
    dataset_version_id: UUID,
    generating_version_id: UUID,
    instrument_id: int,
    interval_seconds: int,
    pool_evaluation_id: UUID,
    ticker_pool_rule_version_id: UUID,
    factor_registry_version_id: UUID,
    scan_parameters_version_id: UUID,
    input_fingerprint: str,
    entry_price: Decimal,
) -> AdaptedModelASignal:
    if instrument_id <= 0:
        raise ModelAPipelineError("instrument_id must be positive")
    if interval_seconds <= 0 or interval_seconds % 60:
        raise ModelAPipelineError("interval_seconds must be a positive whole minute")
    if not signal.factors:
        raise ModelAPipelineError("an emitted signal requires factor diagnostics")
    signal_time = _utc(signal.open_time, "signal.open_time")
    entry_time = signal_time + timedelta(seconds=interval_seconds)
    identity = EntryEventIdentity(
        dataset_version_id=dataset_version_id,
        generating_version_id=generating_version_id,
        symbol=signal.symbol,
        signal_time=signal_time,
        entry_time=entry_time,
        direction=Direction.LONG,
    )
    entry_event_id = build_entry_event_id(identity)
    payload_hash = _sha256(
        {
            "coverage_percent": signal.coverage_percent,
            "entry_event_id": entry_event_id,
            "entry_price": entry_price,
            "grade": signal.grade,
            "group_scores": signal.group_scores,
            "risk_flags": signal.risk_flags,
            "trigger_reason": signal.trigger_reason,
            "trigger_score": signal.score,
        }
    )
    event = ModelAEntryEvent(
        entry_event_id=entry_event_id,
        dataset_version_id=dataset_version_id,
        generating_version_id=generating_version_id,
        instrument_id=instrument_id,
        symbol=identity.symbol,
        source=EntrySource.FIXED_BASELINE_MODEL_A,
        signal_time=signal_time,
        entry_time=entry_time,
        direction=Direction.LONG,
        trigger_score=signal.score,
        coverage_percent=signal.coverage_percent,
        theoretical_signal_price=_positive(signal.close_price, "theoretical_signal_price"),
        entry_price=_positive(entry_price, "entry_price"),
        pool_evaluation_id=pool_evaluation_id,
        ticker_pool_rule_version_id=ticker_pool_rule_version_id,
        factor_registry_version_id=factor_registry_version_id,
        scan_parameters_version_id=scan_parameters_version_id,
        signal_payload_hash=payload_hash,
    )
    factors = tuple(
        FactorSnapshot.from_result(
            entry_event_id=entry_event_id,
            factor_name=name,
            result=result,
            input_fingerprint=input_fingerprint,
        )
        for name, result in sorted(signal.factors.items())
    )
    return AdaptedModelASignal(event, factors)


@dataclass(frozen=True, slots=True)
class OutcomeBar:
    observed_at: datetime
    high_price: Decimal
    low_price: Decimal
    close_price: Decimal

    def __post_init__(self) -> None:
        object.__setattr__(self, "observed_at", _utc(self.observed_at, "observed_at"))
        for field_name in ("high_price", "low_price", "close_price"):
            _positive(getattr(self, field_name), field_name)
        if self.low_price > self.high_price:
            raise ModelAPipelineError("low_price cannot exceed high_price")


@dataclass(frozen=True, slots=True)
class EntryOutcome:
    entry_event_id: str
    label_window_end_at: datetime
    expected_bar_count: int
    observed_bar_count: int
    missing_bar_count: int
    is_complete: bool
    incomplete_reason: str | None
    mfe_percent: Decimal | None
    mae_percent: Decimal | None
    return_percent: Decimal | None
    mfe_reached_at: datetime | None
    mae_reached_at: datetime | None
    endpoint_observed_at: datetime | None
    path_fingerprint: str


def calculate_entry_outcome(
    *,
    entry_event_id: str,
    partition: Partition,
    entry_time: datetime,
    entry_price: Decimal,
    direction: Direction,
    label_window_end_at: datetime,
    interval_seconds: int,
    bars: tuple[OutcomeBar, ...],
) -> EntryOutcome:
    entry_event_id = _require_sha(entry_event_id, "entry_event_id")
    entry_time = _utc(entry_time, "entry_time")
    label_window_end_at = _utc(label_window_end_at, "label_window_end_at")
    _positive(entry_price, "entry_price")
    if interval_seconds <= 0 or interval_seconds % 60:
        raise ModelAPipelineError("interval_seconds must be a positive whole minute")
    partition.assert_label_window(
        signal_time=entry_time,
        label_window_end=label_window_end_at,
    )
    duration_seconds = int((label_window_end_at - entry_time).total_seconds())
    if duration_seconds % interval_seconds:
        raise ModelAPipelineError("label window must align to interval_seconds")
    expected_count = duration_seconds // interval_seconds
    expected_times = tuple(
        entry_time + timedelta(seconds=interval_seconds * index)
        for index in range(1, expected_count + 1)
    )
    observed_times = tuple(bar.observed_at for bar in bars)
    if observed_times != tuple(sorted(set(observed_times))):
        raise ModelAPipelineError("outcome bars must be unique and sorted")
    if any(time <= entry_time or time > label_window_end_at for time in observed_times):
        raise ModelAPipelineError("outcome bar is outside the label window")
    missing_count = len(set(expected_times) - set(observed_times))
    complete = observed_times == expected_times
    path_fingerprint = _sha256(
        [
            {
                "close": bar.close_price,
                "high": bar.high_price,
                "low": bar.low_price,
                "observed_at": bar.observed_at.isoformat(),
            }
            for bar in bars
        ]
    )
    if not complete:
        reason = "ENDPOINT_MISSING" if label_window_end_at not in observed_times else "MISSING_BARS"
        return EntryOutcome(
            entry_event_id,
            label_window_end_at,
            expected_count,
            len(bars),
            missing_count,
            False,
            reason,
            None,
            None,
            None,
            None,
            None,
            observed_times[-1] if observed_times else None,
            path_fingerprint,
        )

    if direction is Direction.LONG:
        favorable = tuple((bar.high_price / entry_price - 1) * 100 for bar in bars)
        adverse = tuple((1 - bar.low_price / entry_price) * 100 for bar in bars)
        final_return = (bars[-1].close_price / entry_price - 1) * 100
    else:
        favorable = tuple((1 - bar.low_price / entry_price) * 100 for bar in bars)
        adverse = tuple((bar.high_price / entry_price - 1) * 100 for bar in bars)
        final_return = (1 - bars[-1].close_price / entry_price) * 100
    mfe = max((Decimal(0), *favorable))
    mae = max((Decimal(0), *adverse))
    mfe_reached_at = entry_time if mfe == 0 else bars[favorable.index(mfe)].observed_at
    mae_reached_at = entry_time if mae == 0 else bars[adverse.index(mae)].observed_at
    return EntryOutcome(
        entry_event_id,
        label_window_end_at,
        expected_count,
        len(bars),
        0,
        True,
        None,
        mfe,
        mae,
        final_return,
        mfe_reached_at,
        mae_reached_at,
        bars[-1].observed_at,
        path_fingerprint,
    )


@dataclass(frozen=True, slots=True)
class OpportunityRule:
    version_id: UUID
    minimum_mfe_percent: Decimal
    maximum_mae_percent: Decimal
    minimum_return_percent: Decimal

    def __post_init__(self) -> None:
        _positive(self.minimum_mfe_percent, "minimum_mfe_percent")
        if self.maximum_mae_percent < 0 or not self.maximum_mae_percent.is_finite():
            raise ModelAPipelineError("maximum_mae_percent must be finite and non-negative")
        if not self.minimum_return_percent.is_finite():
            raise ModelAPipelineError("minimum_return_percent must be finite")


@dataclass(frozen=True, slots=True)
class OpportunityEvent:
    entry_event_id: str
    opportunity_rule_version_id: UUID
    is_opportunity: bool
    reason_codes: tuple[str, ...]
    truth_fingerprint: str


def classify_opportunity(outcome: EntryOutcome, rule: OpportunityRule) -> OpportunityEvent:
    if not outcome.is_complete:
        raise ModelAPipelineError("incomplete outcome cannot become opportunity truth")
    assert outcome.mfe_percent is not None
    assert outcome.mae_percent is not None
    assert outcome.return_percent is not None
    reasons: list[str] = []
    if outcome.mfe_percent < rule.minimum_mfe_percent:
        reasons.append("MFE_BELOW_THRESHOLD")
    if outcome.mae_percent > rule.maximum_mae_percent:
        reasons.append("MAE_ABOVE_THRESHOLD")
    if outcome.return_percent < rule.minimum_return_percent:
        reasons.append("RETURN_BELOW_THRESHOLD")
    truth_fingerprint = _sha256(
        {
            "entry_event_id": outcome.entry_event_id,
            "is_opportunity": not reasons,
            "opportunity_rule_version_id": str(rule.version_id),
            "path_fingerprint": outcome.path_fingerprint,
            "reason_codes": reasons,
        }
    )
    return OpportunityEvent(
        outcome.entry_event_id,
        rule.version_id,
        not reasons,
        tuple(reasons),
        truth_fingerprint,
    )


@dataclass(frozen=True, slots=True)
class BaselineStratum:
    instrument_id: int
    pool_identity: str
    time_bucket: str
    volatility_bucket: str
    liquidity_bucket: str
    btc_regime: str


@dataclass(frozen=True, slots=True)
class BaselineCandidate:
    candidate_id: str
    observed_at: datetime
    stratum: BaselineStratum

    def __post_init__(self) -> None:
        if not self.candidate_id.strip():
            raise ModelAPipelineError("candidate_id must not be blank")
        object.__setattr__(self, "observed_at", _utc(self.observed_at, "observed_at"))


@dataclass(frozen=True, slots=True)
class RandomBaselineSelection:
    matched_entry_event_id: str
    selected_candidate_ids: tuple[str, ...]
    sampling_frame_size: int
    inclusion_probability: Decimal
    random_seed: int
    sampling_frame_hash: str
    overlap_excluded_count: int


def select_matched_random_baseline(
    *,
    matched_entry_event_id: str,
    target: BaselineStratum,
    candidates: tuple[BaselineCandidate, ...],
    signal_times_by_instrument: dict[int, tuple[datetime, ...]],
    exclusion_window: timedelta,
    sample_count: int,
    minimum_frame_size: int,
    random_seed: int,
) -> RandomBaselineSelection:
    matched_entry_event_id = _require_sha(matched_entry_event_id, "matched_entry_event_id")
    if exclusion_window < timedelta(0):
        raise ModelAPipelineError("exclusion_window cannot be negative")
    if sample_count <= 0 or minimum_frame_size <= 0:
        raise ModelAPipelineError("sample_count and minimum_frame_size must be positive")
    identities = [candidate.candidate_id for candidate in candidates]
    if len(identities) != len(set(identities)):
        raise ModelAPipelineError("baseline candidate IDs must be unique")
    matched = tuple(candidate for candidate in candidates if candidate.stratum == target)
    eligible: list[BaselineCandidate] = []
    overlap_count = 0
    for candidate in matched:
        signal_times = signal_times_by_instrument.get(candidate.stratum.instrument_id, ())
        if any(
            abs(candidate.observed_at - signal_time) <= exclusion_window
            for signal_time in signal_times
        ):
            overlap_count += 1
        else:
            eligible.append(candidate)
    if len(eligible) < minimum_frame_size:
        raise ModelAPipelineError("matched random baseline frame is below configured minimum")
    ordered_frame = tuple(sorted(eligible, key=lambda candidate: candidate.candidate_id))
    frame_hash = _sha256(
        [
            {
                "candidate_id": candidate.candidate_id,
                "observed_at": candidate.observed_at.isoformat(),
            }
            for candidate in ordered_frame
        ]
    )
    ranked = sorted(
        ordered_frame,
        key=lambda candidate: (
            hashlib.sha256(
                f"{random_seed}:{matched_entry_event_id}:{candidate.candidate_id}".encode()
            ).hexdigest(),
            candidate.candidate_id,
        ),
    )
    selected_count = min(sample_count, len(ranked))
    selected = tuple(candidate.candidate_id for candidate in ranked[:selected_count])
    probability = Decimal(selected_count) / Decimal(len(ranked))
    return RandomBaselineSelection(
        matched_entry_event_id,
        selected,
        len(ranked),
        probability,
        random_seed,
        frame_hash,
        overlap_count,
    )
