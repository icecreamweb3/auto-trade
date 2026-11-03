from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import cast
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from auto_trade.strategies.feature_scan import FeatureBar


@dataclass(frozen=True, slots=True)
class CandidateScanContext:
    iteration_id: UUID
    dataset_version_id: UUID
    interval_seconds: int
    eligible_start_at: datetime
    eligible_end_at: datetime
    ticker_pool_rule_version_id: UUID
    factor_registry_version_id: UUID
    factor_registry_config: Mapping[str, object]
    scan_parameters_version_id: UUID
    scan_parameters_config: Mapping[str, object]
    candidate_parameters: Mapping[str, object]
    dataset_root_fingerprint: str
    maximum_signal_count: int
    existing_batch_hash: str | None


@dataclass(frozen=True, slots=True)
class ScanInstrument:
    instrument_id: int
    symbol: str


@dataclass(frozen=True, slots=True)
class PoolEvaluation:
    pool_evaluation_id: UUID
    evaluation_at: datetime


class DatabaseModelACandidateScanStore:
    def __init__(self, connection: AsyncConnection) -> None:
        self._connection = connection

    async def load_context(
        self, task_id: UUID, lease_token: UUID
    ) -> CandidateScanContext:
        result = await self._connection.execute(
            text(
                """
                SELECT *
                FROM strategy_training.training_model_a_candidate_scan_context(
                    :task_id, :lease_token
                )
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        row = result.mappings().one()
        return CandidateScanContext(
            iteration_id=cast(UUID, row["iteration_id"]),
            dataset_version_id=cast(UUID, row["dataset_version_id"]),
            interval_seconds=int(row["interval_seconds"]),
            eligible_start_at=cast(datetime, row["eligible_start_at"]),
            eligible_end_at=cast(datetime, row["eligible_end_at"]),
            ticker_pool_rule_version_id=cast(UUID, row["ticker_pool_rule_version_id"]),
            factor_registry_version_id=cast(UUID, row["factor_registry_version_id"]),
            factor_registry_config=cast(Mapping[str, object], row["factor_registry_config"]),
            scan_parameters_version_id=cast(UUID, row["scan_parameters_version_id"]),
            scan_parameters_config=cast(Mapping[str, object], row["scan_parameters_config"]),
            candidate_parameters=cast(Mapping[str, object], row["candidate_parameters"]),
            dataset_root_fingerprint=str(row["dataset_root_fingerprint"]),
            maximum_signal_count=int(row["maximum_signal_count"]),
            existing_batch_hash=(
                None if row["existing_batch_hash"] is None else str(row["existing_batch_hash"])
            ),
        )

    async def load_instruments(
        self, task_id: UUID, lease_token: UUID
    ) -> tuple[ScanInstrument, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT instrument_id, symbol
                FROM strategy_training.training_model_a_candidate_scan_instruments(
                    :task_id, :lease_token
                )
                ORDER BY symbol
                """
            ),
            {"task_id": task_id, "lease_token": lease_token},
        )
        return tuple(
            ScanInstrument(int(row["instrument_id"]), str(row["symbol"]))
            for row in result.mappings().all()
        )

    async def load_bars(
        self, task_id: UUID, lease_token: UUID, instrument_id: int
    ) -> tuple[FeatureBar, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT *
                FROM strategy_training.training_model_a_candidate_scan_bars(
                    :task_id, :lease_token, :instrument_id
                )
                ORDER BY open_time
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "instrument_id": instrument_id,
            },
        )
        return tuple(
            FeatureBar(
                open_time=cast(datetime, row["open_time"]),
                open_price=Decimal(str(row["open_price"])),
                high_price=Decimal(str(row["high_price"])),
                low_price=Decimal(str(row["low_price"])),
                close_price=Decimal(str(row["close_price"])),
                price_precision=(
                    None if row["price_precision"] is None else int(row["price_precision"])
                ),
                ema20=Decimal(str(row["ema20"])),
                ema240=Decimal(str(row["ema240"])),
                base_volume=Decimal(str(row["base_volume"])),
                quote_volume=Decimal(str(row["quote_volume"])),
                amplitude_percent=Decimal(str(row["amplitude_percent"])),
                open_interest_value=(
                    None
                    if row["open_interest_value"] is None
                    else Decimal(str(row["open_interest_value"]))
                ),
            )
            for row in result.mappings().all()
        )

    async def load_pool_evaluations(
        self, task_id: UUID, lease_token: UUID, instrument_id: int
    ) -> tuple[PoolEvaluation, ...]:
        result = await self._connection.execute(
            text(
                """
                SELECT pool_evaluation_id, evaluation_at
                FROM strategy_training.training_model_a_candidate_scan_pool(
                    :task_id, :lease_token, :instrument_id
                )
                ORDER BY evaluation_at
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "instrument_id": instrument_id,
            },
        )
        return tuple(
            PoolEvaluation(
                cast(UUID, row["pool_evaluation_id"]),
                cast(datetime, row["evaluation_at"]),
            )
            for row in result.mappings().all()
        )

    async def freeze_batch(
        self, task_id: UUID, lease_token: UUID, scan_result_hash: str
    ) -> str:
        result = await self._connection.execute(
            text(
                """
                SELECT strategy_training.complete_training_model_a_candidate_scan(
                    :task_id, :lease_token, :scan_result_hash
                )
                """
            ),
            {
                "task_id": task_id,
                "lease_token": lease_token,
                "scan_result_hash": scan_result_hash,
            },
        )
        return str(result.scalar_one())


def feature_bar_fingerprint(root_fingerprint: str, bars: tuple[FeatureBar, ...]) -> str:
    payload = {
        "root_fingerprint": root_fingerprint,
        "bars": [
            {
                "open_time": bar.open_time.isoformat(),
                "open": str(bar.open_price),
                "high": str(bar.high_price),
                "low": str(bar.low_price),
                "close": str(bar.close_price),
                "ema20": str(bar.ema20),
                "ema240": str(bar.ema240),
                "quote_volume": str(bar.quote_volume),
                "amplitude": str(bar.amplitude_percent),
                "oi": None if bar.open_interest_value is None else str(bar.open_interest_value),
            }
            for bar in bars
        ],
    }
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
