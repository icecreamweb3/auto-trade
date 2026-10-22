from __future__ import annotations

import asyncio
import json
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta, timezone
from decimal import Decimal
from html import escape
from pathlib import Path
from typing import IO, Literal, cast
from uuid import UUID, uuid4

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
    BacktestStrategy,
    BacktestStrategyWrite,
)
from auto_trade.monitoring.models import KlinePoint
from auto_trade.strategies.feature_scan import (
    ALL_FACTORS,
    FactorResult,
    StrategyEvaluation,
    StrategyParameters,
    StrategySignal,
    scan_database_detailed,
)

MAX_SIGNALS = 10_000
MAX_RETAINED_JOBS = 20
MAX_ACTIVE_JOBS = 2
MAX_LOG_LINES = 100_000
UTC_PLUS_8 = timezone(timedelta(hours=8))
DEFAULT_PRICE_PRECISION = 8

FACTOR_LOG_LABELS = {
    "bullish_candle_sequence": "连续强势阳线",
    "single_bar_price_rise": "单根K线快速拉升",
    "volume_acceleration": "短周期成交量加速",
    "ema_bullish_setup": "EMA金叉/临近金叉",
    "ema_bullish_cross": "EMA20上穿EMA240",
    "rapid_price_rise": "价格快速拉升",
    "open_interest_rise": "OI价值快速提升",
    "volume_surge": "成交量暴涨",
    "amplitude_spike_streak": "连续振幅异常",
    "low_average_amplitude": "平均振幅低",
}
PERCENT_FACTORS = frozenset(
    {
        "bullish_candle_sequence",
        "single_bar_price_rise",
        "ema_bullish_setup",
        "rapid_price_rise",
        "open_interest_rise",
        "low_average_amplitude",
    }
)
MULTIPLE_FACTORS = frozenset(
    {"volume_acceleration", "volume_surge", "amplitude_spike_streak"}
)


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
    log_line_count: int = 0
    log_truncated: bool = False
    log_path: Path | None = None
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


def _log_value(name: str, value: Decimal | int | None) -> str:
    if value is None:
        return "无"
    if isinstance(value, Decimal):
        if name in PERCENT_FACTORS:
            return f"{value:.2f}%"
        if name in MULTIPLE_FACTORS:
            return f"{value:.2f}x"
        return format(value, "f")
    return str(value)


def _factor_log(name: str, result: FactorResult) -> str:
    status = "✓" if result.passed else "✗"
    detail = (
        f"{FACTOR_LOG_LABELS[name]}: {status}"
        f" (实际值: {_log_value(name, result.value)}, 阈值: {result.threshold}"
    )
    if result.reason:
        detail += f", 原因: {result.reason}"
    return detail + ")"


def _format_price(value: Decimal, price_precision: int | None) -> str:
    precision = (
        price_precision if price_precision is not None else DEFAULT_PRICE_PRECISION
    )
    return f"{value:.{precision}f}"


def format_evaluation_log_line(
    evaluation: StrategyEvaluation, interval_seconds: int
) -> str:
    timestamp = evaluation.open_time.astimezone(UTC_PLUS_8).strftime(
        "%Y-%m-%d %H:%M:%S"
    )
    close_price = _format_price(evaluation.close_price, evaluation.price_precision)
    ema20 = _format_price(evaluation.ema20, evaluation.price_precision)
    ema240 = _format_price(evaluation.ema240, evaluation.price_precision)
    prefix = "🚀" if evaluation.matched else " "
    factors = " | ".join(
        _factor_log(name, evaluation.factors[name]) for name in ALL_FACTORS
    )
    return (
        f"{prefix} {evaluation.symbol} | {interval_seconds // 60}min"
        f" | K线 #{evaluation.bar_number} | {timestamp}"
        f" | 收盘价: {close_price}"
        f" | EMA20: {ema20} | EMA240: {ema240}"
        f" | 成交量: {evaluation.base_volume:.2f}"
        f" | 成交额: {evaluation.quote_volume:.2f} | {factors}"
    )


