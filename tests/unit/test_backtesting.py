from datetime import UTC, datetime
from decimal import Decimal
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
