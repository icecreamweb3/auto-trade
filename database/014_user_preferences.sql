\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS core.user_preferences (
    user_id       uuid PRIMARY KEY REFERENCES core.app_users(user_id) ON DELETE CASCADE,
    paper_trader  jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(paper_trader) = 'object')
);

GRANT SELECT, INSERT, UPDATE, DELETE ON core.user_preferences TO tb2_trader;
GRANT SELECT ON core.user_preferences TO tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '014_user_preferences',
    encode(digest('auto_trade_v2_014_user_preferences_v1', 'sha256'), 'hex'),
    'Persist per-user PaperTrader display and replay preferences'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
