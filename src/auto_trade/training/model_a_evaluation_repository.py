from __future__ import annotations

import json
from collections.abc import Mapping
from datetime import datetime
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.training.model_a_pipeline import (
    BaselineStratum,
    EntryOutcome,
    OutcomeBar,
    RandomBaselineSelection,
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


class DatabaseModelAEvaluationStore:
    """Use only evaluator procedures; training workers cannot read label tables."""

    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

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
