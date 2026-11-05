from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.contracts import Direction, Partition, PartitionKind
from auto_trade.training.model_a_pipeline import (
    BaselineCandidate,
    BaselineStratum,
    EntryOutcome,
    OutcomeBar,
    RandomBaselineSelection,
)


@dataclass(frozen=True, slots=True)
class EntryEvaluationContext:
    entry_event_id: str
    partition: Partition
    entry_time: datetime
    entry_price: Decimal
    direction: Direction
    label_window_end_at: datetime
    interval_seconds: int
    holding_rule_version_id: UUID
    opportunity_definition_version_id: UUID


@dataclass(frozen=True, slots=True)
class ExistingEntryEvidence:
    path_fingerprint: str
    is_complete: bool
    opportunity_recorded: bool
    random_baseline_recorded: bool
    random_baseline_excluded: bool = False


@dataclass(frozen=True, slots=True)
class RandomBaselineEvaluationContext:
    config_version_id: UUID
    sample_count: int
    minimum_frame_size: int
    exclusion_window_seconds: int
    random_seed: int
    target: BaselineStratum
    signal_times: tuple[datetime, ...]


@dataclass(frozen=True, slots=True)
class RandomCandidateOutcomeContext:
    candidate_id: str
    partition: Partition
    entry_time: datetime
    entry_price: Decimal
    direction: Direction
    label_window_end_at: datetime
    interval_seconds: int
    holding_rule_version_id: UUID


def _json_text(value: object) -> str:
    return json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
        allow_nan=False,
    )


