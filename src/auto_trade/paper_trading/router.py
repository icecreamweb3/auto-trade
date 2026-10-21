from __future__ import annotations

from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, Request

from auto_trade.monitoring.repository import MonitoringRepository
from auto_trade.paper_trading.engine import (
    MAINTENANCE_MARGIN_RATE,
    STARTING_BALANCE,
    PaperSession,
)
from auto_trade.paper_trading.models import (
    PaperCandle,
    PaperMarketRange,
    PaperMetadata,
    PaperOrderCreate,
    PaperSessionCreate,
    PaperSessionSnapshot,
)

router = APIRouter(prefix="/api/paper-trader", tags=["paper-trader"])
SUPPORTED_SYMBOLS = ("BTCUSDT", "ETHUSDT")
SUPPORTED_INTERVALS = (300, 900, 3600)
MAX_CANDLES = 3000


def _sessions(request: Request) -> dict[str, PaperSession]:
    return request.app.state.paper_trader_sessions  # type: ignore[no-any-return]


def _session(request: Request, session_id: str) -> PaperSession:
    session = _sessions(request).get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="paper trading session not found")
    return session


@router.get("/metadata", response_model=PaperMetadata)
async def metadata(request: Request) -> PaperMetadata:
    repository = MonitoringRepository(request.app.state.database_engine)
    try:
        ranges = await repository.paper_trader_ranges(SUPPORTED_SYMBOLS)
    except Exception as error:
        raise HTTPException(status_code=503, detail="paper trading data unavailable") from error
    return PaperMetadata(
        starting_balance=STARTING_BALANCE,
        maximum_leverage=100,
        maintenance_margin_rate=MAINTENANCE_MARGIN_RATE,
        ranges=tuple(PaperMarketRange.model_validate(item) for item in ranges),
    )


@router.post("/sessions", response_model=PaperSessionSnapshot, status_code=201)
async def create_session(
    payload: PaperSessionCreate, request: Request
) -> PaperSessionSnapshot:
    symbol = payload.symbol.strip().upper()
    if symbol not in SUPPORTED_SYMBOLS:
        raise HTTPException(status_code=422, detail="symbol must be BTCUSDT or ETHUSDT")
    if payload.interval_seconds not in SUPPORTED_INTERVALS:
        raise HTTPException(status_code=422, detail="interval_seconds must be 300, 900 or 3600")
    range_start = _as_utc(payload.range_start)
    range_end = _as_utc(payload.range_end)
    if range_start >= range_end:
        raise HTTPException(status_code=422, detail="range_start must be before range_end")

    repository = MonitoringRepository(request.app.state.database_engine)
    try:
        rows = await repository.paper_trader_klines(
            symbol=symbol,
            range_start=range_start,
            range_end=range_end,
            interval_seconds=payload.interval_seconds,
            limit=MAX_CANDLES + 1,
        )
    except Exception as error:
        raise HTTPException(status_code=503, detail="paper trading data unavailable") from error
    if not rows:
        raise HTTPException(status_code=404, detail="所选时间范围没有可用 K 线")
    if len(rows) > MAX_CANDLES:
        raise HTTPException(status_code=422, detail=f"所选范围不能超过 {MAX_CANDLES} 根 K 线")

    candles = tuple(PaperCandle.model_validate(row) for row in rows)
    session = PaperSession(
        symbol=symbol,
        interval_seconds=payload.interval_seconds,
        candles=candles,
        range_start=range_start,
        range_end=range_end,
    )
    sessions = _sessions(request)
    if len(sessions) >= 100:
        sessions.pop(next(iter(sessions)))
    sessions[session.session_id] = session
    return session.snapshot()


@router.post("/sessions/{session_id}/advance", response_model=PaperSessionSnapshot)
async def advance_session(session_id: str, request: Request) -> PaperSessionSnapshot:
    return _session(request, session_id).advance()


@router.post("/sessions/{session_id}/orders", response_model=PaperSessionSnapshot)
async def create_order(
    session_id: str, payload: PaperOrderCreate, request: Request
) -> PaperSessionSnapshot:
    try:
        return _session(request, session_id).open_position(
            payload.side, payload.margin, payload.leverage
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.post("/sessions/{session_id}/close", response_model=PaperSessionSnapshot)
async def close_position(session_id: str, request: Request) -> PaperSessionSnapshot:
    try:
        return _session(request, session_id).close_position()
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        raise HTTPException(status_code=422, detail="time range must include a timezone")
    return value.astimezone(UTC)
