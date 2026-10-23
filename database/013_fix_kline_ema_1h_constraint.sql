\set ON_ERROR_STOP on
\pset pager off

BEGIN;

ALTER TABLE market.kline_ema_indicators
    DROP CONSTRAINT IF EXISTS kline_ema_indicators_check1;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '013_fix_kline_ema_1h_constraint',
    encode(
        digest('auto_trade_v2_013_fix_kline_ema_1h_constraint_v1', 'sha256'),
        'hex'
    ),
    'Remove legacy EMA interval and source-count constraint blocking 1-hour rows'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
