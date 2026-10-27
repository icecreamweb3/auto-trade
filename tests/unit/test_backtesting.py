from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest
from pydantic import ValidationError

import auto_trade.backtesting.service as backtest_service
from auto_trade.backtesting.models import (
    BacktestCreateRequest,
    BacktestParameters,
    BacktestStrategyWrite,
)
from auto_trade.backtesting.service import BacktestManager
from auto_trade.strategies.feature_scan import (
    ALL_FACTORS,
    DatabaseScanResult,
    FactorResult,
    StrategyEvaluation,
    StrategySignal,
)


def _request() -> BacktestCreateRequest:
    return BacktestCreateRequest(
        start_at=datetime(2026, 10, 1, tzinfo=UTC),
        end_at=datetime(2026, 10, 8, tzinfo=UTC),
        interval_seconds=300,
        symbols=("brusdt", "BRUSDT", " btcusdt "),
        parameters=BacktestParameters(required_factors=("rapid_price_rise",)),
    )


def test_request_normalizes_tickers_and_requires_aware_time() -> None:
    assert _request().symbols == ("BRUSDT", "BTCUSDT")
    assert _request().preserve_log_history is False
    assert BacktestParameters().required_factors == ALL_FACTORS
    assert sum(BacktestParameters().factor_weights.values()) == Decimal("100")

    with pytest.raises(ValidationError, match="timezone"):
        BacktestCreateRequest(
            start_at=datetime(2026, 10, 1),
            end_at=datetime(2026, 10, 2),
        )

    with pytest.raises(ValidationError, match="Input should be 300 or 900"):
        BacktestCreateRequest(
            start_at=datetime(2026, 10, 1, tzinfo=UTC),
            end_at=datetime(2026, 10, 2, tzinfo=UTC),
            interval_seconds=600,  # type: ignore[arg-type]
        )


def test_saved_strategy_normalizes_metadata_and_serializes_parameters() -> None:
    strategy = BacktestStrategyWrite(
        name="  BR 提前突破 v1  ",
        description="  连续强势阳线与 EMA 临近金叉  ",
        interval_seconds=900,
        parameters=BacktestParameters(
            single_bar_price_rise_percent=Decimal("3.25"),
            required_factors=("single_bar_price_rise", "ema_bullish_setup"),
        ),
    )

    assert strategy.name == "BR 提前突破 v1"
    assert strategy.description == "连续强势阳线与 EMA 临近金叉"
    assert strategy.parameters.single_bar_price_rise_saturation_percent == Decimal("4.875")
    assert strategy.parameters.factor_parameters["single_bar_price_rise"][
        "single_bar_price_rise_percent"
    ] == Decimal("3.25")
    values = BacktestManager._strategy_values(strategy)
    assert '"single_bar_price_rise_percent": "3.25"' in str(values["parameters"])
    assert '"required_factors": ["single_bar_price_rise", "ema_bullish_setup"]' in str(
        values["parameters"]
    )

    with pytest.raises(ValidationError, match="strategy name must not be blank"):
        BacktestStrategyWrite(name="   ")

    with pytest.raises(ValidationError, match="unknown factors"):
        BacktestParameters(required_factors=("future_factor_without_registration",))

    with pytest.raises(ValidationError, match="unknown parameters"):
        BacktestParameters(
            factor_parameters={"rapid_price_rise": {"unknown_parameter": Decimal("1")}}
        )


