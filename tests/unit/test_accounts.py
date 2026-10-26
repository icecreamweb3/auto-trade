import json
from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from auto_trade.accounts.access import api_access_error
from auto_trade.accounts.models import (
    AccountSummary,
    Credentials,
    CurrentUser,
    LoginCredentials,
    PaperTraderPreferences,
    UserRole,
    normalize_email,
)
from auto_trade.accounts.repository import AccountRepository
from auto_trade.accounts.router import (
    paper_trader_preferences,
    require_admin,
    save_paper_trader_preferences,
)
from auto_trade.accounts.security import (
    hash_password,
    new_session_token,
    session_token_hash,
    verify_password,
)
from auto_trade.monitoring.app import enforce_user_access


def test_credentials_normalize_email_and_require_valid_address() -> None:
    credentials = Credentials(email="  Trader@Example.COM ", password="safe-pass-123")

    assert credentials.email == "trader@example.com"
    assert normalize_email(credentials.email) == credentials.email

    for invalid in ("missing-at.example.com", "name@localhost", "name @example.com"):
        try:
            Credentials(email=invalid, password="safe-pass-123")
        except ValidationError:
            pass
        else:
            raise AssertionError(f"invalid email accepted: {invalid}")


def test_password_hash_is_salted_and_verifiable() -> None:
    first = hash_password("safe-pass-123")
    second = hash_password("safe-pass-123")

    assert first != second
    assert "safe-pass-123" not in first
    assert verify_password("safe-pass-123", first)
    assert not verify_password("wrong-password", first)
    assert not verify_password("safe-pass-123", "invalid")


def test_session_token_hash_does_not_store_raw_token() -> None:
    token = new_session_token()
    digest = session_token_hash(token)

    assert token not in digest
    assert len(digest) == 64


def test_login_accepts_admin_username_as_identifier() -> None:
    credentials = LoginCredentials(identifier="  Admin  ", password="Admin@123")

    assert credentials.identifier == "Admin"


def test_paper_trader_preferences_have_per_user_display_defaults() -> None:
    preferences = PaperTraderPreferences()

    assert preferences.show_opening_range is True
    assert preferences.show_upper_opening_range is False
    assert preferences.show_lower_opening_range is False
    assert preferences.speed_seconds == 5
    assert preferences.auto_two_r_take_profit is True


def test_paper_trader_preferences_normalize_symbol_and_validate_range() -> None:
    preferences = PaperTraderPreferences(symbol=" btcusdt ")

    assert preferences.symbol == "BTCUSDT"
    with pytest.raises(ValidationError, match="必须同时设置"):
        PaperTraderPreferences(range_start=datetime.now(UTC))


async def test_paper_trader_preferences_are_saved_for_the_current_user() -> None:
    connection = MagicMock()
    connection.execute = AsyncMock()
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = AccountRepository(engine)
    user_id = uuid4()
    preferences = PaperTraderPreferences(
        show_opening_range=False,
        show_upper_opening_range=True,
    )

    saved = await repository.save_paper_trader_preferences(user_id, preferences)

    assert saved == preferences
    statement, parameters = connection.execute.await_args.args
    assert "ON CONFLICT (user_id) DO UPDATE" in str(statement)
    assert parameters["user_id"] == user_id
    payload = json.loads(parameters["paper_trader"])
    assert payload["show_opening_range"] is False
    assert payload["show_upper_opening_range"] is True


async def test_missing_paper_trader_preferences_return_defaults() -> None:
    result = MagicMock()
    result.scalar_one_or_none.return_value = None
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)

    preferences = await AccountRepository(engine).paper_trader_preferences(uuid4())

    assert preferences.show_opening_range is True
    assert preferences.show_upper_opening_range is False
    assert preferences.show_lower_opening_range is False


async def test_paper_round_is_persisted_and_updated() -> None:
    connection = MagicMock()
    connection.execute = AsyncMock()
    engine = MagicMock()
    engine.begin.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.begin.return_value.__aexit__ = AsyncMock(return_value=None)
    repository = AccountRepository(engine)
    user_id = uuid4()
    session_id = str(uuid4())
    range_start = datetime(2026, 1, 1, tzinfo=UTC)
    range_end = datetime(2026, 1, 2, tzinfo=UTC)

    await repository.record_paper_session(
        user_id=user_id,
        session_id=session_id,
        symbol="BTCUSDT",
        interval_seconds=300,
        range_start=range_start,
        range_end=range_end,
        starting_balance=1000,
        status="READY",
    )

    statement, parameters = connection.execute.await_args.args
    assert "INSERT INTO trade.paper_sessions" in str(statement)
    assert parameters["session_id"] == session_id
    assert parameters["starting_balance"] == 1000

    await repository.update_paper_session(
        session_id=session_id,
        ending_balance=1012.5,
        status="COMPLETED",
    )

    statement, parameters = connection.execute.await_args.args
    assert "UPDATE trade.paper_sessions" in str(statement)
    assert parameters == {
        "session_id": session_id,
        "ending_balance": 1012.5,
        "status": "COMPLETED",
        "completed": True,
    }


