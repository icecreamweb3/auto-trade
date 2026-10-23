\set ON_ERROR_STOP on
\pset pager off

BEGIN;

ALTER TABLE market.kline_ema_indicators
    DROP CONSTRAINT IF EXISTS kline_ema_indicators_interval_seconds_check,
    DROP CONSTRAINT IF EXISTS kline_ema_indicators_source_bar_count_check,
    DROP CONSTRAINT IF EXISTS kline_ema_indicators_check,
    DROP CONSTRAINT IF EXISTS kline_ema_indicators_check1;

ALTER TABLE market.kline_ema_indicators
    ADD CONSTRAINT kline_ema_indicators_interval_seconds_check
        CHECK (interval_seconds IN (300, 900, 3600)),
    ADD CONSTRAINT kline_ema_indicators_source_bar_count_check
        CHECK (source_bar_count IN (1, 3, 12)),
    ADD CONSTRAINT kline_ema_indicators_interval_source_count_check CHECK (
        (interval_seconds = 300 AND source_bar_count = 1)
        OR (interval_seconds = 900 AND source_bar_count = 3)
        OR (interval_seconds = 3600 AND source_bar_count = 12)
    );

ALTER TABLE market.kline_ema_checkpoints
    DROP CONSTRAINT IF EXISTS kline_ema_checkpoints_interval_seconds_check;

ALTER TABLE market.kline_ema_checkpoints
    ADD CONSTRAINT kline_ema_checkpoints_interval_seconds_check
        CHECK (interval_seconds IN (300, 900, 3600));

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '012_kline_ema_1h',
    encode(digest('auto_trade_v2_012_kline_ema_1h_v1', 'sha256'), 'hex'),
    'Extend precomputed EMA20 and EMA240 indicators to 1-hour K-lines'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
