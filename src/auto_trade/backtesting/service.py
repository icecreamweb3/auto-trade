from __future__ import annotations

import asyncio
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Literal, cast
from uuid import uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.backtesting.models import (
    BacktestCreateRequest,
    BacktestFactorResult,
    BacktestIntervalMetadata,
    BacktestJobResult,
    BacktestKlineResult,
    BacktestMetadata,
    BacktestSignal,
    BacktestStatus,
)
from auto_trade.monitoring.models import KlinePoint
from auto_trade.strategies.feature_scan import (
    StrategyParameters,
    StrategySignal,
    scan_database_detailed,
)

MAX_SIGNALS = 10_000
MAX_RETAINED_JOBS = 20
MAX_ACTIVE_JOBS = 2


@dataclass(slots=True)
class _Job:
    job_id: str
    request: BacktestCreateRequest
    created_at: datetime
    status: BacktestStatus = "QUEUED"
    started_at: datetime | None = None
    completed_at: datetime | None = None
    scanned_instruments: int = 0
    total_instruments: int = 0
    truncated: bool = False
    error: str | None = None
    signals: tuple[BacktestSignal, ...] = ()
    task: asyncio.Task[None] | None = field(default=None, repr=False)


def _factor_value(value: Decimal | int | None) -> float | int | None:
    return float(value) if isinstance(value, Decimal) else value


def _signal_model(signal: StrategySignal) -> BacktestSignal:
    return BacktestSignal(
        symbol=signal.symbol,
        open_time=signal.open_time,
        close_price=float(signal.close_price),
        factors={
            name: BacktestFactorResult(
                passed=result.passed,
                value=_factor_value(result.value),
                threshold=result.threshold,
                reason=result.reason,
            )
            for name, result in signal.factors.items()
        },
    )


