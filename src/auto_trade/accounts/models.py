from __future__ import annotations

from datetime import date, datetime
from enum import StrEnum
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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


class UserRole(StrEnum):
    NORMAL = "NORMAL"
    ADVANCED = "ADVANCED"
    ADMIN = "ADMIN"


class Credentials(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=8, max_length=128)

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        return normalize_email(value)


class LoginCredentials(BaseModel):
    identifier: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=8, max_length=128)

    @field_validator("identifier")
    @classmethod
    def normalize_identifier(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("请输入邮箱或用户名")
        return normalized


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
    username: str | None = None
    role: UserRole
    created_at: datetime
    account: AccountSummary


class AdminUser(BaseModel):
    model_config = ConfigDict(frozen=True)

    user_id: UUID
    email: str
    username: str | None = None
    role: UserRole
    created_at: datetime
    balance: float
    trade_count: int


class UserRoleUpdate(BaseModel):
    role: UserRole


class AccountTrade(BaseModel):
    model_config = ConfigDict(frozen=True)

    trade_id: UUID
    session_id: UUID
    round_no: int
    symbol: str
    interval_seconds: int
    side: str
    leverage: int
    margin: float
    quantity: float
    entry_price: float
    exit_price: float
    gross_pnl: float
    entry_fee: float
    exit_fee: float
    fee: float
    realized_pnl: float
    balance_before: float
    balance_after: float
    opened_at: datetime
    closed_at: datetime
    recorded_at: datetime
    exit_reason: str


class AccountTradeHistory(BaseModel):
    model_config = ConfigDict(frozen=True)

    account: AccountSummary
    trades: tuple[AccountTrade, ...]


class AccountPerformanceSummary(BaseModel):
    model_config = ConfigDict(frozen=True)

    round_count: int
    completed_round_count: int
    trade_count: int
    winning_trade_count: int
    win_rate: float
    gross_pnl: float
    total_fees: float
    net_pnl: float


class DailyPerformance(BaseModel):
    model_config = ConfigDict(frozen=True)

    trade_date: date
    round_count: int
    trade_count: int
    winning_trade_count: int
    win_rate: float
    gross_pnl: float
    total_fees: float
    net_pnl: float


class RoundPerformance(BaseModel):
    model_config = ConfigDict(frozen=True)

    session_id: UUID
    round_no: int
    symbol: str
    interval_seconds: int
    range_start: datetime
    range_end: datetime
    status: str
    started_at: datetime
    completed_at: datetime | None
    starting_balance: float
    ending_balance: float
    trade_count: int
    winning_trade_count: int
    win_rate: float
    gross_pnl: float
    total_fees: float
    net_pnl: float


class ProfitRankingEntry(BaseModel):
    model_config = ConfigDict(frozen=True)

    rank: int
    user_id: UUID
    display_name: str
    balance: float
    round_count: int
    trade_count: int
    win_rate: float
    gross_pnl: float
    total_fees: float
    net_pnl: float


class AccountAnalytics(BaseModel):
    model_config = ConfigDict(frozen=True)

    account: AccountSummary
    summary: AccountPerformanceSummary
    daily: tuple[DailyPerformance, ...]
    rounds: tuple[RoundPerformance, ...]
    trades: tuple[AccountTrade, ...]
    today_ranking: tuple[ProfitRankingEntry, ...]
    overall_ranking: tuple[ProfitRankingEntry, ...]
    timezone: str = "Asia/Shanghai"


class PaperReplayPresetPreference(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str = Field(min_length=1, max_length=80)
    symbol: str = Field(min_length=1, max_length=32)
    interval_seconds: Literal[300, 900, 3600]
    range_start: datetime
    range_end: datetime

    @field_validator("symbol")
    @classmethod
    def normalize_symbol(cls, value: str) -> str:
        return value.strip().upper()

    @model_validator(mode="after")
    def validate_range(self) -> PaperReplayPresetPreference:
        if self.range_start >= self.range_end:
            raise ValueError("快捷行情开始时间必须早于结束时间")
        return self


class PaperTraderPreferences(BaseModel):
    model_config = ConfigDict(frozen=True)

    symbol: str = Field(default="BTCUSDT", min_length=1, max_length=32)
    interval_seconds: Literal[300, 900, 3600] = 300
    range_start: datetime | None = None
    range_end: datetime | None = None
    random_symbol: str = Field(default="BTCUSDT", min_length=1, max_length=32)
    random_interval_seconds: Literal[300, 900, 3600] = 300
    random_session_kind: Literal["US", "ASIA"] = "US"
    random_range_start: date | None = None
    random_range_end: date | None = None
    speed_seconds: Literal[1, 3, 5, 10, 15, 30] = 5
    notional: float = Field(default=100, gt=0)
    notional_unit: Literal["USDT", "BASE"] = "USDT"
    leverage: Literal[1, 2, 3, 5, 10, 20, 25, 50, 75, 100] = 100
    open_order_type: Literal["LIMIT", "MARKET", "STOP_MARKET"] = "MARKET"
    close_order_type: Literal["LIMIT", "MARKET"] = "LIMIT"
    auto_two_r_take_profit: bool = True
    show_opening_range: bool = True
    show_upper_opening_range: bool = False
    show_lower_opening_range: bool = False
    replay_presets: tuple[PaperReplayPresetPreference, ...] = Field(
        default=(), max_length=30
    )

    @field_validator("symbol", "random_symbol")
    @classmethod
    def normalize_symbol(cls, value: str) -> str:
        return value.strip().upper()

    @model_validator(mode="after")
    def validate_range(self) -> PaperTraderPreferences:
        if (
            self.random_range_start is not None
            and self.random_range_end is not None
            and self.random_range_start > self.random_range_end
        ):
            raise ValueError("随机行情数据集开始日期不能晚于结束日期")
        if (self.range_start is None) != (self.range_end is None):
            raise ValueError("行情开始和结束时间必须同时设置")
        if (
            self.range_start is not None
            and self.range_end is not None
            and self.range_start >= self.range_end
        ):
            raise ValueError("行情开始时间必须早于结束时间")
        return self
