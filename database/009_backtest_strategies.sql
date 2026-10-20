\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS config.backtest_strategies (
    strategy_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name                varchar(120) NOT NULL,
    description         text NOT NULL DEFAULT '',
    interval_seconds    integer NOT NULL CHECK (interval_seconds IN (300, 900)),
    parameters          jsonb NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(name) <> ''),
    CHECK (jsonb_typeof(parameters) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_backtest_strategies_name
ON config.backtest_strategies (lower(name));

DROP TRIGGER IF EXISTS trg_backtest_strategies_updated_at
ON config.backtest_strategies;
CREATE TRIGGER trg_backtest_strategies_updated_at
BEFORE UPDATE ON config.backtest_strategies
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

GRANT SELECT, INSERT, UPDATE, DELETE ON config.backtest_strategies TO tb2_trader;
GRANT SELECT ON config.backtest_strategies TO tb2_analysis_ro, tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '009_backtest_strategies',
    encode(digest('auto_trade_v2_009_backtest_strategies_v1', 'sha256'), 'hex'),
    'Persist named reusable backtest strategy configurations'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