async def test_metadata_reads_only_first_and_last_timescale_chunks() -> None:
    first_5m = datetime(2020, 4, 1, tzinfo=UTC)
    last_5m = datetime(2026, 10, 22, tzinfo=UTC)
    first_15m = datetime(2020, 3, 26, tzinfo=UTC)
    last_15m = datetime(2026, 10, 15, tzinfo=UTC)
    chunk_result = MagicMock()
    chunk_result.mappings.return_value.all.return_value = [
        {
            "hypertable_name": "klines",
            "edge": "FIRST",
            "range_start": first_5m,
            "range_end": first_5m + timedelta(days=1),
        },
        {
            "hypertable_name": "klines",
            "edge": "LAST",
            "range_start": last_5m,
            "range_end": last_5m + timedelta(days=1),
        },
        {
            "hypertable_name": "klines_15m",
            "edge": "FIRST",
            "range_start": first_15m,
            "range_end": first_15m + timedelta(days=7),
        },
        {
            "hypertable_name": "klines_15m",
            "edge": "LAST",
            "range_start": last_15m,
            "range_end": last_15m + timedelta(days=7),
        },
    ]

    def bounds_result(available_from: datetime, available_to: datetime) -> MagicMock:
        result = MagicMock()
        result.mappings.return_value.one.return_value = {
            "available_from": available_from,
            "available_to": available_to,
        }
        return result

    def symbols_result(*symbols: str) -> MagicMock:
        result = MagicMock()
        result.scalars.return_value.all.return_value = list(symbols)
        return result

    connection = MagicMock()
    connection.execute = AsyncMock(
        side_effect=(
            MagicMock(),
            chunk_result,
            bounds_result(first_5m, last_5m),
            symbols_result("BTCUSDT", "ETHUSDT"),
            bounds_result(first_15m, last_15m),
            symbols_result("BTCUSDT"),
        )
    )
    context = AsyncMock()
    context.__aenter__.return_value = connection
    engine = MagicMock()
    engine.connect.return_value = context

    metadata = await BacktestManager(engine).metadata()

    assert metadata.intervals["300"].symbols == ("BTCUSDT", "ETHUSDT")
    assert metadata.intervals["900"].symbols == ("BTCUSDT",)
    assert len(metadata.factors) == len(ALL_FACTORS)
    rapid = next(factor for factor in metadata.factors if factor.name == "rapid_price_rise")
    assert rapid.label == "价格快速拉升"
    assert rapid.default_weight == 10
    assert {parameter.key for parameter in rapid.parameters} == {
        "rapid_price_window_bars",
        "rapid_price_rise_percent",
        "rapid_price_rise_saturation_percent",
    }
    calls = connection.execute.await_args_list
    assert "force_custom_plan" in str(calls[0].args[0])
    assert "timescaledb_information.chunks" in str(calls[1].args[0])
    for call in calls[2:]:
        statement = str(call.args[0])
        assert "CAST(:last_start AS timestamptz)" in statement
        assert "CAST(:last_end AS timestamptz)" in statement


async def test_manager_runs_scan_and_exposes_progress(monkeypatch: pytest.MonkeyPatch) -> None:
    request = _request()
    signal = StrategySignal(
        symbol="BRUSDT",
        open_time=datetime(2026, 10, 3, 1, tzinfo=UTC),
        close_price=Decimal("0.1234"),
        factors={
            name: FactorResult(
                passed=name == "rapid_price_rise",
                value=Decimal("4.2") if name == "rapid_price_rise" else None,
                threshold="test",
                metrics={"window_bars": 4} if name == "rapid_price_rise" else {},
                score=Decimal("88") if name == "rapid_price_rise" else Decimal(0),
                weight=Decimal("10") if name == "rapid_price_rise" else Decimal(0),
                contribution=(Decimal("8.8") if name == "rapid_price_rise" else Decimal(0)),
            )
            for name in ALL_FACTORS
        },
        score=Decimal("78.5"),
        grade="A",
        coverage_percent=Decimal("90"),
        trigger_reason="窗口涨幅",
        group_scores={"price_action": Decimal("82")},
        risk_flags=("单根涨幅过热",),
    )
    received: dict[str, Any] = {}

    async def fake_scan(*args: Any, **kwargs: Any) -> DatabaseScanResult:
        received.update(kwargs)
        received["parameters"] = args[1]
        kwargs["progress_callback"](1, 2)
        kwargs["progress_callback"](2, 2)
        return DatabaseScanResult((signal,), 2, 2)

    monkeypatch.setattr(backtest_service, "scan_database_detailed", fake_scan)
    manager = BacktestManager(None)  # type: ignore[arg-type]

    job = manager.create(request)
    assert job.task is not None
    await job.task
    response = manager.response(job)

    assert response.status == "COMPLETED"
    assert response.scanned_instruments == 2
    assert response.total_instruments == 2
    assert response.signal_count == 1
    assert response.signals[0].factors["rapid_price_rise"].value == pytest.approx(4.2)
    assert response.signals[0].score == pytest.approx(78.5)
    assert response.signals[0].grade == "A"
    assert response.signals[0].coverage_percent == pytest.approx(90)
    assert response.signals[0].trigger_reason == "窗口涨幅"
    assert response.signals[0].group_scores == {"price_action": 82.0}
    assert response.signals[0].risk_flags == ("单根涨幅过热",)
    rapid = response.signals[0].factors["rapid_price_rise"]
    assert rapid.score == pytest.approx(88)
    assert rapid.weight == pytest.approx(10)
    assert rapid.contribution == pytest.approx(8.8)
    assert rapid.metrics == {"window_bars": 4}
    assert received["symbols"] == ("BRUSDT", "BTCUSDT")
    assert received["start"] == request.start_at
    assert received["end"] == request.end_at
    assert received["parameters"].interval_seconds == 300
    assert received["parameters"].bullish_sequence_bars == 2
    assert received["parameters"].volume_acceleration_average_bars == 20
    assert received["parameters"].ema_near_cross_gap_percent == Decimal("1")
    assert received["parameters"].factor_parameters["rapid_price_rise"][
        "rapid_price_window_bars"
    ] == Decimal("4")
    assert response.log_available is False


