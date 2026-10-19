\set ON_ERROR_STOP on
\pset pager off

BEGIN;

ALTER TABLE market.kline_ema_indicators
    ADD COLUMN IF NOT EXISTS price_change_percent numeric(38,18),
    ADD COLUMN IF NOT EXISTS amplitude_percent numeric(38,18);

ALTER TABLE market.kline_ema_indicators
    ADD CONSTRAINT ck_kline_indicator_price_change_finite
    CHECK (price_change_percent IS NULL OR price_change_percent > -100)
    NOT VALID;

ALTER TABLE market.kline_ema_indicators
    ADD CONSTRAINT ck_kline_indicator_amplitude_nonnegative
    CHECK (amplitude_percent IS NULL OR amplitude_percent >= 0)
    NOT VALID;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '007_kline_change_amplitude_indicators',
    encode(
        digest('auto_trade_v2_007_kline_change_amplitude_indicators_v1', 'sha256'),
        'hex'
    ),
    'Persist per-candle price change and amplitude for Trade 5m and derived 15m K-lines'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
