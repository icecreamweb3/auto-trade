from __future__ import annotations

import argparse
import asyncio
import csv
import json
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import IO, Literal, cast

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from auto_trade.config import get_settings
from auto_trade.infrastructure.database import create_database_engine

FactorName = Literal[
    "ema_bullish_cross",
    "rapid_price_rise",
    "open_interest_rise",
    "volume_surge",
    "amplitude_spike_streak",
    "low_average_amplitude",
]

ALL_FACTORS: tuple[FactorName, ...] = (
    "ema_bullish_cross",
    "rapid_price_rise",
    "open_interest_rise",
    "volume_surge",
    "amplitude_spike_streak",
    "low_average_amplitude",
)
SUPPORTED_INTERVALS = (300, 900)
PERCENT_QUANTUM = Decimal("0.01")


@dataclass(frozen=True, slots=True)
class StrategyParameters:
    interval_seconds: int = 900
    lookback_days: int = 90
    average_days: int = 7
    ema_cross_lookback_bars: int = 4
    rapid_price_window_bars: int = 4
    rapid_price_rise_percent: Decimal = Decimal("3")
    open_interest_window_bars: int = 4
    open_interest_rise_percent: Decimal = Decimal("5")
    volume_surge_multiple: Decimal = Decimal("5")
    amplitude_spike_multiple: Decimal = Decimal("5")
    amplitude_consecutive_bars: int = 2
    average_amplitude_max_percent: Decimal = Decimal("2")
    required_factors: tuple[FactorName, ...] = ALL_FACTORS

    def __post_init__(self) -> None:
        if self.interval_seconds not in SUPPORTED_INTERVALS:
            raise ValueError("interval_seconds must be 300 or 900")
        positive_integers = (
            self.lookback_days,
            self.average_days,
            self.ema_cross_lookback_bars,
            self.rapid_price_window_bars,
            self.open_interest_window_bars,
            self.amplitude_consecutive_bars,
        )
        if any(value <= 0 for value in positive_integers):
            raise ValueError("day and bar parameters must be positive")
        nonnegative_decimals = (
            self.rapid_price_rise_percent,
            self.open_interest_rise_percent,
            self.volume_surge_multiple,
            self.amplitude_spike_multiple,
            self.average_amplitude_max_percent,
        )
        if any(value < 0 for value in nonnegative_decimals):
            raise ValueError("factor thresholds must be nonnegative")
        if not self.required_factors:
            raise ValueError("at least one required factor is needed")
        if len(set(self.required_factors)) != len(self.required_factors):
            raise ValueError("required factors must not contain duplicates")

    @property
    def average_bars(self) -> int:
        return self.average_days * 24 * 60 * 60 // self.interval_seconds

    @property
    def warmup_bars(self) -> int:
        return self.average_bars + max(
            self.ema_cross_lookback_bars,
            self.rapid_price_window_bars,
            self.open_interest_window_bars,
            self.amplitude_consecutive_bars,
        )


@dataclass(frozen=True, slots=True)
class FeatureBar:
    open_time: datetime
    close_price: Decimal
    price_precision: int | None
    ema20: Decimal
    ema240: Decimal
    base_volume: Decimal
    quote_volume: Decimal
    amplitude_percent: Decimal
    open_interest_value: Decimal | None


@dataclass(frozen=True, slots=True)
class FactorResult:
    passed: bool
    value: Decimal | int | None
    threshold: str
    reason: str | None = None


@dataclass(frozen=True, slots=True)
class StrategySignal:
    symbol: str
    open_time: datetime
    close_price: Decimal
    factors: Mapping[FactorName, FactorResult]


@dataclass(frozen=True, slots=True)
class StrategyEvaluation:
    symbol: str
    bar_number: int
    open_time: datetime
    close_price: Decimal
    price_precision: int | None
    ema20: Decimal
    ema240: Decimal
    base_volume: Decimal
    quote_volume: Decimal
    factors: Mapping[FactorName, FactorResult]
    matched: bool


@dataclass(frozen=True, slots=True)
class DatabaseScanResult:
    signals: tuple[StrategySignal, ...]
    scanned_instruments: int
    total_instruments: int
    truncated: bool = False