async def test_optional_html_log_is_generated_and_resolvable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    request = _request().model_copy(update={"generate_log": True})
    factors = {
        name: FactorResult(
            passed=name == "rapid_price_rise",
            value=(
                Decimal("4.2")
                if name == "rapid_price_rise"
                else Decimal("0.07633334544580432043302834212")
                if name == "volume_surge"
                else Decimal("0.3294036146087840013440172645")
                if name == "amplitude_spike_streak"
                else None
            ),
            threshold="test threshold",
            reason=None if name == "rapid_price_rise" else "not matched",
        )
        for name in ALL_FACTORS
    }
    evaluation = StrategyEvaluation(
        symbol="BRUSDT",
        bar_number=37,
        open_time=datetime(2026, 10, 3, 1, tzinfo=UTC),
        close_price=Decimal("108749.60"),
        price_precision=2,
        ema20=Decimal("108700.1234"),
        ema240=Decimal("108650.5678"),
        base_volume=Decimal("18788.707"),
        quote_volume=Decimal("2043370000"),
        factors=factors,
        matched=True,
    )

    async def fake_scan(*args: Any, **kwargs: Any) -> DatabaseScanResult:
        kwargs["evaluation_callback"](evaluation)
        kwargs["progress_callback"](1, 1)
        return DatabaseScanResult((), 1, 1)

    monkeypatch.setattr(backtest_service, "scan_database_detailed", fake_scan)
    manager = BacktestManager(None, tmp_path)  # type: ignore[arg-type]

    job = manager.create(request)
    assert job.task is not None
    await job.task
    response = manager.response(job)

    assert response.log_available is True
    assert response.log_line_count == 1
    assert response.log_url == f"/api/backtests/logs/backtest-{job.job_id}.html"
    assert response.log_url is not None
    path = manager.resolve_log(response.log_url.rsplit("/", 1)[-1])
    assert path is not None
    html = path.read_text(encoding="utf-8")
    assert "<!doctype html>" in html
    assert "overflow-x: auto" in html
    assert "white-space: pre; overflow-wrap: normal" in html
    assert "🚀 BRUSDT | 5min | K线 #37" in html
    assert "2026-10-03 09:00:00" in html
    assert "2026-10-03T09:00:00" not in html
    assert "收盘价: 108749.60" in html
    assert "EMA20: 108700.12 | EMA240: 108650.57" in html
    assert "成交量: 18788.71" in html
    assert "成交额: 2043370000.00" in html
    assert "总分: 0.00 (弱)" in html
    assert "覆盖率: 0.00%" in html
    assert "实际值: 4.20%" in html
    assert "成交量暴涨: " in html and "实际值: 0.08x" in html
    assert "连续振幅异常: " in html and "实际值: 0.33x" in html
    assert '<span class="pass">✓</span>' in html
    assert "test threshold" in html
    assert "</html>" in html


async def test_new_backtest_deletes_previous_log_by_default(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    async def fake_scan(*args: Any, **kwargs: Any) -> DatabaseScanResult:
        kwargs["progress_callback"](1, 1)
        return DatabaseScanResult((), 1, 1)

    monkeypatch.setattr(backtest_service, "scan_database_detailed", fake_scan)
    manager = BacktestManager(None, tmp_path)  # type: ignore[arg-type]
    first = manager.create(_request().model_copy(update={"generate_log": True}))
    assert first.task is not None
    await first.task
    first_path = first.log_path
    assert first_path is not None and first_path.is_file()

    second = manager.create(_request())
    assert not first_path.exists()
    assert manager.response(first).log_available is False
    assert second.task is not None
    await second.task


async def test_preserve_log_history_keeps_previous_log(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    async def fake_scan(*args: Any, **kwargs: Any) -> DatabaseScanResult:
        kwargs["progress_callback"](1, 1)
        return DatabaseScanResult((), 1, 1)

    monkeypatch.setattr(backtest_service, "scan_database_detailed", fake_scan)
    manager = BacktestManager(None, tmp_path)  # type: ignore[arg-type]
    first = manager.create(_request().model_copy(update={"generate_log": True}))
    assert first.task is not None
    await first.task
    first_path = first.log_path
    assert first_path is not None and first_path.is_file()

    second = manager.create(_request().model_copy(update={"preserve_log_history": True}))
    assert first_path.is_file()
    assert manager.response(first).log_available is True
    assert second.task is not None
    await second.task
