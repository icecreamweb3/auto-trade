from datetime import UTC, datetime
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
    UserRole,
    normalize_email,
)
from auto_trade.accounts.router import require_admin
from auto_trade.accounts.security import (
    hash_password,
    new_session_token,
    session_token_hash,
    verify_password,
)


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


@pytest.mark.parametrize(
    ("role", "path", "allowed"),
    (
        (UserRole.NORMAL, "/api/paper-trader/metadata", True),
        (UserRole.NORMAL, "/api/account/trades", True),
        (UserRole.NORMAL, "/api/rankings/daily", False),
        (UserRole.NORMAL, "/api/backtests/metadata", False),
        (UserRole.NORMAL, "/api/monitoring/overview", False),
        (UserRole.ADVANCED, "/api/rankings/daily", True),
        (UserRole.ADVANCED, "/api/admin/users", False),
        (UserRole.ADMIN, "/api/admin/users", True),
    ),
)
def test_role_api_access_matrix(role: UserRole, path: str, allowed: bool) -> None:
    assert (api_access_error(role, path) is None) is allowed