class SeriesContext:
    def __init__(self, bars: Sequence[FeatureBar], interval_seconds: int) -> None:
        self.bars = bars
        self.volume_prefix = self._prefix("quote_volume")
        self.amplitude_prefix = self._prefix("amplitude_percent")
        self.contiguous_count: list[int] = []
        expected_delta = timedelta(seconds=interval_seconds)
        for index, bar in enumerate(bars):
            if index and bar.open_time - bars[index - 1].open_time == expected_delta:
                self.contiguous_count.append(self.contiguous_count[-1] + 1)
            else:
                self.contiguous_count.append(1)

    def _prefix(self, attribute: str) -> list[Decimal]:
        result = [Decimal(0)]
        for bar in self.bars:
            result.append(result[-1] + cast(Decimal, getattr(bar, attribute)))
        return result

    def average_before(self, index: int, count: int, attribute: str) -> Decimal | None:
        if index < count or self.contiguous_count[index] < count + 1:
            return None
        prefix = self.volume_prefix if attribute == "quote_volume" else self.amplitude_prefix
        return (prefix[index] - prefix[index - count]) / Decimal(count)

    def is_contiguous(self, index: int, required_count: int) -> bool:
        return index >= 0 and self.contiguous_count[index] >= required_count


def _ema_bullish_cross(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    first = max(1, index - parameters.ema_cross_lookback_bars + 1)
    for cross_index in range(index, first - 1, -1):
        current = context.bars[cross_index]
        previous = context.bars[cross_index - 1]
        bars_ago = index - cross_index
        if not context.is_contiguous(index, bars_ago + 2):
            continue
        if current.ema20 > current.ema240 and previous.ema20 <= previous.ema240:
            return FactorResult(
                True,
                bars_ago,
                f"bars_since_cross < {parameters.ema_cross_lookback_bars}",
            )
    return FactorResult(
        False,
        None,
        f"bars_since_cross < {parameters.ema_cross_lookback_bars}",
        "no bullish EMA20/EMA240 cross in the configured window",
    )


def _percent_change(current: Decimal, previous: Decimal) -> Decimal | None:
    if previous <= 0:
        return None
    return _percent_2((current / previous - Decimal(1)) * Decimal(100))


def _percent_2(value: Decimal) -> Decimal:
    return value.quantize(PERCENT_QUANTUM, rounding=ROUND_HALF_UP)


def _percent_threshold(operator: str, value: Decimal) -> str:
    return f"{operator} {_percent_2(value):.2f}%"


def _rapid_price_rise(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    window = parameters.rapid_price_window_bars
    if index < window or not context.is_contiguous(index, window + 1):
        return FactorResult(
            False,
            None,
            _percent_threshold(">=", parameters.rapid_price_rise_percent),
            "missing continuous price history",
        )
    value = _percent_change(
        context.bars[index].close_price, context.bars[index - window].close_price
    )
    threshold = _percent_2(parameters.rapid_price_rise_percent)
    return FactorResult(
        value is not None and value >= threshold,
        value,
        f"{_percent_threshold('>=', parameters.rapid_price_rise_percent)} "
        f"over {window} bars",
    )


def _open_interest_rise(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    window = parameters.open_interest_window_bars
    if index < window or not context.is_contiguous(index, window + 1):
        return FactorResult(
            False,
            None,
            _percent_threshold(">=", parameters.open_interest_rise_percent),
            "missing continuous OI history",
        )
    current = context.bars[index].open_interest_value
    previous = context.bars[index - window].open_interest_value
    if current is None or previous is None:
        return FactorResult(
            False,
            None,
            _percent_threshold(">=", parameters.open_interest_rise_percent),
            "OI value is unavailable",
        )
    value = _percent_change(current, previous)
    threshold = _percent_2(parameters.open_interest_rise_percent)
    return FactorResult(
        value is not None and value >= threshold,
        value,
        f"{_percent_threshold('>=', parameters.open_interest_rise_percent)} "
        f"over {window} bars",
    )


def _volume_surge(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    average = context.average_before(index, parameters.average_bars, "quote_volume")
    if average is None or average <= 0:
        return FactorResult(
            False,
            None,
            f">= {parameters.volume_surge_multiple}x",
            "missing prior volume average",
        )
    value = context.bars[index].quote_volume / average
    return FactorResult(
        value >= parameters.volume_surge_multiple,
        value,
        f">= {parameters.volume_surge_multiple}x prior {parameters.average_days}d average",
    )


def _average_amplitude(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> Decimal | None:
    return context.average_before(index, parameters.average_bars, "amplitude_percent")


def _amplitude_spike_streak(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    start = index - parameters.amplitude_consecutive_bars + 1
    if start < 0 or not context.is_contiguous(index, parameters.amplitude_consecutive_bars):
        return FactorResult(
            False,
            None,
            f">= {parameters.amplitude_spike_multiple}x",
            "missing consecutive bars",
        )
    multiples: list[Decimal] = []
    for streak_index in range(start, index + 1):
        average = _average_amplitude(context, streak_index, parameters)
        if average is None or average <= 0:
            return FactorResult(
                False,
                None,
                f">= {parameters.amplitude_spike_multiple}x",
                "missing prior amplitude average",
            )
        multiples.append(context.bars[streak_index].amplitude_percent / average)
    value = min(multiples)
    return FactorResult(
        value >= parameters.amplitude_spike_multiple,
        value,
        f">= {parameters.amplitude_spike_multiple}x for "
        f"{parameters.amplitude_consecutive_bars} consecutive bars",
    )


def _low_average_amplitude(
    context: SeriesContext, index: int, parameters: StrategyParameters
) -> FactorResult:
    value = _average_amplitude(context, index, parameters)
    value = _percent_2(value) if value is not None else None
    threshold = _percent_2(parameters.average_amplitude_max_percent)
    return FactorResult(
        value is not None and value < threshold,
        value,
        f"{_percent_threshold('<', parameters.average_amplitude_max_percent)} "
        f"over prior {parameters.average_days}d",
        None if value is not None else "missing prior amplitude average",
    )


FACTOR_EVALUATORS = {
    "ema_bullish_cross": _ema_bullish_cross,
    "rapid_price_rise": _rapid_price_rise,
    "open_interest_rise": _open_interest_rise,
    "volume_surge": _volume_surge,
    "amplitude_spike_streak": _amplitude_spike_streak,
    "low_average_amplitude": _low_average_amplitude,
}


def evaluate_series(
    symbol: str,
    bars: Sequence[FeatureBar],
    parameters: StrategyParameters,
    scan_start: datetime,
    evaluation_callback: Callable[[StrategyEvaluation], None] | None = None,
) -> tuple[StrategySignal, ...]:
    context = SeriesContext(bars, parameters.interval_seconds)
    signals: list[StrategySignal] = []
    bar_number = 0
    for index, bar in enumerate(bars):
        if bar.open_time < scan_start:
            continue
        bar_number += 1
        factors = {
            name: FACTOR_EVALUATORS[name](context, index, parameters) for name in ALL_FACTORS
        }
        matched = all(factors[name].passed for name in parameters.required_factors)
        if evaluation_callback is not None:
            evaluation_callback(
                StrategyEvaluation(
                    symbol=symbol,
                    bar_number=bar_number,
                    open_time=bar.open_time,
                    close_price=bar.close_price,
                    price_precision=bar.price_precision,
                    ema20=bar.ema20,
                    ema240=bar.ema240,
                    base_volume=bar.base_volume,
                    quote_volume=bar.quote_volume,
                    factors=factors,
                    matched=matched,
                )
            )
        if matched:
            signals.append(StrategySignal(symbol, bar.open_time, bar.close_price, factors))
    return tuple(signals)


async def _instrument_rows(
    connection: AsyncConnection,
    symbols: Sequence[str] | None,
    interval_seconds: int,
) -> Sequence[Mapping[str, object]]:
    source_condition = (
        """
        EXISTS (
            SELECT 1
            FROM market.klines_15m k
            WHERE k.instrument_id = i.instrument_id
              AND k.price_type = 'TRADE'
              AND k.interval_seconds = 900
        )
        """
        if interval_seconds == 900
        else """
        EXISTS (
            SELECT 1
            FROM market.klines k
            WHERE k.instrument_id = i.instrument_id
              AND k.price_type = 'TRADE'
              AND k.interval_seconds = 300
              AND k.is_current
              AND k.is_closed
              AND k.quality_status = 'VALID'
        )
        """
    )
    result = await connection.execute(
        text(
            f"""
            SELECT i.instrument_id, i.symbol
            FROM core.instruments i
            WHERE i.exchange = 'BINANCE'
              AND i.market = 'USD_M_FUTURES'
              AND i.contract_type = 'PERPETUAL'
              AND (:all_symbols OR upper(i.symbol) = ANY(CAST(:symbols AS text[])))
              AND {source_condition}
            ORDER BY i.symbol
            """
        ),
        {
            "all_symbols": not symbols,
            "symbols": [symbol.upper() for symbol in symbols] if symbols else [],
        },
    )
    return [cast(Mapping[str, object], row) for row in result.mappings().all()]


async def _load_feature_bars(
    connection: AsyncConnection,
    instrument_id: int,
    start: datetime,
    end: datetime,
    interval_seconds: int,
) -> tuple[FeatureBar, ...]:
    if interval_seconds == 900:
        source_sql = """
            SELECT e.open_time, e.close_price, rules.price_precision,
                   e.ema20, e.ema240,
                   k.base_volume, k.quote_volume,
                   e.amplitude_percent, k.open_interest_value
            FROM market.kline_ema_indicators e
            JOIN market.klines_15m k
              ON k.instrument_id = e.instrument_id
             AND k.price_type = e.price_type
             AND k.interval_seconds = e.interval_seconds
             AND k.open_time = e.open_time
            LEFT JOIN LATERAL (
                SELECT r.price_precision
                FROM core.instrument_rule_versions r
                WHERE r.instrument_id = e.instrument_id
                ORDER BY (r.effective_from <= e.open_time) DESC,
                         CASE WHEN r.effective_from <= e.open_time
                              THEN r.effective_from END DESC,
                         CASE WHEN r.effective_from > e.open_time
                              THEN r.effective_from END ASC
                LIMIT 1
            ) rules ON true
            WHERE e.instrument_id = :instrument_id
              AND e.price_type = 'TRADE'
              AND e.interval_seconds = :interval_seconds
              AND e.open_time >= CAST(:start AS timestamptz)
              AND e.open_time < CAST(:end AS timestamptz)
              AND e.amplitude_percent IS NOT NULL
            ORDER BY e.open_time
        """
    else:
        source_sql = """
            SELECT e.open_time, e.close_price, rules.price_precision,
                   e.ema20, e.ema240,
                   k.base_volume, k.quote_volume,
                   e.amplitude_percent, oi.open_interest_value
            FROM market.kline_ema_indicators e
            JOIN market.klines k
              ON k.instrument_id = e.instrument_id
             AND k.price_type = e.price_type
             AND k.interval_seconds = e.interval_seconds
             AND k.open_time = e.open_time
             AND k.is_current
             AND k.is_closed
             AND k.quality_status = 'VALID'
            LEFT JOIN LATERAL (
                SELECT r.price_precision
                FROM core.instrument_rule_versions r
                WHERE r.instrument_id = e.instrument_id
                ORDER BY (r.effective_from <= e.open_time) DESC,
                         CASE WHEN r.effective_from <= e.open_time
                              THEN r.effective_from END DESC,
                         CASE WHEN r.effective_from > e.open_time
                              THEN r.effective_from END ASC
                LIMIT 1
            ) rules ON true
            LEFT JOIN LATERAL (
                SELECT o.open_interest_value
                FROM market.open_interest_observations o
                WHERE o.instrument_id = e.instrument_id
                  AND o.observed_at >= e.open_time
                  AND o.observed_at < e.open_time + interval '5 minutes'
                  AND o.quality_status IN ('VALID', 'PARTIAL')
                ORDER BY o.observed_at DESC
                LIMIT 1
            ) oi ON true
            WHERE e.instrument_id = :instrument_id
              AND e.price_type = 'TRADE'
              AND e.interval_seconds = :interval_seconds
              AND e.open_time >= CAST(:start AS timestamptz)
              AND e.open_time < CAST(:end AS timestamptz)
              AND e.amplitude_percent IS NOT NULL
            ORDER BY e.open_time
        """
    result = await connection.execute(
        text(source_sql),
        {
            "instrument_id": instrument_id,
            "interval_seconds": interval_seconds,
            "start": start,
            "end": end,
        },
    )
    return tuple(
        FeatureBar(
            open_time=cast(datetime, row["open_time"]),
            close_price=Decimal(str(row["close_price"])),
            price_precision=(
                int(row["price_precision"])
                if row["price_precision"] is not None
                else None
            ),
            ema20=Decimal(str(row["ema20"])),
            ema240=Decimal(str(row["ema240"])),
            base_volume=Decimal(str(row["base_volume"])),
            quote_volume=Decimal(str(row["quote_volume"])),
            amplitude_percent=Decimal(str(row["amplitude_percent"])),
            open_interest_value=(
                Decimal(str(row["open_interest_value"]))
                if row["open_interest_value"] is not None
                else None
            ),
        )
        for row in result.mappings()
    )


async def scan_database(
    engine: AsyncEngine,
    parameters: StrategyParameters,
    *,
    symbols: Sequence[str] | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
) -> tuple[StrategySignal, ...]:
    result = await scan_database_detailed(
        engine,
        parameters,
        symbols=symbols,
        start=start,
        end=end,
    )
    return result.signals


async def scan_database_detailed(
    engine: AsyncEngine,
    parameters: StrategyParameters,
    *,
    symbols: Sequence[str] | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
    max_signals: int | None = None,
    progress_callback: Callable[[int, int], None] | None = None,
    signals_callback: Callable[[tuple[StrategySignal, ...]], None] | None = None,
    evaluation_callback: Callable[[StrategyEvaluation], None] | None = None,
) -> DatabaseScanResult:
    scan_end = end or datetime.now(UTC)
    scan_end = scan_end.replace(tzinfo=UTC) if scan_end.tzinfo is None else scan_end.astimezone(UTC)
    scan_end = datetime.fromtimestamp(
        int(scan_end.timestamp()) // parameters.interval_seconds * parameters.interval_seconds,
        tz=UTC,
    )
    scan_start = start or (scan_end - timedelta(days=parameters.lookback_days))
    scan_start = (
        scan_start.replace(tzinfo=UTC)
        if scan_start.tzinfo is None
        else scan_start.astimezone(UTC)
    )
    if scan_start >= scan_end:
        raise ValueError("scan start must be earlier than scan end")
    query_start = scan_start - timedelta(
        seconds=parameters.warmup_bars * parameters.interval_seconds
    )
    signals: list[StrategySignal] = []
    scanned_instruments = 0
    truncated = False
    async with engine.connect() as connection:
        instruments = await _instrument_rows(
            connection, symbols, parameters.interval_seconds
        )
        for instrument in instruments:
            bars = await _load_feature_bars(
                connection,
                cast(int, instrument["instrument_id"]),
                query_start,
                scan_end,
                parameters.interval_seconds,
            )
            instrument_signals = evaluate_series(
                cast(str, instrument["symbol"]),
                bars,
                parameters,
                scan_start,
                evaluation_callback,
            )
            if max_signals is not None:
                remaining = max_signals - len(signals)
                emitted_signals = instrument_signals[: max(0, remaining)]
                signals.extend(emitted_signals)
                truncated = len(instrument_signals) > remaining
            else:
                emitted_signals = instrument_signals
                signals.extend(instrument_signals)
            if signals_callback is not None and emitted_signals:
                signals_callback(emitted_signals)
            scanned_instruments += 1
            if progress_callback is not None:
                progress_callback(scanned_instruments, len(instruments))
            if truncated or (max_signals is not None and len(signals) >= max_signals):
                truncated = scanned_instruments < len(instruments) or truncated
                break
    return DatabaseScanResult(
        signals=tuple(sorted(signals, key=lambda signal: (signal.open_time, signal.symbol))),
        scanned_instruments=scanned_instruments,
        total_instruments=len(instruments),
        truncated=truncated,
    )


def _serialize_value(value: Decimal | int | None) -> str | int | None:
    return str(value) if isinstance(value, Decimal) else value


def signal_record(signal: StrategySignal) -> dict[str, object]:
    record: dict[str, object] = {
        "symbol": signal.symbol,
        "open_time": signal.open_time.isoformat(),
        "close_price": str(signal.close_price),
    }
    for name in ALL_FACTORS:
        result = signal.factors[name]
        record[f"{name}_passed"] = result.passed
        record[f"{name}_value"] = _serialize_value(result.value)
        record[f"{name}_threshold"] = result.threshold
        record[f"{name}_reason"] = result.reason
    return record


def write_signals(signals: Sequence[StrategySignal], output: IO[str], output_format: str) -> None:
    records = [signal_record(signal) for signal in signals]
    if output_format == "jsonl":
        for record in records:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
        return
    fieldnames = (
        list(signal_record(signals[0]).keys())
        if signals
        else [
            "symbol",
            "open_time",
            "close_price",
        ]
    )
    writer = csv.DictWriter(output, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(records)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scan configurable 5m/15m momentum/OI/volume/amplitude factors"
    )
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--interval-seconds", type=int, choices=SUPPORTED_INTERVALS, default=900)
    parser.add_argument("--symbols", nargs="*")
    parser.add_argument("--end", type=datetime.fromisoformat)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--format", choices=("jsonl", "csv"), default="jsonl")
    parser.add_argument("--average-days", type=int, default=7)
    parser.add_argument("--ema-cross-bars", type=int, default=4)
    parser.add_argument("--price-window-bars", type=int, default=4)
    parser.add_argument("--price-rise-percent", type=Decimal, default=Decimal("3"))
    parser.add_argument("--oi-window-bars", type=int, default=4)
    parser.add_argument("--oi-rise-percent", type=Decimal, default=Decimal("5"))
    parser.add_argument("--volume-multiple", type=Decimal, default=Decimal("5"))
    parser.add_argument("--amplitude-multiple", type=Decimal, default=Decimal("5"))
    parser.add_argument("--amplitude-consecutive-bars", type=int, default=2)
    parser.add_argument("--average-amplitude-max-percent", type=Decimal, default=Decimal("2"))
    parser.add_argument(
        "--require-factor",
        action="append",
        choices=ALL_FACTORS,
        dest="required_factors",
        help="Repeat to require only selected factors; defaults to all six.",
    )
    return parser


async def _run(args: argparse.Namespace) -> int:
    required = tuple(args.required_factors) if args.required_factors else ALL_FACTORS
    parameters = StrategyParameters(
        interval_seconds=args.interval_seconds,
        lookback_days=args.days,
        average_days=args.average_days,
        ema_cross_lookback_bars=args.ema_cross_bars,
        rapid_price_window_bars=args.price_window_bars,
        rapid_price_rise_percent=args.price_rise_percent,
        open_interest_window_bars=args.oi_window_bars,
        open_interest_rise_percent=args.oi_rise_percent,
        volume_surge_multiple=args.volume_multiple,
        amplitude_spike_multiple=args.amplitude_multiple,
        amplitude_consecutive_bars=args.amplitude_consecutive_bars,
        average_amplitude_max_percent=args.average_amplitude_max_percent,
        required_factors=cast(tuple[FactorName, ...], required),
    )
    engine = create_database_engine(get_settings())
    try:
        signals = await scan_database(engine, parameters, symbols=args.symbols, end=args.end)
    finally:
        await engine.dispose()
    if args.output:
        with args.output.open("w", encoding="utf-8", newline="") as output:
            write_signals(signals, output, args.format)
    else:
        write_signals(signals, sys.stdout, args.format)
    print(
        json.dumps(
            {
                "signal_count": len(signals),
                "parameters": asdict(parameters),
            },
            ensure_ascii=False,
            default=str,
        ),
        file=sys.stderr,
    )
    return 0


def main() -> None:
    args = build_parser().parse_args()
    raise SystemExit(asyncio.run(_run(args)))


if __name__ == "__main__":
    main()
