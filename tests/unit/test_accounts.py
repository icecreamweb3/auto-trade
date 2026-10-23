from pydantic import ValidationError

from auto_trade.accounts.models import Credentials, normalize_email
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
