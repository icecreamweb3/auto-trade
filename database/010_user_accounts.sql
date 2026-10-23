\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS core.app_users (
    user_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email           varchar(320) NOT NULL,
    password_hash   text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (email = lower(btrim(email))),
    CHECK (btrim(email) <> ''),
    CHECK (btrim(password_hash) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_app_users_email
ON core.app_users (email);

DROP TRIGGER IF EXISTS trg_app_users_updated_at ON core.app_users;
CREATE TRIGGER trg_app_users_updated_at
BEFORE UPDATE ON core.app_users
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS core.user_sessions (
    token_hash      char(64) PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES core.app_users(user_id) ON DELETE CASCADE,
    created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at      timestamptz NOT NULL,
    last_seen_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS ix_user_sessions_user
ON core.user_sessions (user_id, expires_at DESC);

CREATE TABLE IF NOT EXISTS trade.paper_accounts (
    user_id             uuid PRIMARY KEY REFERENCES core.app_users(user_id) ON DELETE CASCADE,
    starting_balance    numeric(24, 8) NOT NULL DEFAULT 1000,
    balance             numeric(24, 8) NOT NULL DEFAULT 1000,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (starting_balance >= 0),
    CHECK (balance >= 0)
);

DROP TRIGGER IF EXISTS trg_paper_accounts_updated_at ON trade.paper_accounts;
CREATE TRIGGER trg_paper_accounts_updated_at
BEFORE UPDATE ON trade.paper_accounts
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS trade.paper_trades (
    trade_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid NOT NULL REFERENCES core.app_users(user_id) ON DELETE CASCADE,
    session_id       uuid NOT NULL,
    symbol           varchar(32) NOT NULL,
    interval_seconds integer NOT NULL CHECK (interval_seconds IN (300, 900, 3600)),
    side              varchar(8) NOT NULL CHECK (side IN ('LONG', 'SHORT')),
    leverage          integer NOT NULL CHECK (leverage BETWEEN 1 AND 100),
    margin            numeric(24, 8) NOT NULL CHECK (margin > 0),
    quantity          numeric(30, 12) NOT NULL CHECK (quantity > 0),
    entry_price       numeric(30, 12) NOT NULL CHECK (entry_price > 0),
    exit_price        numeric(30, 12) NOT NULL CHECK (exit_price > 0),
    realized_pnl      numeric(24, 8) NOT NULL,
    balance_before    numeric(24, 8) NOT NULL CHECK (balance_before >= 0),
    balance_after     numeric(24, 8) NOT NULL CHECK (balance_after >= 0),
    opened_at         timestamptz NOT NULL,
    closed_at         timestamptz NOT NULL,
    exit_reason       varchar(32) NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (closed_at >= opened_at)
);

CREATE INDEX IF NOT EXISTS ix_paper_trades_user_closed
ON trade.paper_trades (user_id, closed_at DESC, trade_id DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON core.app_users, core.user_sessions TO tb2_trader;
GRANT SELECT, INSERT, UPDATE, DELETE ON trade.paper_accounts, trade.paper_trades TO tb2_trader;
GRANT SELECT ON trade.paper_accounts, trade.paper_trades TO tb2_analysis_ro;
GRANT SELECT ON core.app_users, core.user_sessions, trade.paper_accounts, trade.paper_trades TO tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '010_user_accounts',
    encode(digest('auto_trade_v2_010_user_accounts_v1', 'sha256'), 'hex'),
    'Add email users, login sessions, persistent paper accounts and trade history'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
