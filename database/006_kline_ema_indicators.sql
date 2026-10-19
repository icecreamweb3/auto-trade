\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE INDEX IF NOT EXISTS ix_klines_ema_source_changes
ON market.klines (instrument_id, effective_at, open_time)
WHERE price_type = 'TRADE'
  AND interval_seconds = 300
  AND is_current
  AND is_closed
  AND quality_status = 'VALID';

CREATE TABLE IF NOT EXISTS market.kline_ema_indicators (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    price_type          varchar(24) NOT NULL DEFAULT 'TRADE'
                        CHECK (price_type = 'TRADE'),
    interval_seconds    integer NOT NULL CHECK (interval_seconds IN (300, 900)),
    open_time           timestamptz NOT NULL,
    close_time          timestamptz NOT NULL,
    close_price         numeric(38,18) NOT NULL CHECK (close_price > 0),
    ema20               numeric(38,18) NOT NULL CHECK (ema20 > 0),
    ema240              numeric(38,18) NOT NULL CHECK (ema240 > 0),
    source_bar_count    smallint NOT NULL CHECK (source_bar_count IN (1, 3)),
    calculation_version varchar(40) NOT NULL,
    computed_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, price_type, interval_seconds, open_time),
    CHECK (close_time > open_time),
    CHECK (
        (interval_seconds = 300 AND source_bar_count = 1)
        OR (interval_seconds = 900 AND source_bar_count = 3)
    )
);

CREATE INDEX IF NOT EXISTS ix_kline_ema_interval_time
ON market.kline_ema_indicators (
    instrument_id, interval_seconds, open_time DESC
);

SELECT create_hypertable(
    'market.kline_ema_indicators',
    by_range('open_time'),
    if_not_exists => TRUE
);

CREATE TABLE IF NOT EXISTS market.kline_ema_checkpoints (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    interval_seconds    integer NOT NULL CHECK (interval_seconds IN (300, 900)),
    source_checked_at   timestamptz NOT NULL,
    last_open_time      timestamptz,
    calculation_version varchar(40) NOT NULL,
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, interval_seconds)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON market.kline_ema_indicators TO tb2_collector;
GRANT SELECT, INSERT, UPDATE, DELETE ON market.kline_ema_checkpoints TO tb2_collector;
GRANT SELECT ON market.kline_ema_indicators TO tb2_trader, tb2_analysis_ro,
    tb2_backup;
GRANT SELECT ON market.kline_ema_checkpoints TO tb2_trader, tb2_analysis_ro,
    tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '006_kline_ema_indicators',
    encode(
        digest('auto_trade_v2_006_kline_ema_indicators_v1', 'sha256'),
        'hex'
    ),
    'Precompute warmed EMA20 and EMA240 for Trade 5m and derived 15m K-lines'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
