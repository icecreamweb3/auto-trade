from __future__ import annotations

import asyncio
import copy
import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from math import ceil
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
    MAKER_FEE_RATE,
    STARTING_BALANCE,
    TAKER_FEE_RATE,
    PaperSession,
    utc8_price_anchor,
)
from auto_trade.paper_trading.models import (
    GameStatus,
    PaperCandle,
    PaperChartView,
    PaperCloseOrderCreate,
    PaperMarketRange,
    PaperMetadata,
    PaperOrderCreate,
    PaperOrderType,
    PaperRiskUpdate,
    PaperSessionCreate,
    PaperSessionSnapshot,
    PaperSessionState,
)

router = APIRouter(prefix="/api/paper-trader", tags=["paper-trader"])
logger = logging.getLogger(__name__)
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


def _session_creations(request: Request) -> set[UUID]:
    return request.app.state.paper_trader_session_creations  # type: ignore[no-any-return]


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
        candidate.position = copy.copy(current.position)
        candidate.pending_open_order = copy.copy(current.pending_open_order)
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
        maker_fee_rate=MAKER_FEE_RATE,
        taker_fee_rate=TAKER_FEE_RATE,
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

    creations = _session_creations(request)
    if user.user_id in creations:
        raise HTTPException(status_code=409, detail="模拟行情正在生成, 请稍候")
    creations.add(user.user_id)
    try:
        return await _create_session(
            payload,
            request,
            user,
            symbol,
            range_start,
            range_end,
        )
    finally:
        creations.discard(user.user_id)


@router.get("/sessions/active", response_model=PaperSessionState | None)
async def active_session(
    request: Request,
    user: AuthenticatedUser,
) -> PaperSessionState | None:
    managed = next(
        (
            session
            for session in _sessions(request).values()
            if session.user_id == user.user_id
            and session.game.status in (GameStatus.READY, GameStatus.RUNNING)
        ),
        None,
    )
    if managed is None:
        return None
    async with managed.lock:
        return managed.game.state()


@router.put(
    "/sessions/{session_id}/chart-view",
    response_model=PaperChartView,
)
async def save_chart_view(
    session_id: str,
    payload: PaperChartView,
    request: Request,
    user: AuthenticatedUser,
) -> PaperChartView:
    managed = _session(request, session_id, user)
    async with managed.lock:
        managed.game.chart_view = payload
    return payload


