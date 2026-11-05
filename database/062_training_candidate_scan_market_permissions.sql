\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Candidate-scan market reads execute inside SECURITY DEFINER functions owned
-- by tb2_training_owner. Dynamic SQL checks the function owner's privileges at
-- execution time, so grant only the three additional source tables required by
-- the scan. The worker role still has no direct market-table access.
GRANT SELECT ON TABLE
    core.instrument_rule_versions,
    market.kline_ema_indicators,
    market.open_interest_observations
TO tb2_training_owner;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '062_training_candidate_scan_market_permissions',
    encode(digest(
        'auto_trade_v2_062_training_candidate_scan_market_permissions_v1',
        'sha256'
    ), 'hex'),
    'Grant the candidate-scan function owner its required market-source reads'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
