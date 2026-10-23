from __future__ import annotations

import asyncio
import copy
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request

from auto_trade.accounts.models import CurrentUser
from auto_trade.accounts.repository import (
    AccountBalanceChangedError,
    AccountRepository,
)
from auto_trade.accounts.router import AuthenticatedUser
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
    PaperRiskUpdate,
    PaperSessionCreate,
    PaperSessionSnapshot,
)

router = APIRouter(prefix="/api/paper-trader", tags=["paper-trader"])
SUPPORTED_SYMBOLS = ("BTCUSDT", "ETHUSDT")
SUPPORTED_INTERVALS = (300, 900, 3600)
MAX_CANDLES = 3000


@dataclass(slots=True)
class UserPaperSession:
    user_id: UUID
    game: PaperSession
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


def _sessions(request: Request) -> dict[str, UserPaperSession]:
    return request.app.state.paper_trader_sessions  # type: ignore[no-any-return]


def _session(request: Request, session_id: str, user: CurrentUser) -> UserPaperSession:
    session = _sessions(request).get(session_id)
    if session is None or session.user_id != user.user_id:
        raise HTTPException(status_code=404, detail="paper trading session not found")
    return session


async def _mutate_session(
    request: Request,
    managed: UserPaperSession,
    operation: Callable[[PaperSession], PaperSessionSnapshot],
) -> PaperSessionSnapshot:
    async with managed.lock:
        current = managed.game
        candidate = copy.copy(current)
        candidate.trades = list(current.trades)
        previous_trade_count = len(current.trades)
        result = operation(candidate)
        new_trades = candidate.trades[previous_trade_count:]
        balance_before = current.balance
        repository = AccountRepository(request.app.state.database_engine)
        try:
            for trade in new_trades:
                balance_after = max(0.0, balance_before + trade.realized_pnl)
                await repository.record_trade(
                    user_id=managed.user_id,
                    session_id=candidate.session_id,
                    symbol=candidate.symbol,
                    interval_seconds=candidate.interval_seconds,
                    trade=trade,
                    balance_before=balance_before,
                    balance_after=balance_after,
                )
                balance_before = balance_after
        except AccountBalanceChangedError as error:
            raise HTTPException(
                status_code=409,
                detail="账户余额已在其他交易会话中变化, 请重新载入模拟行情",
            ) from error
        managed.game = candidate
        return result


@router.get("/metadata", response_model=PaperMetadata)
async def metadata(
    request: Request, _user: AuthenticatedUser
) -> PaperMetadata:
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
    payload: PaperSessionCreate,
    request: Request,
    user: AuthenticatedUser,
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
    account = await AccountRepository(request.app.state.database_engine).account_summary(
        user.user_id
    )
    session = PaperSession(
        symbol=symbol,
        interval_seconds=payload.interval_seconds,
        candles=candles,
        range_start=range_start,
        range_end=range_end,
        balance=account.balance,
    )
    sessions = _sessions(request)
    previous_session_ids = []
    for session_id, managed in sessions.items():
        if managed.user_id == user.user_id and managed.game.position is not None:
            raise HTTPException(status_code=409, detail="请先平掉当前模拟持仓再开始新一轮")
        if managed.user_id == user.user_id:
            previous_session_ids.append(session_id)
    for session_id in previous_session_ids:
        sessions.pop(session_id, None)
    if len(sessions) >= 100:
        sessions.pop(next(iter(sessions)))
    sessions[session.session_id] = UserPaperSession(user.user_id, session)
    return session.snapshot()


@router.post("/sessions/{session_id}/advance", response_model=PaperSessionSnapshot)
async def advance_session(
    session_id: str,
    request: Request,
    user: AuthenticatedUser,
) -> PaperSessionSnapshot:
    return await _mutate_session(
        request, _session(request, session_id, user), lambda game: game.advance()
    )


@router.post("/sessions/{session_id}/orders", response_model=PaperSessionSnapshot)
async def create_order(
    session_id: str,
    payload: PaperOrderCreate,
    request: Request,
    user: AuthenticatedUser,
) -> PaperSessionSnapshot:
    try:
        return await _mutate_session(
            request,
            _session(request, session_id, user),
            lambda game: game.open_position(
                payload.side,
                payload.notional,
                payload.leverage,
                payload.notional_unit,
            ),
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.post("/sessions/{session_id}/close", response_model=PaperSessionSnapshot)
async def close_position(
    session_id: str,
    request: Request,
    user: AuthenticatedUser,
) -> PaperSessionSnapshot:
    try:
        return await _mutate_session(
            request,
            _session(request, session_id, user),
            lambda game: game.close_position(),
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.put("/sessions/{session_id}/risk", response_model=PaperSessionSnapshot)
async def update_risk_orders(
    session_id: str,
    payload: PaperRiskUpdate,
    request: Request,
    user: AuthenticatedUser,
) -> PaperSessionSnapshot:
    try:
        return await _mutate_session(
            request,
            _session(request, session_id, user),
            lambda game: game.set_risk_orders(
                payload.take_profit_price,
                payload.stop_loss_price,
            ),
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        raise HTTPException(status_code=422, detail="time range must include a timezone")
    return value.astimezone(UTC)
