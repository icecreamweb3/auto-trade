\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS market.backfill_scan_checkpoints (
    scan_key           varchar(80) PRIMARY KEY,
    cursor_at          timestamptz NOT NULL,
    scan_stop_at       timestamptz NOT NULL,
    config_signature   varchar(120) NOT NULL,
    completed_at       timestamptz,
    created_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (cursor_at <= scan_stop_at)
);

GRANT SELECT, INSERT, UPDATE ON market.backfill_scan_checkpoints TO tb2_collector;
GRANT SELECT ON market.backfill_scan_checkpoints TO tb2_trader, tb2_analysis_ro,
    tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '005_backfill_scan_checkpoints',
    encode(
        digest('auto_trade_v2_005_backfill_scan_checkpoints_v1', 'sha256'),
        'hex'
    ),
    'Persist historical backfill scan progress across service restarts'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