async def test_today_profit_ranking_uses_actual_record_time() -> None:
    result = MagicMock()
    result.mappings.return_value.all.return_value = []
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)

    ranking = await AccountRepository(engine)._profit_ranking(today_only=True)

    assert ranking == ()
    statement = str(connection.execute.await_args.args[0])
    assert "created_at >=" in statement
    assert "closed_at >=" not in statement
    assert "Asia/Shanghai" in statement


async def test_account_trades_apply_record_time_and_pnl_filters() -> None:
    result = MagicMock()
    result.mappings.return_value.all.return_value = []
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)
    recorded_from = datetime(2026, 10, 25, tzinfo=UTC)
    recorded_to = datetime(2026, 10, 26, tzinfo=UTC)

    trades = await AccountRepository(engine).trades(
        uuid4(),
        500,
        recorded_from=recorded_from,
        recorded_to=recorded_to,
        pnl_result="LOSS",
    )

    assert trades == ()
    statement, parameters = connection.execute.await_args.args
    query = str(statement)
    assert "t.created_at >= CAST(:recorded_from AS timestamptz)" in query
    assert "t.created_at < CAST(:recorded_to AS timestamptz)" in query
    assert "t.realized_pnl < 0" in query
    assert parameters["recorded_from"] == recorded_from
    assert parameters["recorded_to"] == recorded_to
    assert parameters["pnl_result"] == "LOSS"


def current_user(role: UserRole) -> CurrentUser:
    return CurrentUser(
        user_id=uuid4(),
        email="user@example.com",
        role=role,
        created_at=datetime.now(UTC),
        account=AccountSummary(
            starting_balance=1000,
            balance=1000,
            realized_pnl=0,
            trade_count=0,
        ),
    )


async def test_only_admin_role_passes_admin_dependency() -> None:
    admin = current_user(UserRole.ADMIN)

    assert await require_admin(admin) is admin
    with pytest.raises(HTTPException) as error:
        await require_admin(current_user(UserRole.ADVANCED))

    assert error.value.status_code == 403


async def test_paper_trader_preference_failures_return_json_http_errors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = current_user(UserRole.NORMAL)
    request = MagicMock()
    request.app.state.database_engine = MagicMock()
    monkeypatch.setattr(
        AccountRepository,
        "paper_trader_preferences",
        AsyncMock(side_effect=RuntimeError("database unavailable")),
    )
    monkeypatch.setattr(
        AccountRepository,
        "save_paper_trader_preferences",
        AsyncMock(side_effect=RuntimeError("database unavailable")),
    )

    with pytest.raises(HTTPException, match="交易偏好暂时不可用") as lookup_error:
        await paper_trader_preferences(request, user)
    with pytest.raises(HTTPException, match="交易偏好暂时无法保存") as save_error:
        await save_paper_trader_preferences(PaperTraderPreferences(), request, user)

    assert lookup_error.value.status_code == 503
    assert save_error.value.status_code == 503


async def test_authentication_database_failure_returns_json_503(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = MagicMock()
    request.url.path = "/api/paper-trader/metadata"
    request.cookies = {"auto_trade_session": "session-token"}
    request.app.state.database_engine = MagicMock()
    monkeypatch.setattr(
        AccountRepository,
        "current_user",
        AsyncMock(side_effect=RuntimeError("database unavailable")),
    )
    call_next = AsyncMock()

    response = await enforce_user_access(request, call_next)

    assert response.status_code == 503
    assert json.loads(response.body) == {"detail": "服务暂时不可用。请稍后重试"}
    call_next.assert_not_awaited()


@pytest.mark.parametrize(
    ("role", "path", "allowed"),
    (
        (UserRole.NORMAL, "/api/paper-trader/metadata", True),
        (UserRole.NORMAL, "/api/account/trades", True),
        (UserRole.NORMAL, "/api/account/analytics", True),
        (UserRole.NORMAL, "/api/account/preferences/paper-trader", True),
        (UserRole.NORMAL, "/api/rankings/daily", False),
        (UserRole.NORMAL, "/api/backtests/metadata", False),
        (UserRole.NORMAL, "/api/monitoring/overview", False),
        (UserRole.NORMAL, "/api/messages/channels", False),
        (UserRole.ADVANCED, "/api/rankings/daily", True),
        (UserRole.ADVANCED, "/api/messages/channels", True),
        (UserRole.ADVANCED, "/api/admin/users", False),
        (UserRole.ADMIN, "/api/admin/users", True),
    ),
)
def test_role_api_access_matrix(role: UserRole, path: str, allowed: bool) -> None:
    assert (api_access_error(role, path) is None) is allowed
