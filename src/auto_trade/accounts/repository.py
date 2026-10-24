from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.accounts.models import (
    AccountSummary,
    AccountTrade,
    AdminUser,
    CurrentUser,
    PaperTraderPreferences,
    UserRole,
)
from auto_trade.paper_trading.models import PaperTrade


class EmailAlreadyRegisteredError(Exception):
    pass


class AccountBalanceChangedError(Exception):
    pass


class AccountRepository:
    def __init__(self, engine: AsyncEngine) -> None:
        self.engine = engine

    async def register(self, email: str, password_hash: str) -> CurrentUser:
        try:
            async with self.engine.begin() as connection:
                user = (
                    await connection.execute(
                        text(
                            """
                            INSERT INTO core.app_users (email, password_hash)
                            VALUES (:email, :password_hash)
                            RETURNING user_id, email, created_at
                            """
                        ),
                        {"email": email, "password_hash": password_hash},
                    )
                ).mappings().one()
                await connection.execute(
                    text(
                        """
                        INSERT INTO trade.paper_accounts (user_id, starting_balance, balance)
                        VALUES (:user_id, 1000, 1000)
                        """
                    ),
                    {"user_id": user["user_id"]},
                )
        except IntegrityError as error:
            raise EmailAlreadyRegisteredError from error
        return CurrentUser(
            user_id=user["user_id"],
            email=user["email"],
            role=UserRole.NORMAL,
            created_at=user["created_at"],
            account=AccountSummary(
                starting_balance=1000,
                balance=1000,
                realized_pnl=0,
                trade_count=0,
            ),
        )

    async def credentials(self, identifier: str) -> dict[str, Any] | None:
        async with self.engine.connect() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        SELECT user_id, password_hash
                        FROM core.app_users
                        WHERE lower(email) = lower(:identifier)
                           OR lower(username) = lower(:identifier)
                        """
                    ),
                    {"identifier": identifier},
                )
            ).mappings().one_or_none()
        return dict(row) if row is not None else None

    async def create_session(
        self, user_id: UUID, token_hash: str, expires_at: datetime
    ) -> None:
        async with self.engine.begin() as connection:
            await connection.execute(
                text("DELETE FROM core.user_sessions WHERE expires_at <= now()"),
            )
            await connection.execute(
                text(
                    """
                    INSERT INTO core.user_sessions (token_hash, user_id, expires_at)
                    VALUES (:token_hash, :user_id, :expires_at)
                    """
                ),
                {
                    "token_hash": token_hash,
                    "user_id": user_id,
                    "expires_at": expires_at.astimezone(UTC),
                },
            )

    async def delete_session(self, token_hash: str) -> None:
        async with self.engine.begin() as connection:
            await connection.execute(
                text("DELETE FROM core.user_sessions WHERE token_hash = :token_hash"),
                {"token_hash": token_hash},
            )

    async def current_user(self, token_hash: str) -> CurrentUser | None:
        async with self.engine.begin() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        SELECT u.user_id,
                               u.email,
                               u.username,
                               u.role,
                               u.created_at,
                               a.starting_balance,
                               a.balance,
                               count(t.trade_id)::integer AS trade_count
                        FROM core.user_sessions s
                        JOIN core.app_users u ON u.user_id = s.user_id
                        JOIN trade.paper_accounts a ON a.user_id = u.user_id
                        LEFT JOIN trade.paper_trades t ON t.user_id = u.user_id
                        WHERE s.token_hash = :token_hash
                          AND s.expires_at > now()
                        GROUP BY u.user_id, u.email, u.username, u.role, u.created_at,
                                 a.starting_balance, a.balance
                        """
                    ),
                    {"token_hash": token_hash},
                )
            ).mappings().one_or_none()
            if row is not None:
                await connection.execute(
                    text(
                        """
                        UPDATE core.user_sessions
                        SET last_seen_at = now()
                        WHERE token_hash = :token_hash
                        """
                    ),
                    {"token_hash": token_hash},
                )
        return self._current_user(row) if row is not None else None

    async def current_user_for_id(self, user_id: UUID) -> CurrentUser:
        async with self.engine.connect() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        SELECT u.user_id,
                               u.email,
                               u.username,
                               u.role,
                               u.created_at,
                               a.starting_balance,
                               a.balance,
                               count(t.trade_id)::integer AS trade_count
                        FROM core.app_users u
                        JOIN trade.paper_accounts a ON a.user_id = u.user_id
                        LEFT JOIN trade.paper_trades t ON t.user_id = u.user_id
                        WHERE u.user_id = :user_id
                        GROUP BY u.user_id, u.email, u.username, u.role, u.created_at,
                                 a.starting_balance, a.balance
                        """
                    ),
                    {"user_id": user_id},
                )
            ).mappings().one()
        return self._current_user(row)

    async def account_summary(self, user_id: UUID) -> AccountSummary:
        async with self.engine.connect() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        SELECT a.starting_balance,
                               a.balance,
                               count(t.trade_id)::integer AS trade_count
                        FROM trade.paper_accounts a
                        LEFT JOIN trade.paper_trades t ON t.user_id = a.user_id
                        WHERE a.user_id = :user_id
                        GROUP BY a.starting_balance, a.balance
                        """
                    ),
                    {"user_id": user_id},
                )
            ).mappings().one()
        return self._account_summary(row)

    async def trades(self, user_id: UUID, limit: int) -> tuple[AccountTrade, ...]:
        async with self.engine.connect() as connection:
            rows = (
                await connection.execute(
                    text(
                        """
                        SELECT trade_id, session_id, symbol, interval_seconds,
                               side, leverage, margin, quantity, entry_price,
                               exit_price, gross_pnl, entry_fee, exit_fee, fee,
                               realized_pnl, balance_before,
                               balance_after, opened_at, closed_at, exit_reason
                        FROM trade.paper_trades
                        WHERE user_id = :user_id
                        ORDER BY closed_at DESC, trade_id DESC
                        LIMIT :limit
                        """
                    ),
                    {"user_id": user_id, "limit": limit},
                )
            ).mappings().all()
        return tuple(AccountTrade.model_validate(row) for row in rows)

    async def paper_trader_preferences(
        self, user_id: UUID
    ) -> PaperTraderPreferences:
        async with self.engine.connect() as connection:
            value = (
                await connection.execute(
                    text(
                        """
                        SELECT paper_trader
                        FROM core.user_preferences
                        WHERE user_id = :user_id
                        """
                    ),
                    {"user_id": user_id},
                )
            ).scalar_one_or_none()
        return PaperTraderPreferences.model_validate(value or {})

    async def save_paper_trader_preferences(
        self, user_id: UUID, preferences: PaperTraderPreferences
    ) -> PaperTraderPreferences:
        async with self.engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    INSERT INTO core.user_preferences (user_id, paper_trader)
                    VALUES (:user_id, CAST(:paper_trader AS jsonb))
                    ON CONFLICT (user_id) DO UPDATE SET
                        paper_trader = EXCLUDED.paper_trader,
                        updated_at = clock_timestamp()
                    """
                ),
                {
                    "user_id": user_id,
                    "paper_trader": json.dumps(
                        preferences.model_dump(mode="json"), separators=(",", ":")
                    ),
                },
            )
        return preferences

    async def ensure_default_admin(
        self, username: str, email: str, password_hash: str
    ) -> None:
        async with self.engine.begin() as connection:
            row = (
                await connection.execute(
                    text(
                        """
                        INSERT INTO core.app_users (email, username, password_hash, role)
                        VALUES (:email, :username, :password_hash, 'ADMIN')
                        ON CONFLICT DO NOTHING
                        RETURNING user_id
                        """
                    ),
                    {
                        "email": email,
                        "username": username,
                        "password_hash": password_hash,
                    },
                )
            ).mappings().one_or_none()
            if row is not None:
                await connection.execute(
                    text(
                        """
                        INSERT INTO trade.paper_accounts (user_id, starting_balance, balance)
                        VALUES (:user_id, 1000, 1000)
                        """
                    ),
                    {"user_id": row["user_id"]},
                )
                return
            existing_role = (
                await connection.execute(
                    text(
                        """
                        SELECT role
                        FROM core.app_users
                        WHERE lower(username) = lower(:username)
                        """
                    ),
                    {"username": username},
                )
            ).scalar_one_or_none()
            if existing_role != UserRole.ADMIN.value:
                raise RuntimeError(
                    "default administrator could not be created because its "
                    "username or reserved email is already in use"
                )

    async def users(self) -> tuple[AdminUser, ...]:
        async with self.engine.connect() as connection:
            rows = (
                await connection.execute(
                    text(
                        """
                        SELECT u.user_id, u.email, u.username, u.role, u.created_at,
                               a.balance, count(t.trade_id)::integer AS trade_count
                        FROM core.app_users u
                        JOIN trade.paper_accounts a ON a.user_id = u.user_id
                        LEFT JOIN trade.paper_trades t ON t.user_id = u.user_id
                        GROUP BY u.user_id, u.email, u.username, u.role,
                                 u.created_at, a.balance
                        ORDER BY u.created_at DESC, u.user_id DESC
                        """
                    )
                )
            ).mappings().all()
        return tuple(AdminUser.model_validate(row) for row in rows)

    async def update_user_role(
        self, user_id: UUID, role: UserRole
    ) -> AdminUser | None:
        async with self.engine.begin() as connection:
            updated = (
                await connection.execute(
                    text(
                        """
                        UPDATE core.app_users
                        SET role = :role
                        WHERE user_id = :user_id
                          AND role <> 'ADMIN'
                        RETURNING user_id
                        """
                    ),
                    {"user_id": user_id, "role": role.value},
                )
            ).scalar_one_or_none()
        if updated is None:
            return None
        return next(user for user in await self.users() if user.user_id == user_id)

    async def record_trade(
        self,
        *,
        user_id: UUID,
        session_id: str,
        symbol: str,
        interval_seconds: int,
        trade: PaperTrade,
        balance_before: float,
        balance_after: float,
    ) -> None:
        async with self.engine.begin() as connection:
            current_balance: Any = (
                await connection.execute(
                    text(
                        """
                        SELECT balance
                        FROM trade.paper_accounts
                        WHERE user_id = :user_id
                        FOR UPDATE
                        """
                    ),
                    {"user_id": user_id},
                )
            ).scalar_one()
            if abs(float(current_balance) - balance_before) > 0.000001:
                raise AccountBalanceChangedError
            await connection.execute(
                text(
                    """
                    INSERT INTO trade.paper_trades (
                        user_id, session_id, symbol, interval_seconds, side,
                        leverage, margin, quantity, entry_price, exit_price,
                        gross_pnl, entry_fee, exit_fee, fee, realized_pnl,
                        balance_before, balance_after, opened_at,
                        closed_at, exit_reason
                    ) VALUES (
                        :user_id, :session_id, :symbol, :interval_seconds, :side,
                        :leverage, :margin, :quantity, :entry_price, :exit_price,
                        :gross_pnl, :entry_fee, :exit_fee, :fee, :realized_pnl,
                        :balance_before, :balance_after, :opened_at,
                        :closed_at, :exit_reason
                    )
                    """
                ),
                {
                    "user_id": user_id,
                    "session_id": session_id,
                    "symbol": symbol,
                    "interval_seconds": interval_seconds,
                    "side": trade.side.value,
                    "leverage": trade.leverage,
                    "margin": trade.margin,
                    "quantity": trade.quantity,
                    "entry_price": trade.entry_price,
                    "exit_price": trade.exit_price,
                    "gross_pnl": trade.gross_pnl,
                    "entry_fee": trade.entry_fee,
                    "exit_fee": trade.exit_fee,
                    "fee": trade.fee,
                    "realized_pnl": trade.realized_pnl,
                    "balance_before": balance_before,
                    "balance_after": balance_after,
                    "opened_at": trade.opened_at,
                    "closed_at": trade.closed_at,
                    "exit_reason": trade.exit_reason,
                },
            )
            await connection.execute(
                text(
                    """
                    UPDATE trade.paper_accounts
                    SET balance = :balance_after
                    WHERE user_id = :user_id
                    """
                ),
                {"balance_after": balance_after, "user_id": user_id},
            )

    @staticmethod
    def _account_summary(row: Any) -> AccountSummary:
        starting_balance = float(row["starting_balance"])
        balance = float(row["balance"])
        return AccountSummary(
            starting_balance=starting_balance,
            balance=balance,
            realized_pnl=balance - starting_balance,
            trade_count=int(row["trade_count"]),
        )

    @classmethod
    def _current_user(cls, row: Any) -> CurrentUser:
        return CurrentUser(
            user_id=row["user_id"],
            email=row["email"],
            username=row["username"],
            role=UserRole(row["role"]),
            created_at=row["created_at"],
            account=cls._account_summary(row),
        )
