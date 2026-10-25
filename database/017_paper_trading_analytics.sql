\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS trade.paper_sessions (
    session_id        uuid PRIMARY KEY,
    user_id           uuid NOT NULL REFERENCES core.app_users(user_id) ON DELETE CASCADE,
    symbol            varchar(32) NOT NULL,
    interval_seconds  integer NOT NULL CHECK (interval_seconds IN (300, 900, 3600)),
    range_start       timestamptz NOT NULL,
    range_end         timestamptz NOT NULL,
    starting_balance  numeric(24, 8) NOT NULL CHECK (starting_balance >= 0),
    ending_balance    numeric(24, 8) NOT NULL CHECK (ending_balance >= 0),
    status            varchar(16) NOT NULL CHECK (status IN ('READY', 'RUNNING', 'COMPLETED', 'LIQUIDATED')),
    started_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at      timestamptz,
    updated_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (range_end > range_start),
    CHECK (completed_at IS NULL OR completed_at >= started_at)
);

DROP TRIGGER IF EXISTS trg_paper_sessions_updated_at ON trade.paper_sessions;
CREATE TRIGGER trg_paper_sessions_updated_at
BEFORE UPDATE ON trade.paper_sessions
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE INDEX IF NOT EXISTS ix_paper_sessions_user_started
ON trade.paper_sessions (user_id, started_at DESC, session_id DESC);

INSERT INTO trade.paper_sessions (
    session_id, user_id, symbol, interval_seconds, range_start, range_end,
    starting_balance, ending_balance, status, started_at, completed_at
)
SELECT DISTINCT ON (t.session_id)
       t.session_id,
       t.user_id,
       t.symbol,
       t.interval_seconds,
       bounds.first_opened_at,
       CASE
           WHEN bounds.last_closed_at > bounds.first_opened_at THEN bounds.last_closed_at
           ELSE bounds.first_opened_at + make_interval(secs => t.interval_seconds)
       END,
       bounds.first_balance,
       bounds.last_balance,
       'COMPLETED',
       bounds.first_recorded_at,
       bounds.last_recorded_at
FROM trade.paper_trades t
JOIN LATERAL (
    SELECT min(opened_at) AS first_opened_at,
           max(closed_at) AS last_closed_at,
           min(created_at) AS first_recorded_at,
           max(created_at) AS last_recorded_at,
           (array_agg(balance_before ORDER BY closed_at, trade_id))[1] AS first_balance,
           (array_agg(balance_after ORDER BY closed_at DESC, trade_id DESC))[1] AS last_balance
    FROM trade.paper_trades grouped
    WHERE grouped.session_id = t.session_id
) bounds ON true
ON CONFLICT (session_id) DO NOTHING;

GRANT SELECT, INSERT, UPDATE, DELETE ON trade.paper_sessions TO tb2_trader;
GRANT SELECT ON trade.paper_sessions TO tb2_analysis_ro, tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '017_paper_trading_analytics',
    encode(digest('auto_trade_v2_017_paper_trading_analytics_v1', 'sha256'), 'hex'),
    'Persist paper trading rounds and support account performance analytics'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
