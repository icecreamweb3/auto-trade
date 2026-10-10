\set ON_ERROR_STOP on
\pset pager off

BEGIN;

-- Keep the active write/repair window in rowstore while making future chunks
-- small enough to cool independently. Existing chunks retain their old bounds.
SELECT set_chunk_time_interval('market.raw_events', INTERVAL '1 day');
SELECT set_chunk_time_interval('market.klines', INTERVAL '1 day');
SELECT set_chunk_time_interval('market.ticker_minutes', INTERVAL '1 day');
SELECT set_chunk_time_interval('market.funding_observations', INTERVAL '1 day');
SELECT set_chunk_time_interval(
    'market.open_interest_observations', INTERVAL '1 day'
);

-- Hypercore/Columnstore is enabled now, but chunks are converted only after
-- the 72-hour cooling period. This is deliberately longer than the 24-hour
-- automatic repair window.
ALTER TABLE market.raw_events SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'event_type',
    timescaledb.orderby = 'symbol, event_time DESC'
);

ALTER TABLE market.klines SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'instrument_id',
    timescaledb.orderby = 'price_type, interval_seconds, open_time DESC'
);

ALTER TABLE market.ticker_minutes SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'instrument_id',
    timescaledb.orderby = 'minute_time DESC'
);

ALTER TABLE market.funding_observations SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'instrument_id',
    timescaledb.orderby = 'observed_at DESC'
);

-- OI has only about 288 points per instrument/day. Avoiding segment-by keeps
-- compression batches large; instrument_id remains first in the sort order.
ALTER TABLE market.open_interest_observations SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'instrument_id, observed_at DESC'
);

CALL add_columnstore_policy(
    'market.raw_events',
    after => INTERVAL '72 hours',
    if_not_exists => true
);
CALL add_columnstore_policy(
    'market.klines',
    after => INTERVAL '72 hours',
    if_not_exists => true
);
CALL add_columnstore_policy(
    'market.ticker_minutes',
    after => INTERVAL '72 hours',
    if_not_exists => true
);
CALL add_columnstore_policy(
    'market.funding_observations',
    after => INTERVAL '72 hours',
    if_not_exists => true
);
CALL add_columnstore_policy(
    'market.open_interest_observations',
    after => INTERVAL '72 hours',
    if_not_exists => true
);

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '002_storage_optimization',
    encode(
        digest('auto_trade_v2_002_storage_optimization_v1', 'sha256'),
        'hex'
    ),
    'Use daily chunks and a 72-hour Hypercore columnstore cooling policy'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