class DatabaseModelAEvaluationStore:
    """Use only evaluator procedures; training workers cannot read label tables."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(
        self, task_id: UUID, lease_token: UUID, entry_event_id: str
    ) -> EntryEvaluationContext:
        result = await self._connection.execute(
            text(
                """
                SELECT partition, partition_start_at, partition_end_at,
                       entry_time, entry_price, direction,
                       label_window_end_at, interval_seconds,
                       holding_rule_version_id,
                       opportunity_definition_version_id
                FROM strategy_training.training_model_a_evaluation_context(
                    :task_id, :lease_token, :entry_event_id
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
            },
        )
        row = result.mappings().one()
        return EntryEvaluationContext(
            entry_event_id=entry_event_id,
            partition=Partition(
                PartitionKind(str(row["partition"])),
                cast(datetime, row["partition_start_at"]),
                cast(datetime, row["partition_end_at"]),
            ),
            entry_time=cast(datetime, row["entry_time"]),
            entry_price=Decimal(str(row["entry_price"])),
            direction=Direction(str(row["direction"])),
            label_window_end_at=cast(datetime, row["label_window_end_at"]),
            interval_seconds=int(row["interval_seconds"]),
            holding_rule_version_id=cast(UUID, row["holding_rule_version_id"]),
            opportunity_definition_version_id=cast(
                UUID, row["opportunity_definition_version_id"]
            ),
        )

    async def load_existing_evidence(
        self, entry_event_id: str
    ) -> ExistingEntryEvidence | None:
        result = await self._connection.execute(
            text(
                """
                SELECT outcome.path_fingerprint, outcome.is_complete,
                       opportunity.entry_event_id IS NOT NULL AS opportunity_recorded,
                       baseline.random_baseline_id IS NOT NULL AS random_baseline_recorded
                       , exclusion.entry_event_id IS NOT NULL AS random_baseline_excluded
                FROM strategy_training.training_entry_outcomes outcome
                LEFT JOIN strategy_training.training_opportunity_events opportunity
                  ON opportunity.entry_event_id = outcome.entry_event_id
                LEFT JOIN strategy_training.training_random_entry_baselines baseline
                  ON baseline.matched_entry_event_id = outcome.entry_event_id
                LEFT JOIN strategy_training.training_random_baseline_frame_exclusions exclusion
                  ON exclusion.entry_event_id = outcome.entry_event_id
                WHERE outcome.entry_event_id = :entry_event_id
                """
            ),
            {"entry_event_id": entry_event_id},
        )
        row = result.mappings().one_or_none()
        if row is None:
            return None
        return ExistingEntryEvidence(
            str(row["path_fingerprint"]),
            bool(row["is_complete"]),
            bool(row["opportunity_recorded"]),
            bool(row["random_baseline_recorded"]),
            bool(row["random_baseline_excluded"]),
        )

    async def load_random_baseline_context(
        self, task_id: UUID, lease_token: UUID, entry_event_id: str
    ) -> RandomBaselineEvaluationContext:
        result = await self._connection.execute(
            text(
                """
                SELECT random_baseline_config_version_id,
                       sample_count, minimum_frame_size,
                       exclusion_window_seconds, random_seed,
                       instrument_id, pool_identity, time_bucket,
                       volatility_bucket, liquidity_bucket, btc_regime,
                       signal_times
                FROM strategy_training.training_random_baseline_evaluation_context(
                    :task_id, :lease_token, :entry_event_id
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
            },
        )
        row = result.mappings().one()
        return RandomBaselineEvaluationContext(
            config_version_id=cast(UUID, row["random_baseline_config_version_id"]),
            sample_count=int(row["sample_count"]),
            minimum_frame_size=int(row["minimum_frame_size"]),
            exclusion_window_seconds=int(row["exclusion_window_seconds"]),
            random_seed=int(row["random_seed"]),
            target=BaselineStratum(
                instrument_id=int(row["instrument_id"]),
                pool_identity=str(row["pool_identity"]),
                time_bucket=str(row["time_bucket"]),
                volatility_bucket=str(row["volatility_bucket"]),
                liquidity_bucket=str(row["liquidity_bucket"]),
                btc_regime=str(row["btc_regime"]),
            ),
            signal_times=tuple(cast(list[datetime], row["signal_times"])),
        )

    async def load_random_baseline_candidates(
        self, task_id: UUID, lease_token: UUID, entry_event_id: str
    ) -> tuple[BaselineCandidate, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT candidate_id, observed_at, instrument_id,
                       pool_identity, time_bucket, volatility_bucket,
                       liquidity_bucket, btc_regime
                FROM strategy_training.training_random_baseline_candidate_frame(
                    :task_id, :lease_token, :entry_event_id
                )
                ORDER BY candidate_id
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
            },
        )
        return tuple(
            BaselineCandidate(
                candidate_id=str(row["candidate_id"]),
                observed_at=cast(datetime, row["observed_at"]),
                stratum=BaselineStratum(
                    instrument_id=int(str(row["instrument_id"])),
                    pool_identity=str(row["pool_identity"]),
                    time_bucket=str(row["time_bucket"]),
                    volatility_bucket=str(row["volatility_bucket"]),
                    liquidity_bucket=str(row["liquidity_bucket"]),
                    btc_regime=str(row["btc_regime"]),
                ),
            )
            for raw_row in result.mappings().all()
            for row in (cast(Mapping[str, object], raw_row),)
        )

    async def load_outcome_bars(self, entry_event_id: str) -> tuple[OutcomeBar, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT observed_at, high_price, low_price, close_price
                FROM strategy_training.training_entry_outcome_bars(:entry_event_id)
                ORDER BY observed_at
                """
            ),
            {"entry_event_id": entry_event_id},
        )
        return tuple(
            OutcomeBar(
                observed_at=cast(datetime, row["observed_at"]),
                high_price=Decimal(str(row["high_price"])),
                low_price=Decimal(str(row["low_price"])),
                close_price=Decimal(str(row["close_price"])),
            )
            for raw_row in result.mappings().all()
            for row in (cast(Mapping[str, object], raw_row),)
        )

    async def load_random_candidate_outcome_context(
        self,
        task_id: UUID,
        lease_token: UUID,
        entry_event_id: str,
        candidate_id: str,
    ) -> RandomCandidateOutcomeContext:
        result = await self._connection.execute(
            text(
                """
                SELECT partition, partition_start_at, partition_end_at,
                       entry_time, entry_price, direction,
                       label_window_end_at, interval_seconds,
                       holding_rule_version_id
                FROM strategy_training.training_random_candidate_outcome_context(
                    :task_id, :lease_token, :entry_event_id, :candidate_id
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
                "candidate_id": candidate_id,
            },
        )
        row = result.mappings().one()
        return RandomCandidateOutcomeContext(
            candidate_id=candidate_id,
            partition=Partition(
                PartitionKind(str(row["partition"])),
                cast(datetime, row["partition_start_at"]),
                cast(datetime, row["partition_end_at"]),
            ),
            entry_time=cast(datetime, row["entry_time"]),
            entry_price=Decimal(str(row["entry_price"])),
            direction=Direction(str(row["direction"])),
            label_window_end_at=cast(datetime, row["label_window_end_at"]),
            interval_seconds=int(row["interval_seconds"]),
            holding_rule_version_id=cast(UUID, row["holding_rule_version_id"]),
        )

    async def load_random_candidate_outcome_bars(
        self, task_id: UUID, lease_token: UUID, entry_event_id: str, candidate_id: str
    ) -> tuple[OutcomeBar, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT observed_at, high_price, low_price, close_price
                FROM strategy_training.training_random_candidate_outcome_bars(
                    :task_id, :lease_token, :entry_event_id, :candidate_id
                )
                ORDER BY observed_at
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
                "candidate_id": candidate_id,
            },
        )
        return tuple(
            OutcomeBar(
                observed_at=cast(datetime, row["observed_at"]),
                high_price=Decimal(str(row["high_price"])),
                low_price=Decimal(str(row["low_price"])),
                close_price=Decimal(str(row["close_price"])),
            )
            for row in result.mappings().all()
        )

    async def record_random_candidate_outcome(
        self,
        task_id: UUID,
        lease_token: UUID,
        matched_entry_event_id: str,
        outcome: EntryOutcome,
        holding_rule_version_id: UUID,
        interval_seconds: int,
    ) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_random_candidate_outcome(
                    :task_id, :lease_token, :matched_entry_event_id,
                    :candidate_id, :holding_rule_version_id,
                    :label_window_end_at, :interval_seconds,
                    :expected_bar_count, :observed_bar_count,
                    :missing_bar_count, :is_complete, :incomplete_reason,
                    :mfe_percent, :mae_percent, :return_percent,
                    :mfe_reached_at, :mae_reached_at,
                    :endpoint_observed_at, :path_fingerprint
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "matched_entry_event_id": matched_entry_event_id,
                "candidate_id": outcome.entry_event_id,
                "holding_rule_version_id": holding_rule_version_id,
                "label_window_end_at": outcome.label_window_end_at,
                "interval_seconds": interval_seconds,
                "expected_bar_count": outcome.expected_bar_count,
                "observed_bar_count": outcome.observed_bar_count,
                "missing_bar_count": outcome.missing_bar_count,
                "is_complete": outcome.is_complete,
                "incomplete_reason": outcome.incomplete_reason,
                "mfe_percent": outcome.mfe_percent,
                "mae_percent": outcome.mae_percent,
                "return_percent": outcome.return_percent,
                "mfe_reached_at": outcome.mfe_reached_at,
                "mae_reached_at": outcome.mae_reached_at,
                "endpoint_observed_at": outcome.endpoint_observed_at,
                "path_fingerprint": outcome.path_fingerprint,
            },
        )

    async def record_outcome(
        self, outcome: EntryOutcome, holding_rule_version_id: UUID, interval_seconds: int
    ) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_entry_outcome(
                    :entry_event_id, :holding_rule_version_id,
                    :label_window_end_at, :interval_seconds,
                    :expected_bar_count, :observed_bar_count,
                    :missing_bar_count, :is_complete, :incomplete_reason,
                    :mfe_percent, :mae_percent, :return_percent,
                    :mfe_reached_at, :mae_reached_at,
                    :endpoint_observed_at, :path_fingerprint
                )
                """
            ),
            {
                "entry_event_id": outcome.entry_event_id,
                "holding_rule_version_id": holding_rule_version_id,
                "label_window_end_at": outcome.label_window_end_at,
                "interval_seconds": interval_seconds,
                "expected_bar_count": outcome.expected_bar_count,
                "observed_bar_count": outcome.observed_bar_count,
                "missing_bar_count": outcome.missing_bar_count,
                "is_complete": outcome.is_complete,
                "incomplete_reason": outcome.incomplete_reason,
                "mfe_percent": outcome.mfe_percent,
                "mae_percent": outcome.mae_percent,
                "return_percent": outcome.return_percent,
                "mfe_reached_at": outcome.mfe_reached_at,
                "mae_reached_at": outcome.mae_reached_at,
                "endpoint_observed_at": outcome.endpoint_observed_at,
                "path_fingerprint": outcome.path_fingerprint,
            },
        )

    async def record_opportunity(
        self, entry_event_id: str, opportunity_definition_version_id: UUID
    ) -> None:
        await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_opportunity_event(
                    :entry_event_id, :config_version_id
                )
                """
            ),
            {
                "entry_event_id": entry_event_id,
                "config_version_id": opportunity_definition_version_id,
            },
        )

    async def record_random_baseline(
        self,
        selection: RandomBaselineSelection,
        config_version_id: UUID,
        stratum: BaselineStratum,
    ) -> UUID:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_random_baseline(
                    :entry_event_id, :config_version_id,
                    CAST(:matching_stratum AS jsonb),
                    CAST(:selected_candidate_ids AS jsonb),
                    :sampling_frame_size, :inclusion_probability,
                    :random_seed, :sampling_frame_hash,
                    :overlap_excluded_count
                )
                """
            ),
            {
                "entry_event_id": selection.matched_entry_event_id,
                "config_version_id": config_version_id,
                "matching_stratum": _json_text(
                    {
                        "btc_regime": stratum.btc_regime,
                        "instrument_id": stratum.instrument_id,
                        "liquidity_bucket": stratum.liquidity_bucket,
                        "pool_identity": stratum.pool_identity,
                        "time_bucket": stratum.time_bucket,
                        "volatility_bucket": stratum.volatility_bucket,
                    }
                ),
                "selected_candidate_ids": _json_text(selection.selected_candidate_ids),
                "sampling_frame_size": selection.sampling_frame_size,
                "inclusion_probability": selection.inclusion_probability,
                "random_seed": selection.random_seed,
                "sampling_frame_hash": selection.sampling_frame_hash,
                "overlap_excluded_count": selection.overlap_excluded_count,
            },
        )
        return cast(UUID, result.scalar_one())

    async def record_random_baseline_exclusion(
        self, task_id: UUID, lease_token: UUID, entry_event_id: str
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.record_training_random_baseline_frame_exclusion(
                    :task_id, :lease_token, :entry_event_id
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "entry_event_id": entry_event_id,
            },
        )
        return str(result.scalar_one())

    async def finalize_random_baseline_coverage(
        self, task_id: UUID, lease_token: UUID
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.finalize_training_random_baseline_coverage(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return str(result.scalar_one())
