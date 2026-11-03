from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from auto_trade.strategies.feature_scan import (
    FactorResult,
    FeatureBar,
    StrategyEvaluation,
    StrategySignal,
)
from auto_trade.training.model_a_candidate_scan_repository import (
    BenchmarkBar,
    CandidateScanContext,
    PoolEvaluation,
    RandomBaselineConfig,
    ScanInstrument,
)
from auto_trade.training.model_a_candidate_scan_task_handler import (
    ModelACandidateScanError,
    ModelACandidateScanTaskHandler,
    build_candidate_strategy_parameters,
)
from auto_trade.training.orchestrator import ExecutorKind, TaskLease


def _context(**overrides: object) -> CandidateScanContext:
    values: dict[str, object] = {
        "iteration_id": uuid4(),
        "dataset_version_id": uuid4(),
        "interval_seconds": 300,
        "eligible_start_at": datetime(2026, 8, 1, tzinfo=UTC),
        "eligible_end_at": datetime(2026, 8, 2, tzinfo=UTC),
        "ticker_pool_rule_version_id": uuid4(),
        "factor_registry_version_id": uuid4(),
        "factor_registry_config": {
            "adapter_version": "v2",
            "factors": ["single_bar_price_rise"],
        },
        "scan_parameters_version_id": uuid4(),
        "scan_parameters_config": {
            "interval_seconds": 300,
            "strategy_parameters": {
                "required_factors": ["single_bar_price_rise"],
                "factor_weights": {"single_bar_price_rise": "1"},
            },
        },
        "candidate_parameters": {"signal_score_threshold": 70},
        "dataset_root_fingerprint": "a" * 64,
        "maximum_signal_count": 10,
        "existing_batch_hash": None,
    }
    values.update(overrides)
    return CandidateScanContext(**values)  # type: ignore[arg-type]


def _bar(open_time: datetime, open_price: str) -> FeatureBar:
    price = Decimal(open_price)
    return FeatureBar(
        open_time=open_time,
        open_price=price,
        high_price=price + 1,
        low_price=price - 1,
        close_price=price,
        price_precision=2,
        ema20=price,
        ema240=price,
        base_volume=Decimal("1"),
        quote_volume=Decimal("100"),
        amplitude_percent=Decimal("2"),
        open_interest_value=Decimal("1000"),
    )


def test_candidate_parameters_are_merged_with_frozen_registry() -> None:
    parameters = build_candidate_strategy_parameters(_context())

    assert parameters.interval_seconds == 300
    assert parameters.required_factors == ("single_bar_price_rise",)
    assert parameters.factor_weights["single_bar_price_rise"] == Decimal("1")
    assert parameters.signal_score_threshold == Decimal("70")


def test_candidate_scan_rejects_unknown_or_non_5m_parameters() -> None:
    with pytest.raises(ModelACandidateScanError, match="unsupported"):
        build_candidate_strategy_parameters(
            _context(candidate_parameters={"future_label_threshold": 1})
        )
    with pytest.raises(ModelACandidateScanError, match="5m"):
        build_candidate_strategy_parameters(_context(interval_seconds=900))


