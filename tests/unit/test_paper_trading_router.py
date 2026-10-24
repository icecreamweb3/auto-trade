from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import uuid4

import pytest
from starlette.requests import Request

from auto_trade.accounts.models import AccountSummary, CurrentUser, UserRole
from auto_trade.paper_trading.engine import PaperSession
from auto_trade.paper_trading.models import GameStatus, PaperCandle
from auto_trade.paper_trading.router import UserPaperSession, active_session


def make_session(*, status: GameStatus = GameStatus.RUNNING) -> PaperSession:
    opened = datetime(2026, 1, 1, tzinfo=UTC)
    candles = tuple(
        PaperCandle(
            open_time=opened + timedelta(minutes=5 * index),
            close_time=opened + timedelta(minutes=5 * (index + 1)),
            open_price=100 + index,
            high_price=101 + index,
            low_price=99 + index,
            close_price=100 + index,
            base_volume=1,
            quote_volume=100,
        )
        for index in range(3)
    )
    return PaperSession(
        symbol="BTCUSDT",
        interval_seconds=300,
        candles=candles,
        range_start=candles[0].open_time,
        range_end=candles[-1].close_time,
        status=status,
        index=1,
    )


def make_user() -> CurrentUser:
    return CurrentUser(
        user_id=uuid4(),
        email="trader@example.com",
        role=UserRole.NORMAL,
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
        account=AccountSummary(
            starting_balance=1000,
            balance=1000,
            realized_pnl=0,
            trade_count=0,
        ),
    )


def make_request(sessions: dict[str, UserPaperSession]) -> Request:
    app = SimpleNamespace(
        state=SimpleNamespace(paper_trader_sessions=sessions),
    )
    return Request({"type": "http", "app": app})


@pytest.mark.asyncio
async def test_active_session_restores_only_current_users_unfinished_round() -> None:
    user = make_user()
    other_user = make_user()
    completed = make_session(status=GameStatus.COMPLETED)
    foreign = make_session()
    current = make_session()
    request = make_request(
        {
            completed.session_id: UserPaperSession(user.user_id, completed),
            foreign.session_id: UserPaperSession(other_user.user_id, foreign),
            current.session_id: UserPaperSession(user.user_id, current),
        }
    )

    state = await active_session(request, user)

    assert state is not None
    assert state.snapshot.session_id == current.session_id
    assert state.snapshot.revealed_count == 2
    assert len(state.candles) == 2


@pytest.mark.asyncio
async def test_active_session_returns_none_without_unfinished_round() -> None:
    user = make_user()
    completed = make_session(status=GameStatus.COMPLETED)
    request = make_request(
        {completed.session_id: UserPaperSession(user.user_id, completed)}
    )

    assert await active_session(request, user) is None
