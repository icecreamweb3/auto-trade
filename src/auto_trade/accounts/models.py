from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator


def normalize_email(value: str) -> str:
    normalized = value.strip().lower()
    local, separator, domain = normalized.partition("@")
    if (
        not separator
        or not local
        or not domain
        or "." not in domain
        or len(normalized) > 320
        or any(character.isspace() for character in normalized)
    ):
        raise ValueError("请输入有效的邮箱地址")
    return normalized


class Credentials(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=8, max_length=128)

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        return normalize_email(value)


class AccountSummary(BaseModel):
    model_config = ConfigDict(frozen=True)

    starting_balance: float
    balance: float
    realized_pnl: float
    trade_count: int


class CurrentUser(BaseModel):
    model_config = ConfigDict(frozen=True)

    user_id: UUID
    email: str
    created_at: datetime
    account: AccountSummary


class AccountTrade(BaseModel):
    model_config = ConfigDict(frozen=True)

    trade_id: UUID
    session_id: UUID
    symbol: str
    interval_seconds: int
    side: str
    leverage: int
    margin: float
    quantity: float
    entry_price: float
    exit_price: float
    realized_pnl: float
    balance_before: float
    balance_after: float
    opened_at: datetime
    closed_at: datetime
    exit_reason: str


class AccountTradeHistory(BaseModel):
    model_config = ConfigDict(frozen=True)

    account: AccountSummary
    trades: tuple[AccountTrade, ...]