def _html_log_header(job: _Job) -> str:
    request = job.request
    config = escape(request.model_dump_json(indent=2))
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>策略回测日志 {job.job_id}</title>
<style>
body {{
  margin: 0; color: #d9e7f5; background: #07101d;
  font: 13px/1.65 ui-monospace, SFMono-Regular, Menlo, monospace;
}}
header {{
  position: sticky; top: 0; z-index: 2; padding: 18px 24px;
  border-bottom: 1px solid #29455e; background: rgba(7,16,29,.96);
}}
h1 {{ margin: 0 0 8px; color: #58d6c2; font: 700 22px/1.3 system-ui, sans-serif; }}
.meta {{ color: #8da4ba; }}
details {{ margin-top: 10px; }}
pre {{
  overflow: auto; padding: 12px; border-radius: 8px;
  background: #0b1a2a; white-space: pre-wrap;
}}
main {{ padding: 14px 24px 40px; overflow-x: auto; }}
.line {{
  padding: 5px 9px; border-bottom: 1px solid #13283a;
  box-sizing: border-box; width: max-content; min-width: 100%;
  white-space: pre; overflow-wrap: normal;
}}
.line:hover {{ background: #10263a; }}
.hit {{ color: #ffd27a; background: #182618; }}
.pass {{ color: #58d6c2; font-weight: 700; }}
.fail {{ color: #ff8a97; font-weight: 700; }}
.summary {{
  margin-top: 18px; padding: 12px; border: 1px solid #29455e;
  border-radius: 8px; color: #a9bed1;
}}
</style>
</head>
<body>
<header>
<h1>策略回测逐 K 线诊断日志</h1>
<div class="meta">
任务 {job.job_id} · {request.interval_seconds // 60}min
· 日志上限 {MAX_LOG_LINES:,} 根 K 线
</div>
<details><summary>查看回测配置</summary><pre>{config}</pre></details>
</header>
<main>
"""


def _html_evaluation_line(evaluation: StrategyEvaluation, interval_seconds: int) -> str:
    line = escape(format_evaluation_log_line(evaluation, interval_seconds))
    line = line.replace("✓", '<span class="pass">✓</span>')
    line = line.replace("✗", '<span class="fail">✗</span>')
    css_class = "line hit" if evaluation.matched else "line"
    return f'<div class="{css_class}">{line}</div>\n'


class BacktestManager:
    def __init__(
        self,
        engine: AsyncEngine,
        log_directory: Path | None = None,
        log_retention_days: int = 14,
    ) -> None:
        self.engine = engine
        self.jobs: OrderedDict[str, _Job] = OrderedDict()
        self.log_directory = log_directory or Path("/tmp/auto-trade-backtests")
        self.log_retention_days = log_retention_days

    def create(self, request: BacktestCreateRequest) -> _Job:
        self._cleanup_expired_logs()
        active_jobs = sum(
            job.status in ("QUEUED", "RUNNING") for job in self.jobs.values()
        )
        if active_jobs >= MAX_ACTIVE_JOBS:
            raise RuntimeError("too many active backtests")
        if not request.preserve_log_history:
            self._delete_historical_logs()
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
        log_path = self.log_path(job)
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
            log_line_count=job.log_line_count,
            log_truncated=job.log_truncated,
            log_available=log_path is not None,
            log_url=(
                f"/api/backtests/logs/{log_path.name}"
                if log_path is not None
                else None
            ),
            max_log_lines=MAX_LOG_LINES,
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

    async def list_strategies(self) -> tuple[BacktestStrategy, ...]:
        sql = """
            SELECT strategy_id, name, description, interval_seconds, parameters,
                   created_at, updated_at
            FROM config.backtest_strategies
            ORDER BY updated_at DESC, name
        """
        async with self.engine.connect() as connection:
            rows = (await connection.execute(text(sql))).mappings().all()
        return tuple(BacktestStrategy.model_validate(dict(row)) for row in rows)

    async def create_strategy(self, strategy: BacktestStrategyWrite) -> BacktestStrategy:
        sql = """
            INSERT INTO config.backtest_strategies (
                name, description, interval_seconds, parameters
            )
            VALUES (
                :name, :description, :interval_seconds, CAST(:parameters AS jsonb)
            )
            RETURNING strategy_id, name, description, interval_seconds, parameters,
                      created_at, updated_at
        """
        values = self._strategy_values(strategy)
        async with self.engine.begin() as connection:
            row = (await connection.execute(text(sql), values)).mappings().one()
        return BacktestStrategy.model_validate(dict(row))

    async def update_strategy(
        self, strategy_id: UUID, strategy: BacktestStrategyWrite
    ) -> BacktestStrategy | None:
        sql = """
            UPDATE config.backtest_strategies
            SET name = :name,
                description = :description,
                interval_seconds = :interval_seconds,
                parameters = CAST(:parameters AS jsonb)
            WHERE strategy_id = CAST(:strategy_id AS uuid)
            RETURNING strategy_id, name, description, interval_seconds, parameters,
                      created_at, updated_at
        """
        values = self._strategy_values(strategy) | {"strategy_id": str(strategy_id)}
        async with self.engine.begin() as connection:
            row = (await connection.execute(text(sql), values)).mappings().one_or_none()
        return BacktestStrategy.model_validate(dict(row)) if row is not None else None

    async def delete_strategy(self, strategy_id: UUID) -> bool:
        sql = """
            DELETE FROM config.backtest_strategies
            WHERE strategy_id = CAST(:strategy_id AS uuid)
            RETURNING strategy_id
        """
        async with self.engine.begin() as connection:
            deleted = (
                await connection.execute(text(sql), {"strategy_id": str(strategy_id)})
            ).scalar_one_or_none()
        return deleted is not None

    @staticmethod
    def _strategy_values(strategy: BacktestStrategyWrite) -> dict[str, object]:
        return {
            "name": strategy.name,
            "description": strategy.description,
            "interval_seconds": strategy.interval_seconds,
            "parameters": json.dumps(strategy.parameters.model_dump(mode="json")),
        }

    def log_path(self, job: _Job) -> Path | None:
        if job.log_path is None or not job.log_path.is_file():
            return None
        return job.log_path

    def resolve_log(self, filename: str) -> Path | None:
        if not filename.startswith("backtest-") or not filename.endswith(".html"):
            return None
        stem = filename.removeprefix("backtest-").removesuffix(".html")
        is_hex = all(character in "0123456789abcdef" for character in stem)
        if len(stem) != 32 or not is_hex:
            return None
        path = self.log_directory / filename
        return path if path.is_file() else None

    def _cleanup_expired_logs(self) -> None:
        if not self.log_directory.is_dir():
            return
        cutoff = time.time() - self.log_retention_days * 24 * 60 * 60
        for path in self.log_directory.glob("backtest-*.html"):
            try:
                if path.is_file() and path.stat().st_mtime < cutoff:
                    path.unlink(missing_ok=True)
            except OSError:
                continue

    def _delete_historical_logs(self) -> None:
        active_paths = {
            job.log_path
            for job in self.jobs.values()
            if job.status in ("QUEUED", "RUNNING") and job.log_path is not None
        }
        if self.log_directory.is_dir():
            for path in self.log_directory.glob("backtest-*.html"):
                if path not in active_paths and path.is_file():
                    path.unlink(missing_ok=True)
        for job in self.jobs.values():
            if job.log_path is not None and not job.log_path.is_file():
                job.log_path = None

    async def metadata(self) -> BacktestMetadata:
        intervals: dict[str, BacktestIntervalMetadata] = {}
        async with self.engine.connect() as connection:
            await connection.execute(
                text(
                    "SELECT set_config("
                    "'plan_cache_mode', 'force_custom_plan', true)"
                )
            )
            chunk_rows = (
                await connection.execute(
                    text(
                        """
                        WITH ranked AS (
                            SELECT hypertable_name, range_start, range_end,
                                   row_number() OVER (
                                       PARTITION BY hypertable_name
                                       ORDER BY range_start
                                   ) AS first_rank,
                                   row_number() OVER (
                                       PARTITION BY hypertable_name
                                       ORDER BY range_start DESC
                                   ) AS last_rank
                            FROM timescaledb_information.chunks
                            WHERE hypertable_schema = 'market'
                              AND hypertable_name IN ('klines', 'klines_15m')
                        )
                        SELECT hypertable_name, edge, range_start, range_end
                        FROM (
                            SELECT hypertable_name, 'FIRST' AS edge,
                                   range_start, range_end
                            FROM ranked WHERE first_rank = 1
                            UNION ALL
                            SELECT hypertable_name, 'LAST' AS edge,
                                   range_start, range_end
                            FROM ranked WHERE last_rank = 1
                        ) edges
                        ORDER BY hypertable_name, edge
                        """
                    )
                )
            ).mappings().all()
            chunk_bounds = {
                (cast(str, row["hypertable_name"]), cast(str, row["edge"])): (
                    cast(datetime, row["range_start"]),
                    cast(datetime, row["range_end"]),
                )
                for row in chunk_rows
            }
            for interval_seconds in (300, 900):
                if interval_seconds == 900:
                    hypertable_name = "klines_15m"
                    table_name = "market.klines_15m"
                    filters = (
                        "price_type = 'TRADE' AND interval_seconds = 900"
                    )
                else:
                    hypertable_name = "klines"
                    table_name = "market.klines"
                    filters = (
                        "price_type = 'TRADE' AND interval_seconds = 300 "
                        "AND is_current AND is_closed "
                        "AND quality_status = 'VALID'"
                    )
                first_chunk = chunk_bounds.get((hypertable_name, "FIRST"))
                last_chunk = chunk_bounds.get((hypertable_name, "LAST"))
                if first_chunk is None or last_chunk is None:
                    intervals[str(interval_seconds)] = BacktestIntervalMetadata()
                    continue
                bounds_sql = f"""
                    SELECT (
                        SELECT min(open_time) FROM {table_name}
                        WHERE {filters}
                          AND open_time >= CAST(:first_start AS timestamptz)
                          AND open_time < CAST(:first_end AS timestamptz)
                    ) AS available_from, (
                        SELECT max(open_time) FROM {table_name}
                        WHERE {filters}
                          AND open_time >= CAST(:last_start AS timestamptz)
                          AND open_time < CAST(:last_end AS timestamptz)
                    ) AS available_to
                """
                symbols_sql = f"""
                    SELECT i.symbol
                    FROM core.instruments i
                    WHERE EXISTS (
                        SELECT 1 FROM {table_name} k
                        WHERE k.instrument_id = i.instrument_id
                          AND {filters}
                          AND k.open_time >= CAST(:last_start AS timestamptz)
                          AND k.open_time < CAST(:last_end AS timestamptz)
                    )
                    ORDER BY i.symbol
                """
                parameters = {
                    "first_start": first_chunk[0],
                    "first_end": first_chunk[1],
                    "last_start": last_chunk[0],
                    "last_end": last_chunk[1],
                }
                bounds = (
                    await connection.execute(text(bounds_sql), parameters)
                ).mappings().one()
                symbol_rows: list[object] = cast(
                    list[object],
                    (
                        await connection.execute(text(symbols_sql), parameters)
                    ).scalars().all(),
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
            bullish_sequence_bars=parameters.bullish_sequence_bars,
            bullish_min_close_position_percent=(
                parameters.bullish_min_close_position_percent
            ),
            bullish_last_close_position_percent=(
                parameters.bullish_last_close_position_percent
            ),
            bullish_last_max_upper_shadow_percent=(
                parameters.bullish_last_max_upper_shadow_percent
            ),
            single_bar_price_rise_percent=parameters.single_bar_price_rise_percent,
            volume_acceleration_average_bars=(
                parameters.volume_acceleration_average_bars
            ),
            volume_acceleration_average_multiple=(
                parameters.volume_acceleration_average_multiple
            ),
            volume_acceleration_previous_multiple=(
                parameters.volume_acceleration_previous_multiple
            ),
            ema_near_cross_gap_percent=parameters.ema_near_cross_gap_percent,
            ema_gap_shrink_min_percent=parameters.ema_gap_shrink_min_percent,
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
        log_file: IO[str] | None = None

        def update_progress(scanned: int, total: int) -> None:
            job.scanned_instruments = scanned
            job.total_instruments = total
            if log_file is not None:
                log_file.flush()

        def emit_signals(signals: tuple[StrategySignal, ...]) -> None:
            job.signals = (*job.signals, *(_signal_model(signal) for signal in signals))

        def emit_evaluation(evaluation: StrategyEvaluation) -> None:
            if log_file is None:
                return
            if job.log_line_count >= MAX_LOG_LINES:
                job.log_truncated = True
                return
            log_file.write(_html_evaluation_line(evaluation, request.interval_seconds))
            job.log_line_count += 1

        try:
            if request.generate_log:
                self.log_directory.mkdir(parents=True, exist_ok=True)
                log_path = self.log_directory / f"backtest-{job.job_id}.html"
                log_file = log_path.open("x", encoding="utf-8")
                job.log_path = log_path
                log_file.write(_html_log_header(job))
            result = await scan_database_detailed(
                self.engine,
                strategy_parameters,
                symbols=request.symbols or None,
                start=request.start_at,
                end=request.end_at,
                max_signals=MAX_SIGNALS,
                progress_callback=update_progress,
                signals_callback=emit_signals,
                evaluation_callback=emit_evaluation if request.generate_log else None,
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
            if log_file is not None:
                if job.log_truncated:
                    log_file.write(
                        f'<div class="summary">日志已在 {MAX_LOG_LINES:,} 条 K 线记录处截断; '
                        "请缩短时间范围或减少 Tickers。</div>\n"
                    )
                log_file.write(
                    f'<div class="summary">回测结束: 状态={job.status}, '
                    f"信号数={len(job.signals)}, 扫描 Tickers="
                    f"{job.scanned_instruments}/{job.total_instruments}</div>\n"
                    "</main></body></html>\n"
                )
                log_file.close()

    def _discard_old_jobs(self) -> None:
        removable = [
            job_id
            for job_id, job in self.jobs.items()
            if job.status in ("COMPLETED", "FAILED")
        ]
        while len(self.jobs) >= MAX_RETAINED_JOBS and removable:
            self.jobs.pop(removable.pop(0), None)
