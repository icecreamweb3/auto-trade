from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy.exc import SQLAlchemyError

from auto_trade.accounts.models import AccountSummary, CurrentUser, UserRole
from auto_trade.training.workspace import require_training_researcher


def _user(role: UserRole = UserRole.ADMIN) -> CurrentUser:
    return CurrentUser(
        user_id=uuid4(),
        email="researcher@example.com",
        role=role,
        created_at=datetime.now(UTC),
        account=AccountSummary(
            starting_balance=1000,
            balance=1000,
            realized_pnl=0,
            trade_count=0,
        ),
    )


def _request_with_result(value: bool) -> tuple[MagicMock, MagicMock]:
    result = MagicMock()
    result.scalar_one.return_value = value
    connection = MagicMock()
    connection.execute = AsyncMock(return_value=result)
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)
    request = MagicMock()
    request.app.state.database_engine = engine
    return request, connection


async def test_explicit_active_training_researcher_grant_is_required() -> None:
    user = _user(UserRole.NORMAL)
    request, connection = _request_with_result(True)

    assert await require_training_researcher(request, user) is user
    statement, parameters = connection.execute.await_args.args
    query = str(statement)
    assert "TRAINING_RESEARCHER" in query
    assert "expires_at > clock_timestamp()" in query
    assert "revocation.grant_id IS NULL" in query
    assert parameters == {"user_id": user.user_id}


async def test_admin_without_training_grant_is_rejected() -> None:
    request, _connection = _request_with_result(False)

    with pytest.raises(HTTPException, match="TRAINING_RESEARCHER") as error:
        await require_training_researcher(request, _user(UserRole.ADMIN))

    assert error.value.status_code == 403


async def test_training_role_lookup_failure_is_fail_closed() -> None:
    connection = MagicMock()
    connection.execute = AsyncMock(side_effect=SQLAlchemyError("unavailable"))
    engine = MagicMock()
    engine.connect.return_value.__aenter__ = AsyncMock(return_value=connection)
    engine.connect.return_value.__aexit__ = AsyncMock(return_value=None)
    request = MagicMock()
    request.app.state.database_engine = engine

    with pytest.raises(HTTPException, match="authorization unavailable") as error:
        await require_training_researcher(request, _user())

    assert error.value.status_code == 503