class BacktestManager:
    def __init__(self, engine: AsyncEngine) -> None:
        self.engine = engine
        self.jobs: OrderedDict[str, _Job] = OrderedDict()

    def create(self, request: BacktestCreateRequest) -> _Job:
        active_jobs = sum(
            job.status in ("QUEUED", "RUNNING") for job in self.jobs.values()
        )
        if active_jobs >= MAX_ACTIVE_JOBS:
            raise RuntimeError("too many active backtests")
        self._discard_old_jobs()
        job = _Job(
            job_id=uuid4().hex,
            request=request,
            created_at=datetime.now(UTC),
        )
        self.jobs[job.job_id] = job
        job.task = asyncio.create_task(self._run(job), name=f"backtest-{job.job_id}")
        return job

    def get(self, job_id: str) -> _Job | None:
        return self.jobs.get(job_id)

    def response(self, job: _Job) -> BacktestJobResult:
        return BacktestJobResult(
            job_id=job.job_id,
            status=job.status,
            created_at=job.created_at,
            started_at=job.started_at,
            completed_at=job.completed_at,
            scanned_instruments=job.scanned_instruments,
            total_instruments=job.total_instruments,
            signal_count=len(job.signals),
            truncated=job.truncated,
            max_signals=MAX_SIGNALS,
            error=job.error,
            request=job.request,
            signals=job.signals,
        )

    async def close(self) -> None:
        tasks = [job.task for job in self.jobs.values() if job.task and not job.task.done()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def metadata(self) -> BacktestMetadata:
        intervals: dict[str, BacktestIntervalMetadata] = {}
        async with self.engine.connect() as connection:
            for interval_seconds in (300, 900):
                if interval_seconds == 900:
                    bounds_sql = """
                        SELECT min(open_time) AS available_from,
                               max(open_time) AS available_to
                        FROM market.klines_15m
                        WHERE price_type = 'TRADE' AND interval_seconds = 900
                    """
                    symbols_sql = """
                        SELECT i.symbol
                        FROM core.instruments i
                        WHERE EXISTS (
                            SELECT 1 FROM market.klines_15m k
                            WHERE k.instrument_id = i.instrument_id
                              AND k.price_type = 'TRADE'
                              AND k.interval_seconds = 900
                        )
                        ORDER BY i.symbol
                    """
                else:
                    bounds_sql = """
                        SELECT min(open_time) AS available_from,
                               max(open_time) AS available_to
                        FROM market.klines
                        WHERE price_type = 'TRADE'
                          AND interval_seconds = 300
                          AND is_current AND is_closed
                          AND quality_status = 'VALID'
                    """
                    symbols_sql = """
                        SELECT i.symbol
                        FROM core.instruments i
                        WHERE EXISTS (
                            SELECT 1 FROM market.klines k
                            WHERE k.instrument_id = i.instrument_id
                              AND k.price_type = 'TRADE'
                              AND k.interval_seconds = 300
                              AND k.is_current AND k.is_closed
                              AND k.quality_status = 'VALID'
                        )
                        ORDER BY i.symbol
                    """
                bounds = (await connection.execute(text(bounds_sql))).mappings().one()
                symbol_rows: list[object] = cast(
                    list[object],
                    (await connection.execute(text(symbols_sql))).scalars().all(),
                )
                intervals[str(interval_seconds)] = BacktestIntervalMetadata(
                    available_from=cast(datetime | None, bounds["available_from"]),
                    available_to=cast(datetime | None, bounds["available_to"]),
                    symbols=tuple(cast(str, symbol) for symbol in symbol_rows),
                )
        return BacktestMetadata(intervals=intervals)

    async def signal_klines(
        self,
        *,
        symbol: str,
        signal_time: datetime,
        interval_seconds: int,
        before_bars: int,
        after_bars: int,
    ) -> BacktestKlineResult:
        if interval_seconds not in (300, 900):
            raise ValueError("interval_seconds must be 300 or 900")
        range_start = signal_time - timedelta(seconds=interval_seconds * before_bars)
        range_end = signal_time + timedelta(seconds=interval_seconds * (after_bars + 1))
        if interval_seconds == 900:
            source_sql = """
                SELECT k.open_time, k.close_time,
                       k.open_price, k.high_price, k.low_price, k.close_price,
                       k.base_volume, k.quote_volume,
                       k.open_interest_qty, k.open_interest_value,
                       e.ema20, e.ema240,
                       e.price_change_percent, e.amplitude_percent
                FROM market.klines_15m k
                JOIN core.instruments i ON i.instrument_id = k.instrument_id
                JOIN market.kline_ema_indicators e
                  ON e.instrument_id = k.instrument_id
                 AND e.price_type = k.price_type
                 AND e.interval_seconds = k.interval_seconds
                 AND e.open_time = k.open_time
                WHERE upper(i.symbol) = :symbol
                  AND k.price_type = 'TRADE'
                  AND k.interval_seconds = :interval_seconds
                  AND k.open_time >= CAST(:range_start AS timestamptz)
                  AND k.open_time < CAST(:range_end AS timestamptz)
                ORDER BY k.open_time
            """
        else:
            source_sql = """
                SELECT k.open_time, k.close_time,
                       k.open_price, k.high_price, k.low_price, k.close_price,
                       k.base_volume, k.quote_volume,
                       oi.open_interest_qty, oi.open_interest_value,
                       e.ema20, e.ema240,
                       e.price_change_percent, e.amplitude_percent
                FROM market.klines k
                JOIN core.instruments i ON i.instrument_id = k.instrument_id
                JOIN market.kline_ema_indicators e
                  ON e.instrument_id = k.instrument_id
                 AND e.price_type = k.price_type
                 AND e.interval_seconds = k.interval_seconds
                 AND e.open_time = k.open_time
                LEFT JOIN LATERAL (
                    SELECT o.open_interest_qty, o.open_interest_value
                    FROM market.open_interest_observations o
                    WHERE o.instrument_id = k.instrument_id
                      AND o.observed_at >= k.open_time
                      AND o.observed_at < k.open_time + interval '5 minutes'
                      AND o.quality_status IN ('VALID', 'PARTIAL')
                    ORDER BY o.observed_at DESC
                    LIMIT 1
                ) oi ON true
                WHERE upper(i.symbol) = :symbol
                  AND k.price_type = 'TRADE'
                  AND k.interval_seconds = :interval_seconds
                  AND k.is_current AND k.is_closed
                  AND k.quality_status = 'VALID'
                  AND k.open_time >= CAST(:range_start AS timestamptz)
                  AND k.open_time < CAST(:range_end AS timestamptz)
                ORDER BY k.open_time
            """
        async with self.engine.connect() as connection:
            rows = (
                await connection.execute(
                    text(source_sql),
                    {
                        "symbol": symbol,
                        "interval_seconds": interval_seconds,
                        "range_start": range_start,
                        "range_end": range_end,
                    },
                )
            ).mappings().all()
        return BacktestKlineResult(
            symbol=symbol,
            signal_time=signal_time,
            interval_seconds=cast(Literal[300, 900], interval_seconds),
            items=tuple(KlinePoint.model_validate(row) for row in rows),
        )

    async def _run(self, job: _Job) -> None:
        job.status = "RUNNING"
        job.started_at = datetime.now(UTC)
        request = job.request
        span_days = max(1, (request.end_at - request.start_at).days + 1)
        parameters = request.parameters
        strategy_parameters = StrategyParameters(
            interval_seconds=request.interval_seconds,
            lookback_days=span_days,
            average_days=parameters.average_days,
            ema_cross_lookback_bars=parameters.ema_cross_lookback_bars,
            rapid_price_window_bars=parameters.rapid_price_window_bars,
            rapid_price_rise_percent=parameters.rapid_price_rise_percent,
            open_interest_window_bars=parameters.open_interest_window_bars,
            open_interest_rise_percent=parameters.open_interest_rise_percent,
            volume_surge_multiple=parameters.volume_surge_multiple,
            amplitude_spike_multiple=parameters.amplitude_spike_multiple,
            amplitude_consecutive_bars=parameters.amplitude_consecutive_bars,
            average_amplitude_max_percent=parameters.average_amplitude_max_percent,
            required_factors=parameters.required_factors,
        )

        def update_progress(scanned: int, total: int) -> None:
            job.scanned_instruments = scanned
            job.total_instruments = total

        def emit_signals(signals: tuple[StrategySignal, ...]) -> None:
            job.signals = (*job.signals, *(_signal_model(signal) for signal in signals))

        try:
            result = await scan_database_detailed(
                self.engine,
                strategy_parameters,
                symbols=request.symbols or None,
                start=request.start_at,
                end=request.end_at,
                max_signals=MAX_SIGNALS,
                progress_callback=update_progress,
                signals_callback=emit_signals,
            )
            job.scanned_instruments = result.scanned_instruments
            job.total_instruments = result.total_instruments
            job.signals = tuple(_signal_model(signal) for signal in result.signals)
            job.truncated = result.truncated
            job.status = "COMPLETED"
        except asyncio.CancelledError:
            raise
        except Exception as error:
            job.status = "FAILED"
            job.error = str(error) or error.__class__.__name__
        finally:
            job.completed_at = datetime.now(UTC)

    def _discard_old_jobs(self) -> None:
        removable = [
            job_id
            for job_id, job in self.jobs.items()
            if job.status in ("COMPLETED", "FAILED")
        ]
        while len(self.jobs) >= MAX_RETAINED_JOBS and removable:
            self.jobs.pop(removable.pop(0), None)