async def test_candidate_scan_persists_entries_and_freezes_batch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    context = _context()
    signal_time = context.eligible_start_at
    bars = (
        _bar(signal_time - timedelta(minutes=10), "98"),
        _bar(signal_time - timedelta(minutes=5), "99"),
        _bar(signal_time, "100"),
        _bar(signal_time + timedelta(minutes=5), "101"),
    )
    factor = FactorResult(
        passed=True,
        value=Decimal("1"),
        threshold="test",
        score=Decimal("80"),
        weight=Decimal("1"),
        contribution=Decimal("80"),
    )
    signal = StrategySignal(
        symbol="BTCUSDT",
        open_time=signal_time,
        close_price=Decimal("100"),
        factors={"single_bar_price_rise": factor},
        score=Decimal("80"),
        coverage_percent=Decimal("100"),
    )
    evaluation = StrategyEvaluation(
        symbol="BTCUSDT",
        bar_number=1,
        open_time=signal_time,
        close_price=Decimal("100"),
        price_precision=2,
        ema20=Decimal("100"),
        ema240=Decimal("100"),
        base_volume=Decimal("1"),
        quote_volume=Decimal("100"),
        factors={"single_bar_price_rise": factor},
        matched=True,
        candidate_triggered=True,
        trigger_reason="test",
        score=Decimal("80"),
        coverage_percent=Decimal("100"),
    )
    def evaluate(*_args: object, **kwargs: object) -> tuple[StrategySignal, ...]:
        kwargs["evaluation_callback"](evaluation)  # type: ignore[operator]
        return (signal,)

    monkeypatch.setattr(
        "auto_trade.training.model_a_candidate_scan_task_handler.evaluate_series", evaluate
    )
    handler = ModelACandidateScanTaskHandler(MagicMock())
    handler._store.load_context = AsyncMock(return_value=context)
    handler._store.load_instruments = AsyncMock(
        return_value=(ScanInstrument(1, "BTCUSDT"),)
    )
    handler._store.load_bars = AsyncMock(return_value=bars)
    handler._store.load_pool_evaluations = AsyncMock(
        return_value=(PoolEvaluation(uuid4(), signal_time),)
    )
    handler._store.load_random_baseline_config = AsyncMock(
        return_value=RandomBaselineConfig(
            uuid4(),
            {
                "maximum_frame_candidates": 100,
                "stratification": {
                    "benchmark_symbol": "BTCUSDT",
                    "volatility_measure": "CLOSE_RETURN_STDDEV_PERCENT",
                    "volatility_window_bars": 1,
                    "volatility_boundaries_percent": [1],
                    "liquidity_measure": "MEAN_QUOTE_VOLUME",
                    "liquidity_window_bars": 1,
                    "liquidity_boundaries_quote_volume": [1000],
                    "btc_regime_measure": "CLOSE_RETURN_PERCENT",
                    "btc_regime_window_bars": 1,
                    "btc_return_boundaries_percent": [0],
                },
            },
        )
    )
    handler._store.load_benchmark_bars = AsyncMock(
        return_value=(
            BenchmarkBar(signal_time - timedelta(minutes=10), Decimal("98")),
            BenchmarkBar(signal_time - timedelta(minutes=5), Decimal("99")),
        )
    )
    handler._store.record_signal_stratum = AsyncMock()
    handler._store.record_random_candidate = AsyncMock()
    handler._store.freeze_batch = AsyncMock(return_value="b" * 64)
    handler._feature_store.record_candidate_signal = AsyncMock(return_value="c" * 64)
    lease = TaskLease(
        uuid4(),
        ExecutorKind.WORKER,
        uuid4(),
        1,
        datetime.now(UTC) + timedelta(minutes=5),
        0,
        {"task_type": "MODEL_A_CANDIDATE_SCAN", "payload_version": 1},
    )

    assert await handler(lease) == "b" * 64
    adapted = handler._feature_store.record_candidate_signal.await_args.args[0]
    assert adapted.event.source.value == "IN_SAMPLE_MODEL_A"
    assert adapted.event.entry_price == Decimal("101")
    handler._store.record_signal_stratum.assert_awaited_once()
    handler._store.record_random_candidate.assert_not_awaited()
    handler._store.freeze_batch.assert_awaited_once()


async def test_existing_batch_is_idempotently_reused() -> None:
    handler = ModelACandidateScanTaskHandler(MagicMock())
    handler._store.load_context = AsyncMock(
        return_value=_context(existing_batch_hash="d" * 64)
    )
    handler._store.load_instruments = AsyncMock()
    lease = TaskLease(
        uuid4(), ExecutorKind.WORKER, uuid4(), 1,
        datetime.now(UTC) + timedelta(minutes=5), 0,
        {"task_type": "MODEL_A_CANDIDATE_SCAN", "payload_version": 1},
    )

    assert await handler(lease) == "d" * 64
    handler._store.load_instruments.assert_not_called()
