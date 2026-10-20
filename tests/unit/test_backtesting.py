from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

import auto_trade.backtesting.service as backtest_service
from auto_trade.backtesting.models import BacktestCreateRequest, BacktestParameters
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
            )
            for name in ALL_FACTORS
        },
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
    assert received["symbols"] == ("BRUSDT", "BTCUSDT")
    assert received["start"] == request.start_at
    assert received["end"] == request.end_at
    assert received["parameters"].interval_seconds == 300
    assert response.log_available is False


async def test_optional_html_log_is_generated_and_resolvable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    request = _request().model_copy(update={"generate_log": True})
    factors = {
        name: FactorResult(
            passed=name == "rapid_price_rise",
            value=Decimal("4.2") if name == "rapid_price_rise" else None,
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
    assert "🚀 BRUSDT | 5min | K线 #37" in html
    assert '<span class="pass">✓</span>' in html
    assert "test threshold" in html
    assert "</html>" in html
