from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine

from auto_trade.accounts.models import (
    AccountAnalytics,
    AccountPerformanceSummary,
    AccountSummary,
    AccountTrade,
    AdminUser,
    CurrentUser,
    DailyPerformance,
    PaperTraderPreferences,
    ProfitRankingEntry,
    RoundPerformance,
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
                        WITH numbered_sessions AS (
                            SELECT session_id,
                                   row_number() OVER (
                                       PARTITION BY user_id
                                       ORDER BY started_at, session_id
                                   )::integer AS round_no
                            FROM trade.paper_sessions
                            WHERE user_id = :user_id
                        )
                        SELECT t.trade_id, t.session_id, s.round_no,
                               t.symbol, t.interval_seconds,
                               side, leverage, margin, quantity, entry_price,
                               exit_price, gross_pnl, entry_fee, exit_fee, fee,
                               realized_pnl, balance_before,
                               balance_after, opened_at, closed_at,
                               t.created_at AS recorded_at, exit_reason
                        FROM trade.paper_trades t
                        JOIN numbered_sessions s ON s.session_id = t.session_id
                        WHERE t.user_id = :user_id
                        ORDER BY t.closed_at DESC, t.trade_id DESC
                        LIMIT :limit
                        """
                    ),
                    {"user_id": user_id, "limit": limit},
                )
            ).mappings().all()
        return tuple(AccountTrade.model_validate(row) for row in rows)

    async def record_paper_session(
        self,
        *,
        user_id: UUID,
        session_id: str,
        symbol: str,
        interval_seconds: int,
        range_start: datetime,
        range_end: datetime,
        starting_balance: float,
        status: str,
    ) -> None:
        async with self.engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    INSERT INTO trade.paper_sessions (
                        session_id, user_id, symbol, interval_seconds,
                        range_start, range_end, starting_balance,
                        ending_balance, status
                    ) VALUES (
                        :session_id, :user_id, :symbol, :interval_seconds,
                        :range_start, :range_end, :starting_balance,
                        :starting_balance, :status
                    )
                    ON CONFLICT (session_id) DO NOTHING
                    """
                ),
                {
                    "session_id": session_id,
                    "user_id": user_id,
                    "symbol": symbol,
                    "interval_seconds": interval_seconds,
                    "range_start": range_start,
                    "range_end": range_end,
                    "starting_balance": starting_balance,
                    "status": status,
                },
            )

    async def update_paper_session(
        self,
        *,
        session_id: str,
        ending_balance: float,
        status: str,
    ) -> None:
        completed = status in ("COMPLETED", "LIQUIDATED")
        async with self.engine.begin() as connection:
            await connection.execute(
                text(
                    """
                    UPDATE trade.paper_sessions
                    SET ending_balance = :ending_balance,
                        status = :status,
                        completed_at = CASE
                            WHEN :completed THEN coalesce(completed_at, clock_timestamp())
                            ELSE completed_at
                        END
                    WHERE session_id = :session_id
                    """
                ),
                {
                    "session_id": session_id,
                    "ending_balance": ending_balance,
                    "status": status,
                    "completed": completed,
                },
            )

    async def analytics(
        self, user_id: UUID, *, days: int = 30, trade_limit: int = 500
    ) -> AccountAnalytics:
        account = await self.account_summary(user_id)
        async with self.engine.connect() as connection:
            summary_row = (
                await connection.execute(
                    text(
                        """
                        SELECT count(DISTINCT s.session_id)::integer AS round_count,
                               count(DISTINCT s.session_id) FILTER (
                                   WHERE s.status IN ('COMPLETED', 'LIQUIDATED')
                               )::integer AS completed_round_count,
                               count(t.trade_id)::integer AS trade_count,
                               count(t.trade_id) FILTER (
                                   WHERE t.realized_pnl > 0
                               )::integer AS winning_trade_count,
                               CASE WHEN count(t.trade_id) = 0 THEN 0
                                    ELSE count(t.trade_id) FILTER (
                                        WHERE t.realized_pnl > 0
                                    )::double precision / count(t.trade_id) * 100
                               END AS win_rate,
                               coalesce(sum(t.gross_pnl), 0) AS gross_pnl,
                               coalesce(sum(t.fee), 0) AS total_fees,
                               coalesce(sum(t.realized_pnl), 0) AS net_pnl
                        FROM trade.paper_accounts a
                        LEFT JOIN trade.paper_sessions s ON s.user_id = a.user_id
                        LEFT JOIN trade.paper_trades t ON t.session_id = s.session_id
                        WHERE a.user_id = :user_id
                        """
                    ),
                    {"user_id": user_id},
                )
            ).mappings().one()
            daily_rows = (
                await connection.execute(
                    text(
                        """
                        WITH dates AS (
                            SELECT generate_series(
                                (now() AT TIME ZONE 'Asia/Shanghai')::date
                                    - (CAST(:days AS integer) - 1),
                                (now() AT TIME ZONE 'Asia/Shanghai')::date,
                                interval '1 day'
                            )::date AS trade_date
                        ), trade_totals AS (
                            SELECT (created_at AT TIME ZONE 'Asia/Shanghai')::date AS trade_date,
                                   count(*)::integer AS trade_count,
                                   count(*) FILTER (WHERE realized_pnl > 0)::integer
                                       AS winning_trade_count,
                                   sum(gross_pnl) AS gross_pnl,
                                   sum(fee) AS total_fees,
                                   sum(realized_pnl) AS net_pnl
                            FROM trade.paper_trades
                            WHERE user_id = :user_id
                              AND created_at >= ((now() AT TIME ZONE 'Asia/Shanghai')::date
                                  - (CAST(:days AS integer) - 1)) AT TIME ZONE 'Asia/Shanghai'
                            GROUP BY 1
                        ), round_totals AS (
                            SELECT (started_at AT TIME ZONE 'Asia/Shanghai')::date AS trade_date,
                                   count(*)::integer AS round_count
                            FROM trade.paper_sessions
                            WHERE user_id = :user_id
                              AND started_at >= ((now() AT TIME ZONE 'Asia/Shanghai')::date
                                  - (CAST(:days AS integer) - 1)) AT TIME ZONE 'Asia/Shanghai'
                            GROUP BY 1
                        )
                        SELECT d.trade_date,
                               coalesce(r.round_count, 0)::integer AS round_count,
                               coalesce(t.trade_count, 0)::integer AS trade_count,
                               coalesce(t.winning_trade_count, 0)::integer
                                   AS winning_trade_count,
                               CASE WHEN coalesce(t.trade_count, 0) = 0 THEN 0
                                    ELSE t.winning_trade_count::double precision
                                         / t.trade_count * 100
                               END AS win_rate,
                               coalesce(t.gross_pnl, 0) AS gross_pnl,
                               coalesce(t.total_fees, 0) AS total_fees,
                               coalesce(t.net_pnl, 0) AS net_pnl
                        FROM dates d
                        LEFT JOIN trade_totals t USING (trade_date)
                        LEFT JOIN round_totals r USING (trade_date)
                        ORDER BY d.trade_date DESC
                        """
                    ),
                    {"user_id": user_id, "days": days},
                )
            ).mappings().all()
            round_rows = (
                await connection.execute(
                    text(
                        """
                        WITH numbered_sessions AS (
                            SELECT s.*,
                                   row_number() OVER (
                                       PARTITION BY user_id
                                       ORDER BY started_at, session_id
                                   )::integer AS round_no
                            FROM trade.paper_sessions s
                            WHERE user_id = :user_id
                        )
                        SELECT s.session_id, s.round_no, s.symbol,
                               s.interval_seconds, s.range_start, s.range_end,
                               s.status, s.started_at, s.completed_at,
                               s.starting_balance, s.ending_balance,
                               count(t.trade_id)::integer AS trade_count,
                               count(t.trade_id) FILTER (
                                   WHERE t.realized_pnl > 0
                               )::integer AS winning_trade_count,
                               CASE WHEN count(t.trade_id) = 0 THEN 0
                                    ELSE count(t.trade_id) FILTER (
                                        WHERE t.realized_pnl > 0
                                    )::double precision / count(t.trade_id) * 100
                               END AS win_rate,
                               coalesce(sum(t.gross_pnl), 0) AS gross_pnl,
                               coalesce(sum(t.fee), 0) AS total_fees,
                               coalesce(sum(t.realized_pnl), 0) AS net_pnl
                        FROM numbered_sessions s
                        LEFT JOIN trade.paper_trades t ON t.session_id = s.session_id
                        GROUP BY s.session_id, s.round_no, s.symbol,
                                 s.interval_seconds, s.range_start, s.range_end,
                                 s.status, s.started_at, s.completed_at,
                                 s.starting_balance, s.ending_balance
                        ORDER BY s.round_no DESC
                        LIMIT 200
                        """
                    ),
                    {"user_id": user_id},
                )
            ).mappings().all()
        return AccountAnalytics(
            account=account,
            summary=AccountPerformanceSummary.model_validate(summary_row),
            daily=tuple(DailyPerformance.model_validate(row) for row in daily_rows),
            rounds=tuple(RoundPerformance.model_validate(row) for row in round_rows),
            trades=await self.trades(user_id, trade_limit),
            today_ranking=await self._profit_ranking(today_only=True),
            overall_ranking=await self._profit_ranking(today_only=False),
        )

    async def _profit_ranking(
        self, *, today_only: bool
    ) -> tuple[ProfitRankingEntry, ...]:
        trade_filter = (
            "AND created_at >= (now() AT TIME ZONE 'Asia/Shanghai')::date "
            "AT TIME ZONE 'Asia/Shanghai'"
            if today_only
            else ""
        )
        round_filter = (
            "AND started_at >= (now() AT TIME ZONE 'Asia/Shanghai')::date "
            "AT TIME ZONE 'Asia/Shanghai'"
            if today_only
            else ""
        )
        statement = text(
            f"""
            WITH trade_totals AS (
                SELECT user_id, count(*)::integer AS trade_count,
                       count(*) FILTER (WHERE realized_pnl > 0)::integer
                           AS winning_trade_count,
                       sum(gross_pnl) AS gross_pnl,
                       sum(fee) AS total_fees,
                       sum(realized_pnl) AS net_pnl
                FROM trade.paper_trades
                WHERE true {trade_filter}
                GROUP BY user_id
            ), round_totals AS (
                SELECT user_id, count(*)::integer AS round_count
                FROM trade.paper_sessions
                WHERE true {round_filter}
                GROUP BY user_id
            ), ranked AS (
                SELECT u.user_id,
                       coalesce(u.username, split_part(u.email, '@', 1)) AS display_name,
                       a.balance,
                       coalesce(r.round_count, 0)::integer AS round_count,
                       coalesce(t.trade_count, 0)::integer AS trade_count,
                       CASE WHEN coalesce(t.trade_count, 0) = 0 THEN 0
                            ELSE t.winning_trade_count::double precision
                                 / t.trade_count * 100
                       END AS win_rate,
                       coalesce(t.gross_pnl, 0) AS gross_pnl,
                       coalesce(t.total_fees, 0) AS total_fees,
                       coalesce(t.net_pnl, 0) AS net_pnl
                FROM core.app_users u
                JOIN trade.paper_accounts a ON a.user_id = u.user_id
                LEFT JOIN trade_totals t ON t.user_id = u.user_id
                LEFT JOIN round_totals r ON r.user_id = u.user_id
            )
            SELECT row_number() OVER (
                       ORDER BY net_pnl DESC, win_rate DESC, trade_count DESC, user_id
                   )::integer AS rank,
                   user_id, display_name, balance, round_count, trade_count,
                   win_rate, gross_pnl, total_fees, net_pnl
            FROM ranked
            ORDER BY rank
            LIMIT 50
            """
        )
        async with self.engine.connect() as connection:
            rows = (await connection.execute(statement)).mappings().all()
        return tuple(ProfitRankingEntry.model_validate(row) for row in rows)

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
