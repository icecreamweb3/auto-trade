\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE INDEX IF NOT EXISTS ix_oi_instrument_collected
ON market.open_interest_observations (
    instrument_id, collected_at, observed_at
);

CREATE TABLE IF NOT EXISTS market.klines_15m (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    price_type          varchar(24) NOT NULL DEFAULT 'TRADE'
                        CHECK (price_type = 'TRADE'),
    interval_seconds    integer NOT NULL DEFAULT 900
                        CHECK (interval_seconds = 900),
    open_time           timestamptz NOT NULL,
    close_time          timestamptz NOT NULL,
    open_price          numeric(38,18) NOT NULL CHECK (open_price > 0),
    high_price          numeric(38,18) NOT NULL CHECK (high_price > 0),
    low_price           numeric(38,18) NOT NULL CHECK (low_price > 0),
    close_price         numeric(38,18) NOT NULL CHECK (close_price > 0),
    base_volume         numeric(38,18) NOT NULL CHECK (base_volume >= 0),
    quote_volume        numeric(38,18) NOT NULL CHECK (quote_volume >= 0),
    trade_count         bigint CHECK (trade_count >= 0),
    taker_buy_base      numeric(38,18),
    taker_buy_quote     numeric(38,18),
    open_interest_qty   numeric(38,18),
    open_interest_value numeric(38,18),
    oi_observed_at      timestamptz,
    oi_quality_status   varchar(24),
    source_bar_count    smallint NOT NULL DEFAULT 3 CHECK (source_bar_count = 3),
    derivation_version  varchar(40) NOT NULL,
    computed_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, price_type, interval_seconds, open_time),
    CHECK (close_time > open_time),
    CHECK (high_price >= GREATEST(open_price, close_price, low_price)),
    CHECK (low_price <= LEAST(open_price, close_price, high_price)),
    CHECK (open_interest_qty IS NULL OR open_interest_qty >= 0),
    CHECK (
        oi_quality_status IS NULL
        OR oi_quality_status IN ('VALID', 'PARTIAL')
    ),
    CHECK (
        (oi_observed_at IS NULL AND oi_quality_status IS NULL)
        OR (oi_observed_at IS NOT NULL AND oi_quality_status IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS ix_klines_15m_time
ON market.klines_15m (open_time DESC, instrument_id);

SELECT create_hypertable(
    'market.klines_15m',
    by_range('open_time'),
    if_not_exists => TRUE
);

CREATE TABLE IF NOT EXISTS market.kline_15m_checkpoints (
    instrument_id       bigint PRIMARY KEY REFERENCES core.instruments(instrument_id),
    kline_checked_at    timestamptz NOT NULL,
    oi_checked_at       timestamptz NOT NULL,
    last_open_time      timestamptz,
    derivation_version  varchar(40) NOT NULL,
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON market.klines_15m TO tb2_collector;
GRANT SELECT, INSERT, UPDATE, DELETE ON market.kline_15m_checkpoints TO tb2_collector;
GRANT SELECT ON market.klines_15m TO tb2_trader, tb2_analysis_ro, tb2_backup;
GRANT SELECT ON market.kline_15m_checkpoints TO tb2_trader, tb2_analysis_ro,
    tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '008_persisted_15m_klines',
    encode(
        digest('auto_trade_v2_008_persisted_15m_klines_v1', 'sha256'),
        'hex'
    ),
    'Persist complete Trade 15m OHLCV bars with latest available bucket OI'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
