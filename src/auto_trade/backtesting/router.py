from __future__ import annotations

from datetime import datetime
from typing import cast

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import FileResponse

from auto_trade.backtesting.models import (
    BacktestCreated,
    BacktestCreateRequest,
    BacktestJobResult,
    BacktestKlineResult,
    BacktestMetadata,
)
from auto_trade.backtesting.service import BacktestManager

router = APIRouter(prefix="/api/backtests", tags=["backtests"])


def _manager(request: Request) -> BacktestManager:
    return cast(BacktestManager, request.app.state.backtest_manager)


@router.get("/metadata", response_model=BacktestMetadata)
async def metadata(request: Request) -> BacktestMetadata:
    try:
        return await _manager(request).metadata()
    except Exception as error:
        raise HTTPException(status_code=503, detail="backtest metadata unavailable") from error


@router.post("", response_model=BacktestCreated, status_code=202)
async def create_backtest(
    body: BacktestCreateRequest, request: Request
) -> BacktestCreated:
    try:
        job = _manager(request).create(body)
    except RuntimeError as error:
        raise HTTPException(
            status_code=429, detail="too many backtests are already running"
        ) from error
    return BacktestCreated(job_id=job.job_id, status=job.status)


@router.get("/klines", response_model=BacktestKlineResult)
async def signal_klines(
    request: Request,
    signal_time: datetime,
    symbol: str = Query(min_length=1, max_length=32),
    interval_seconds: int = Query(default=900),
    before_bars: int = Query(default=80, ge=20, le=300),
    after_bars: int = Query(default=40, ge=10, le=200),
) -> BacktestKlineResult:
    normalized_symbol = symbol.strip().upper()
    if not normalized_symbol:
        raise HTTPException(status_code=422, detail="symbol must not be blank")
    if interval_seconds not in (300, 900):
        raise HTTPException(status_code=422, detail="interval_seconds must be 300 or 900")
    try:
        result = await _manager(request).signal_klines(
            symbol=normalized_symbol,
            signal_time=signal_time,
            interval_seconds=interval_seconds,
            before_bars=before_bars,
            after_bars=after_bars,
        )
    except Exception as error:
        raise HTTPException(status_code=503, detail="signal kline data unavailable") from error
    if not result.items:
        raise HTTPException(status_code=404, detail="no kline data around signal")
    return result


@router.get("/logs/{filename}", response_class=FileResponse)
async def view_backtest_log(filename: str, request: Request) -> FileResponse:
    path = _manager(request).resolve_log(filename)
    if path is None:
        raise HTTPException(status_code=404, detail="backtest log not found")
    return FileResponse(
        path,
        media_type="text/html; charset=utf-8",
        headers={
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.get("/{job_id}", response_model=BacktestJobResult)
async def get_backtest(job_id: str, request: Request) -> BacktestJobResult:
    job = _manager(request).get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="backtest job not found")
    return _manager(request).response(job)