async def _create_session(
    payload: PaperSessionCreate,
    request: Request,
    user: CurrentUser,
    symbol: str,
    range_start: datetime,
    range_end: datetime,
) -> PaperSessionSnapshot:

    repository = MonitoringRepository(request.app.state.database_engine)
    warmup_start = range_start - timedelta(seconds=payload.warmup_seconds)
    warmup_limit = ceil(payload.warmup_seconds / payload.interval_seconds)
    try:
        rows = await repository.paper_trader_klines(
            symbol=symbol,
            range_start=warmup_start,
            range_end=range_end,
            interval_seconds=payload.interval_seconds,
            limit=MAX_CANDLES + warmup_limit + 1,
        )
    except Exception as error:
        logger.exception(
            "paper replay candle query failed symbol=%s interval=%s start=%s end=%s",
            symbol,
            payload.interval_seconds,
            range_start,
            range_end,
        )
        raise HTTPException(status_code=503, detail="paper trading data unavailable") from error
    warmup_rows = tuple(row for row in rows if row.open_time < range_start)
    visible_rows = tuple(row for row in rows if row.open_time >= range_start)
    warmup_candles = tuple(PaperCandle.model_validate(row) for row in warmup_rows)
    warmup_ema_values = tuple(
        (
            row.ema20 if row.ema20 > 0 else None,
            row.ema240 if row.ema240 > 0 else None,
        )
        for row in warmup_rows
    )
    candles = tuple(PaperCandle.model_validate(row) for row in visible_rows)
    ema_values = tuple(
        (
            row.ema20 if row.ema20 > 0 else None,
            row.ema240 if row.ema240 > 0 else None,
        )
        for row in visible_rows
    )
    if not candles:
        raise HTTPException(status_code=404, detail="所选时间范围没有可用 K 线")
    if len(candles) > MAX_CANDLES:
        raise HTTPException(status_code=422, detail=f"所选范围不能超过 {MAX_CANDLES} 根 K 线")

    lookback_candles: tuple[PaperCandle, ...] = warmup_candles
    anchor_time = utc8_price_anchor(range_start)
    reference_start = anchor_time - timedelta(seconds=payload.interval_seconds)
    reference_end = anchor_time + timedelta(seconds=payload.interval_seconds)
    if anchor_time < range_start and not any(
        candle.open_time == anchor_time for candle in lookback_candles
    ):
        try:
            reference_rows = await repository.paper_trader_klines(
                symbol=symbol,
                range_start=reference_start,
                range_end=reference_end,
                interval_seconds=payload.interval_seconds,
                limit=2,
            )
            lookback_candles += tuple(
                PaperCandle.model_validate(row) for row in reference_rows
            )
        except Exception:
            logger.warning(
                "paper replay UTC+8 anchor query failed; continuing without anchored change "
                "symbol=%s interval=%s start=%s end=%s",
                symbol,
                payload.interval_seconds,
                reference_start,
                reference_end,
                exc_info=True,
            )

    account = await AccountRepository(request.app.state.database_engine).account_summary(
        user.user_id
    )
    session = PaperSession(
        symbol=symbol,
        interval_seconds=payload.interval_seconds,
        candles=candles,
        range_start=range_start,
        range_end=range_end,
        warmup_seconds=payload.warmup_seconds,
        warmup_candles=warmup_candles,
        warmup_ema_values=warmup_ema_values,
        lookback_candles=lookback_candles,
        ema_values=ema_values,
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
            lambda game: (
                game.place_limit_open_order(
                    payload.side,
                    payload.notional,
                    payload.leverage,
                    payload.price,
                    payload.notional_unit,
                )
                if payload.order_type is PaperOrderType.LIMIT and payload.price is not None
                else game.place_stop_open_order(
                    payload.side,
                    payload.notional,
                    payload.leverage,
                    payload.price,
                    payload.notional_unit,
                    payload.take_profit_price,
                    payload.stop_loss_price,
                )
                if payload.order_type is PaperOrderType.STOP_MARKET
                and payload.price is not None
                else game.open_position(
                    payload.side,
                    payload.notional,
                    payload.leverage,
                    payload.notional_unit,
                )
            ),
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.delete(
    "/sessions/{session_id}/orders/{order_id}",
    response_model=PaperSessionSnapshot,
)
async def cancel_order(
    session_id: str,
    order_id: str,
    request: Request,
    user: AuthenticatedUser,
) -> PaperSessionSnapshot:
    try:
        return await _mutate_session(
            request,
            _session(request, session_id, user),
            lambda game: game.cancel_order(order_id),
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.post("/sessions/{session_id}/close", response_model=PaperSessionSnapshot)
async def close_position(
    session_id: str,
    request: Request,
    user: AuthenticatedUser,
    payload: PaperCloseOrderCreate | None = None,
) -> PaperSessionSnapshot:
    try:
        return await _mutate_session(
            request,
            _session(request, session_id, user),
            lambda game: (
                game.place_limit_close_order(
                    price=payload.price,
                    quantity=payload.quantity,
                )
                if payload is not None
                and payload.order_type is PaperOrderType.LIMIT
                and payload.price is not None
                else game.close_position(
                    quantity=payload.quantity if payload is not None else None
                )
            ),
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
                payload.take_profit_quantity,
            ),
        )
    except ValueError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        raise HTTPException(status_code=422, detail="time range must include a timezone")
    return value.astimezone(UTC)
