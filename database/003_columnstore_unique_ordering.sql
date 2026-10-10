\set ON_ERROR_STOP on
\pset pager off

BEGIN;

-- Include every primary/unique-key column in segment-by or order-by. This
-- avoids Hypercore warnings and preserves uniqueness checks during conversion.
ALTER TABLE market.raw_events SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'event_type',
    timescaledb.orderby = 'symbol, event_time DESC, event_id'
);

ALTER TABLE market.klines SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'instrument_id',
    timescaledb.orderby =
        'price_type, interval_seconds, open_time DESC, revision_no'
);

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '003_columnstore_unique_ordering',
    encode(
        digest('auto_trade_v2_003_columnstore_unique_ordering_v1', 'sha256'),
        'hex'
    ),
    'Include raw-event and kline unique-key columns in Columnstore ordering'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
