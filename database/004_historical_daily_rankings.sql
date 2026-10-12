\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS market.utc_daily_metrics (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    utc_trade_date      date NOT NULL,
    window_start        timestamptz NOT NULL,
    snapshot_at         timestamptz NOT NULL,
    source_kline_time   timestamptz,
    reference_open_price numeric(38,18),
    snapshot_price      numeric(38,18),
    period_high_price   numeric(38,18),
    period_high_at      timestamptz,
    period_low_price    numeric(38,18),
    period_low_at       timestamptz,
    base_volume         numeric(38,18),
    quote_volume        numeric(38,18),
    price_change        numeric(20,10),
    amplitude           numeric(20,10),
    actual_bar_count    smallint NOT NULL CHECK (actual_bar_count BETWEEN 0 AND 287),
    expected_bar_count  smallint NOT NULL DEFAULT 287 CHECK (expected_bar_count = 287),
    source              varchar(40) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','INVALID')),
    metrics             jsonb NOT NULL DEFAULT '{}'::jsonb,
    payload_hash        char(64) NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, utc_trade_date),
    CHECK (snapshot_at > window_start)
);

CREATE INDEX IF NOT EXISTS ix_utc_daily_metrics_ranking
ON market.utc_daily_metrics (utc_trade_date, quality_status, price_change DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON market.utc_daily_metrics TO tb2_collector;
GRANT SELECT ON market.utc_daily_metrics TO tb2_trader, tb2_analysis_ro, tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '004_historical_daily_rankings',
    encode(digest('auto_trade_v2_004_historical_daily_rankings_v1', 'sha256'), 'hex'),
    'Add resumable UTC daily metrics staging for derived historical top-50 rankings'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
