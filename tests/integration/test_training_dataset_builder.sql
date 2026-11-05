\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '023_training_dataset_builder' AND success
    ) THEN
        RAISE EXCEPTION 'migration 023 was not recorded successfully';
    END IF;
END
$$;

DO $$
DECLARE
    shard_function_language text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '058_training_kline_shard_static_pruning' AND success
    ) THEN
        RAISE EXCEPTION 'migration 058 was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '059_training_historical_pool_daily_batch' AND success
    ) THEN
        RAISE EXCEPTION 'migration 059 was not recorded successfully';
    END IF;

    SELECT language.lanname
    INTO STRICT shard_function_language
    FROM pg_proc function
    JOIN pg_language language ON language.oid = function.prolang
    WHERE function.oid =
        'strategy_training.training_kline_source_shard(uuid,bigint,timestamptz,timestamptz)'::regprocedure;

    IF shard_function_language <> 'plpgsql' THEN
        RAISE EXCEPTION 'trusted Kline shard function must use static-pruning implementation';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES (
    'c1000000-0000-0000-0000-000000000001',
    'dataset-builder-admin@example.test', 'not-a-real-hash',
    'dataset-builder-admin', 'ADMIN'
);

INSERT INTO core.app_user_training_identities (
    user_id, natural_person_id, declared_by_user_id, declaration_reason, request_id
) VALUES (
    'c1000000-0000-0000-0000-000000000001',
    'c1000000-0000-0000-0000-000000000002',
    'c1000000-0000-0000-0000-000000000001',
    'dataset builder integration identity',
    'c1000000-0000-0000-0000-000000000003'
);

INSERT INTO core.app_user_training_roles (
    user_id, training_role, granted_by_user_id, grant_reason,
    request_id, valid_from, expires_at
) VALUES (
    'c1000000-0000-0000-0000-000000000001', 'TRAINING_ADMIN',
    'c1000000-0000-0000-0000-000000000001', 'dataset builder integration grant',
    'c1000000-0000-0000-0000-000000000004',
    clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 day'
);

SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json, content_hash,
    status, created_by_user_id, ready_by_user_id, ready_at
)
SELECT config_version_id, config_type, semver, 1, config_json,
       encode(digest(config_json::text, 'sha256'), 'hex'), 'READY',
       'c1000000-0000-0000-0000-000000000001',
       'c1000000-0000-0000-0000-000000000001', clock_timestamp()
FROM (VALUES
    ('c2000000-0000-0000-0000-000000000001'::uuid, 'TICKER_POOL_RULES'::varchar,
     '23.0.1'::varchar,
     '{"policy_name":"UTC_DAILY_2355_TOP_50_D_MINUS_1_V1","source":"market.ranking_snapshots","ranking_type":"UTC_DAILY_2355","as_of_lag_days":1,"top_n":50,"excluded_symbols":[],"required_contract_type":"USDT_PERPETUAL"}'::jsonb),
    ('c2000000-0000-0000-0000-000000000002'::uuid, 'DATA_QUALITY_RULES'::varchar,
     '23.0.2'::varchar,
     '{"required_dependencies":["KLINE"],"dependency_rules":{"KLINE":{"minimum_coverage":1,"minimum_effective_samples":17280,"minimum_effective_folds":1,"warmup_required":true}}}'::jsonb),
    ('c2000000-0000-0000-0000-000000000003'::uuid, 'HOLDING_HORIZON_RULES'::varchar,
     '23.0.3'::varchar,
     '{"label_horizon_seconds":86400,"max_holding_seconds":86400}'::jsonb),
    ('c2000000-0000-0000-0000-000000000004'::uuid, 'ELIGIBLE_POOL_RULES'::varchar,
     '23.0.4'::varchar,
     '{"minimum_listing_age_seconds":86400,"minimum_notional_volume":500,"inferred_trading_minimum_notional_volume":100000,"required_contract_type":"USDT_PERPETUAL","liquidity_lookback_seconds":86400}'::jsonb),
    ('c2000000-0000-0000-0000-000000000005'::uuid, 'RESOURCE_LIMITS'::varchar,
     '23.0.5'::varchar,
     '{"max_heavy_experiments":1,"db_workers_per_experiment":2,"pool_connections":6,"statement_timeout_seconds":900,"lock_timeout_seconds":2,"idle_in_transaction_session_timeout_seconds":60,"work_mem_bytes":67108864,"cpu_limit":4,"memory_bytes":8589934592,"temp_disk_min_free_bytes":1073741824,"max_candidate_count":1000,"max_signal_count":100000,"max_decision_row_count":1000000,"max_storage_bytes":10737418240}'::jsonb),
    ('c2000000-0000-0000-0000-000000000006'::uuid, 'REPRODUCIBILITY_TOLERANCE'::varchar,
     '23.0.6'::varchar,
     '{"absolute_tolerance":0.000000001,"relative_tolerance":0.000000001}'::jsonb),
    ('c2000000-0000-0000-0000-000000000007'::uuid, 'FEE_MODEL'::varchar,
     '23.0.7'::varchar, '{"model":"fixture"}'::jsonb),
    ('c2000000-0000-0000-0000-000000000008'::uuid, 'SLIPPAGE_MODEL'::varchar,
     '23.0.8'::varchar, '{"model":"fixture"}'::jsonb),
    ('c2000000-0000-0000-0000-000000000009'::uuid, 'VISIBILITY_CUTOFF_POLICY'::varchar,
     '23.0.9'::varchar, '{"required_lead_seconds":0}'::jsonb)
) AS configs(config_version_id, config_type, semver, config_json);

SET LOCAL session_replication_role = origin;

INSERT INTO core.instruments (
    exchange, market, symbol, base_asset, quote_asset, contract_type,
    trading_status, onboard_at, first_seen_at, last_seen_at, status_effective_at
) VALUES
(
    'BINANCE', 'USD_M_FUTURES', 'ELIGIBLEUSDT', 'ELIGIBLE', 'USDT', 'PERPETUAL',
    'TRADING', '2025-01-01 00:00:00+00', '2025-01-01 00:00:00+00',
    '2026-07-01 00:00:00+00', '2026-01-01 00:00:00+00'
),
(
    'BINANCE', 'USD_M_FUTURES', 'NEWUSDT', 'NEW', 'USDT', 'PERPETUAL',
    'TRADING', '2026-06-14 12:00:00+00', '2026-06-14 12:00:00+00',
    '2026-07-01 00:00:00+00', '2026-06-14 12:00:00+00'
);

INSERT INTO core.instrument_status_history (
    instrument_id, exchange_status, system_status, discovered_at, effective_at,
    disposition, payload_hash, created_at
)
SELECT instrument_id, 'TRADING', 'ACTIVE', '2026-06-01 00:00:00+00',
       '2026-06-01 00:00:00+00', '{"source":"fixture"}',
       encode(digest(symbol, 'sha256'), 'hex'), '2026-06-01 00:00:00+00'
FROM core.instruments
WHERE symbol = 'NEWUSDT';

INSERT INTO market.klines (
    instrument_id, price_type, interval_seconds, open_time, revision_no, is_current,
    close_time, open_price, high_price, low_price, close_price,
    base_volume, quote_volume, trade_count, is_closed, source,
    data_rule_version, payload_hash, quality_status, collected_at, effective_at
)
SELECT instrument.instrument_id, 'TRADE', 300, slot.open_time, 1, true,
       slot.open_time + interval '5 minutes', 1, 1, 1, 1,
       1000, 1000, 1, true, 'ARCHIVE', 'fixture-v1',
       encode(digest(instrument.symbol || ':' || slot.open_time::text, 'sha256'), 'hex'),
       'VALID', slot.open_time + interval '6 minutes',
       slot.open_time + interval '6 minutes'
FROM core.instruments instrument
CROSS JOIN generate_series(
    '2026-05-01 00:00:00+00'::timestamptz,
    '2026-06-29 23:55:00+00'::timestamptz,
    interval '5 minutes'
) AS slot(open_time)
WHERE instrument.symbol = 'ELIGIBLEUSDT'
  AND slot.open_time <> '2026-06-14 23:55:00+00'::timestamptz;

INSERT INTO market.klines (
    instrument_id, price_type, interval_seconds, open_time, revision_no, is_current,
    close_time, open_price, high_price, low_price, close_price,
    base_volume, quote_volume, trade_count, is_closed, source,
    data_rule_version, payload_hash, quality_status, collected_at, effective_at
)
SELECT instrument_id, 'TRADE', 300, '2026-06-14 23:55:00+00', 1, false,
       '2026-06-15 00:00:00+00', 1, 1, 1, 1,
       1000, 1000, 1, true, 'ARCHIVE', 'fixture-v1',
       encode(digest(symbol || ':revision-1', 'sha256'), 'hex'), 'VALID',
       '2026-06-15 00:01:00+00', '2026-06-15 00:01:00+00'
FROM core.instruments
WHERE symbol IN ('ELIGIBLEUSDT', 'NEWUSDT');

DO $$
BEGIN
    IF has_function_privilege(
        'tb2_training_orchestrator',
        to_regproc('strategy_training.historical_instrument_universe'), 'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        to_regproc('strategy_training.historical_instrument_universe'), 'EXECUTE'
    ) OR has_table_privilege(
        'tb2_training_rw', 'market.klines', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_dataset_members', 'INSERT'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_training_dataset_member(uuid,text,text,text,timestamptz,timestamptz,jsonb,character,character,character,bigint)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_training_kline_dataset_member(uuid,bigint,timestamptz,timestamptz)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.historical_kline_liquidity(bigint,timestamptz,timestamptz,double precision)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_historical_pool_evaluation(uuid,bigint,text,timestamptz,timestamptz,text,text,text,timestamptz,character,numeric,timestamptz,character,boolean,jsonb,jsonb)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_historical_pool_day(uuid,timestamptz)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'dataset builder privilege matrix is incorrect';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.create_training_dataset(
    'MODEL_A_FEATURES', 'TRAIN',
    '2026-06-01 00:00:00+00', '2026-07-01 00:00:00+00', 300,
    '2026-05-01 00:00:00+00', '2026-06-01 00:00:00+00',
    '2026-06-29 00:00:00+00', '2026-06-30 00:00:00+00',
    '2026-07-02 00:00:00+00', '2026-05-31 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'c2000000-0000-0000-0000-000000000001',
    'c2000000-0000-0000-0000-000000000002',
    'c2000000-0000-0000-0000-000000000003',
    interval '1 day', interval '1 day', '{"fixture":"source-v1"}', NULL,
    'c1000000-0000-0000-0000-000000000001'
) AS builder_dataset_id \gset

SELECT strategy_training.bind_training_dataset_config(
    :'builder_dataset_id', config_type, config_version_id
)
FROM strategy_training.training_config_versions
WHERE config_version_id::text LIKE 'c2000000-0000-0000-0000-00000000000%';

RESET ROLE;

INSERT INTO market.ranking_snapshots (
    ranking_snapshot_id, ranking_type, snapshot_at, utc_trade_date, scheduled_at,
    generated_at, generation_mode, source_kline_time, window_start, window_end,
    item_count, snapshot_hash, quality_status, created_at
) VALUES
(
    'c3000000-0000-0000-0000-000000000001', 'UTC_DAILY_2355',
    '2026-06-14 23:55:00+00', '2026-06-14', '2026-06-14 23:55:00+00',
    '2026-07-01 00:00:00+00', 'BACKFILLED', '2026-06-14 23:55:00+00',
    '2026-06-14 00:00:00+00', '2026-06-14 23:55:00+00', 2,
    repeat('3', 64), 'VALID', '2026-07-01 00:00:00+00'
),
(
    'c3000000-0000-0000-0000-000000000002', 'UTC_DAILY_2355',
    '2026-06-15 23:55:00+00', '2026-06-15', '2026-06-15 23:55:00+00',
    '2026-07-01 00:00:00+00', 'BACKFILLED', '2026-06-15 23:55:00+00',
    '2026-06-15 00:00:00+00', '2026-06-15 23:55:00+00', 2,
    repeat('4', 64), 'VALID', '2026-07-01 00:00:00+00'
);

INSERT INTO market.ranking_entries (
    ranking_snapshot_id, rank_no, instrument_id, price_change, quote_volume
)
SELECT snapshot.ranking_snapshot_id,
       row_number() OVER (
           PARTITION BY snapshot.ranking_snapshot_id ORDER BY instrument.symbol
       )::smallint,
       instrument.instrument_id, 1, 1000000
FROM market.ranking_snapshots snapshot
CROSS JOIN core.instruments instrument
WHERE snapshot.ranking_snapshot_id IN (
          'c3000000-0000-0000-0000-000000000001',
          'c3000000-0000-0000-0000-000000000002'
      )
  AND instrument.symbol IN ('ELIGIBLEUSDT', 'NEWUSDT');

CREATE TEMP TABLE first_universe AS
SELECT * FROM strategy_training.historical_instrument_universe(
    :'builder_dataset_id', '2026-06-15 00:00:00+00'
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM first_universe
        WHERE symbol = 'ELIGIBLEUSDT' AND is_eligible AND rejection_codes = '[]'::jsonb
          AND exchange_status = 'TRADING' AND system_status = 'ACTIVE'
          AND status_effective_at = liquidity_observed_at
          AND status_payload_hash IS NOT NULL
    ) OR NOT EXISTS (
        SELECT 1 FROM first_universe
        WHERE symbol = 'NEWUSDT' AND NOT is_eligible
          AND rejection_codes ? 'LISTING_AGE_TOO_SHORT'
    ) THEN
        RAISE EXCEPTION 'historical eligibility did not use status/Kline evidence';
    END IF;
END
$$;

INSERT INTO market.klines (
    instrument_id, price_type, interval_seconds, open_time, revision_no, is_current,
    supersedes_revision, close_time, open_price, high_price, low_price, close_price,
    base_volume, quote_volume, trade_count, is_closed, source,
    data_rule_version, payload_hash, quality_status, collected_at, effective_at
)
SELECT instrument_id, 'TRADE', 300, '2026-06-14 23:55:00+00', 2, false, 1,
       '2026-06-15 00:00:00+00', 1, 1, 1, 1,
       2000, 2000, 1, true, 'BACKFILL', 'fixture-v2',
       encode(digest(symbol || ':future-revision', 'sha256'), 'hex'), 'VALID',
       '2026-07-03 00:00:00+00', '2026-07-03 00:00:00+00'
FROM core.instruments WHERE symbol = 'ELIGIBLEUSDT';

SELECT instrument_id AS eligible_instrument_id
FROM core.instruments WHERE symbol = 'ELIGIBLEUSDT' \gset

DO $$
DECLARE
    fixture_dataset_id uuid;
BEGIN
    SELECT dataset_version_id INTO fixture_dataset_id
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND source_revision_watermark = '{"fixture":"source-v1"}'::jsonb;
    IF (
        SELECT liquidity_revision_hash FROM first_universe WHERE symbol = 'ELIGIBLEUSDT'
    ) IS DISTINCT FROM (
        SELECT liquidity_revision_hash
        FROM strategy_training.historical_instrument_universe(
            fixture_dataset_id, '2026-06-15 00:00:00+00'
        ) WHERE symbol = 'ELIGIBLEUSDT'
    ) THEN
        RAISE EXCEPTION 'revision after source_as_of changed the frozen universe';
    END IF;
END
$$;

INSERT INTO market.klines (
    instrument_id, price_type, interval_seconds, open_time, revision_no, is_current,
    supersedes_revision, close_time, open_price, high_price, low_price, close_price,
    base_volume, quote_volume, trade_count, is_closed, source,
    data_rule_version, payload_hash, quality_status, collected_at, effective_at
)
SELECT instrument_id, 'TRADE', 300, '2026-06-14 23:55:00+00', 3, false, 2,
       '2026-06-15 00:00:00+00', 1, 1, 1, 1,
       3000, 3000, 1, true, 'BACKFILL', 'fixture-v3',
       encode(digest(symbol || ':visible-revision', 'sha256'), 'hex'), 'VALID',
       '2026-07-01 00:00:00+00', '2026-07-01 00:00:00+00'
FROM core.instruments WHERE symbol = 'ELIGIBLEUSDT';

DO $$
DECLARE
    fixture_dataset_id uuid;
BEGIN
    SELECT dataset_version_id INTO fixture_dataset_id
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND source_revision_watermark = '{"fixture":"source-v1"}'::jsonb;
    IF (
        SELECT liquidity_revision_hash FROM first_universe WHERE symbol = 'ELIGIBLEUSDT'
    ) IS NOT DISTINCT FROM (
        SELECT liquidity_revision_hash
        FROM strategy_training.historical_instrument_universe(
            fixture_dataset_id, '2026-06-15 00:00:00+00'
        ) WHERE symbol = 'ELIGIBLEUSDT'
    ) THEN
        RAISE EXCEPTION 'visible source revision did not change the frozen fingerprint';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_rw;

CREATE TEMP TABLE first_day_batch AS
SELECT * FROM strategy_training.record_historical_pool_day(
    :'builder_dataset_id', '2026-06-15 00:00:00+00'
);

CREATE TEMP TABLE first_day_replay AS
SELECT * FROM strategy_training.record_historical_pool_day(
    :'builder_dataset_id', '2026-06-15 00:00:00+00'
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM first_day_batch
        WHERE canonical_count = 2 AND preexisting_count = 0
          AND inserted_count = 2 AND final_count = 2
    ) OR NOT EXISTS (
        SELECT 1 FROM first_day_replay
        WHERE canonical_count = 2 AND preexisting_count = 2
          AND inserted_count = 0 AND final_count = 2
    ) THEN
        RAISE EXCEPTION 'daily historical pool batch is not complete and idempotent';
    END IF;
END
$$;

DO $$
DECLARE
    fixture_dataset_id uuid;
    eligible_instrument_id bigint;
BEGIN
    SELECT dataset_version_id INTO fixture_dataset_id
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND source_revision_watermark = '{"fixture":"source-v1"}'::jsonb;
    SELECT instrument_id INTO eligible_instrument_id
    FROM strategy_training.historical_instrument_universe(
        fixture_dataset_id, '2026-06-16 00:00:00+00'
    ) WHERE symbol = 'ELIGIBLEUSDT';
    BEGIN
        PERFORM strategy_training.record_historical_pool_evaluation(
            fixture_dataset_id, eligible_instrument_id, 'ELIGIBLEUSDT',
            '2026-06-16 00:00:00+00', '2025-01-01 00:00:00+00',
            'USDT_PERPETUAL', 'TRADING', 'ACTIVE', '2026-06-01 00:00:00+00',
            repeat('1', 64), 999999, '2026-06-16 00:00:00+00', repeat('2', 64),
            true, '[]', '{"forged":true}'
        );
        RAISE EXCEPTION 'forged historical eligibility was accepted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;

DO $$
DECLARE
    fixture_dataset_id uuid;
BEGIN
    SELECT dataset_version_id INTO fixture_dataset_id
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND source_revision_watermark = '{"fixture":"source-v1"}'::jsonb;
    BEGIN
        PERFORM strategy_training.record_training_resource_preflight(
            fixture_dataset_id, 'c2000000-0000-0000-0000-000000000005',
            1001, 100, 1000, 1048576, 1, 2, 60, 1048576,
            1, 1073741824, 1048576, 2147483648,
            'PASS', '[]', '{"attempt":"forged-pass"}'
        );
        RAISE EXCEPTION 'over-budget resource estimate was accepted as PASS';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT strategy_training.record_training_resource_preflight(
    :'builder_dataset_id', 'c2000000-0000-0000-0000-000000000005',
    10, 100, 1000, 1048576, 1, 2, 60, 1048576,
    1, 1073741824, 1048576, 2147483648,
    'PASS', '[]', '{"attempt":"within-limits"}'
);

SELECT strategy_training.record_training_kline_dataset_member(
    :'builder_dataset_id', :'eligible_instrument_id',
    '2026-05-01 00:00:00+00', '2026-06-30 00:00:00+00'
);

DO $$
DECLARE
    fixture_dataset_id uuid;
BEGIN
    SELECT dataset_version_id INTO fixture_dataset_id
    FROM strategy_training.training_dataset_versions
    WHERE source_revision_watermark = '{"fixture":"source-v1"}'::jsonb;
    BEGIN
        PERFORM strategy_training.record_training_quality_report(
            fixture_dataset_id, 'c2000000-0000-0000-0000-000000000002',
            'KLINE', 'MARKET_DATA', true, 1, 0, true, 1, 1,
            1, 1, 0, 'PASS', NULL, '{"attempt":"forged-quality"}'
        );
        RAISE EXCEPTION 'forged KLINE quality counts were accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT strategy_training.record_training_quality_report(
    :'builder_dataset_id', 'c2000000-0000-0000-0000-000000000002',
    'KLINE', 'MARKET_DATA', true, 1, 0, true, 17280, 1,
    17280, 17280, 0, 'PASS', NULL, '{"coverage":"complete"}'
);

SELECT strategy_training.finalize_training_dataset_fingerprint(
    :'builder_dataset_id'
) AS first_root_fingerprint \gset

SELECT strategy_training.complete_training_dataset_manifest(
    :'builder_dataset_id', repeat('a', 40), 'sha256:fixture-image-v1',
    '3.12.fixture', 'linux-fixture', repeat('b', 64),
    '024_training_dataset_lifecycle', '{"dataset_builder":"v1"}', 7,
    1, 1, 2, 1, repeat('5', 64),
    jsonb_build_object('source', repeat('4', 64)),
    jsonb_build_object('dataset_root', :'first_root_fingerprint'),
    'python -m auto_trade.training.dataset_builder'
);

RESET ROLE;

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.transition_training_dataset(
    :'builder_dataset_id', 'BUILDING', 'READY',
    'c1000000-0000-0000-0000-000000000001', NULL,
    'dataset builder integration ready',
    'c1000000-0000-0000-0000-000000000010'
);

RESET ROLE;

DO $$
DECLARE
    fixture_dataset_id uuid;
BEGIN
    SELECT dataset_version_id INTO fixture_dataset_id
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND source_revision_watermark = '{"fixture":"source-v1"}'::jsonb;
    IF (SELECT count(*) FROM strategy_training.training_historical_pool_evaluations
        WHERE dataset_version_id = fixture_dataset_id) <> 2
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_resource_preflight_reports
           WHERE dataset_version_id = fixture_dataset_id AND status = 'PASS'
       ) THEN
        RAISE EXCEPTION 'dataset builder facts were not persisted as expected';
    END IF;
END
$$;

INSERT INTO market.klines (
    instrument_id, price_type, interval_seconds, open_time, revision_no, is_current,
    supersedes_revision, close_time, open_price, high_price, low_price, close_price,
    base_volume, quote_volume, trade_count, is_closed, source,
    data_rule_version, payload_hash, quality_status, collected_at, effective_at
)
SELECT instrument_id, 'TRADE', 300, '2026-06-14 23:55:00+00', 4, true, 3,
       '2026-06-15 00:00:00+00', 1, 1, 1, 1,
       4000, 4000, 1, true, 'BACKFILL', 'fixture-v4',
       encode(digest(symbol || ':replacement-revision', 'sha256'), 'hex'), 'VALID',
       '2026-07-03 00:00:00+00', '2026-07-03 00:00:00+00'
FROM core.instruments WHERE symbol = 'ELIGIBLEUSDT';

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.create_training_dataset(
    'MODEL_A_FEATURES', 'TRAIN',
    '2026-06-01 00:00:00+00', '2026-07-01 00:00:00+00', 300,
    '2026-05-01 00:00:00+00', '2026-06-01 00:00:00+00',
    '2026-06-29 00:00:00+00', '2026-06-30 00:00:00+00',
    '2026-07-04 00:00:00+00', '2026-05-31 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'c2000000-0000-0000-0000-000000000001',
    'c2000000-0000-0000-0000-000000000002',
    'c2000000-0000-0000-0000-000000000003',
    interval '1 day', interval '1 day', '{"fixture":"source-v2"}',
    :'builder_dataset_id', 'c1000000-0000-0000-0000-000000000001'
) AS replacement_dataset_id \gset

SELECT strategy_training.bind_training_dataset_config(
    :'replacement_dataset_id', config_type, config_version_id
)
FROM strategy_training.training_config_versions
WHERE config_version_id::text LIKE 'c2000000-0000-0000-0000-00000000000%';

RESET ROLE;
SET LOCAL ROLE tb2_training_rw;

SELECT * FROM strategy_training.record_historical_pool_day(
    :'replacement_dataset_id', '2026-06-15 00:00:00+00'
);

SELECT strategy_training.record_training_resource_preflight(
    :'replacement_dataset_id', 'c2000000-0000-0000-0000-000000000005',
    10, 100, 1000, 1048576, 1, 2, 60, 1048576,
    1, 1073741824, 1048576, 2147483648,
    'PASS', '[]', '{"attempt":"replacement-within-limits"}'
);

SELECT strategy_training.record_training_kline_dataset_member(
    :'replacement_dataset_id', :'eligible_instrument_id',
    '2026-05-01 00:00:00+00', '2026-06-30 00:00:00+00'
);

SELECT strategy_training.record_training_quality_report(
    :'replacement_dataset_id', 'c2000000-0000-0000-0000-000000000002',
    'KLINE', 'MARKET_DATA', true, 1, 0, true, 17280, 1,
    17280, 17280, 0, 'PASS', NULL, '{"coverage":"replacement-complete"}'
);

SELECT strategy_training.finalize_training_dataset_fingerprint(
    :'replacement_dataset_id'
) AS replacement_root_fingerprint \gset

SELECT strategy_training.complete_training_dataset_manifest(
    :'replacement_dataset_id', repeat('a', 40), 'sha256:fixture-image-v1',
    '3.12.fixture', 'linux-fixture', repeat('b', 64),
    '024_training_dataset_lifecycle', '{"dataset_builder":"v1"}', 7,
    1, 1, 2, 1, repeat('5', 64),
    jsonb_build_object('source', repeat('7', 64)),
    jsonb_build_object('dataset_root', :'replacement_root_fingerprint'),
    'python -m auto_trade.training.dataset_builder'
);

RESET ROLE;

-- A recorded historical non-TRADING state is authoritative and must never be
-- overwritten by the Kline-volume fallback, even when volume is sufficient.
INSERT INTO core.instrument_status_history (
    instrument_id, exchange_status, system_status, discovered_at, effective_at,
    disposition, payload_hash, created_at
)
SELECT instrument_id, 'SETTLING', 'INACTIVE', '2026-06-15 00:00:00+00',
       '2026-06-15 00:00:00+00', '{"source":"fixture-explicit-non-trading"}',
       encode(digest(symbol || ':explicit-non-trading', 'sha256'), 'hex'),
       '2026-07-01 00:00:00+00'
FROM core.instruments
WHERE symbol = 'ELIGIBLEUSDT';

DO $$
DECLARE
    replacement_id uuid;
BEGIN
    SELECT dataset_version_id INTO STRICT replacement_id
    FROM strategy_training.training_dataset_versions
    WHERE source_revision_watermark = '{"fixture":"source-v2"}'::jsonb;
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.historical_instrument_universe(
            replacement_id, '2026-06-16 00:00:00+00'
        )
        WHERE symbol = 'ELIGIBLEUSDT'
          AND NOT is_eligible
          AND exchange_status = 'SETTLING'
          AND system_status = 'INACTIVE'
          AND rejection_codes ? 'NOT_TRADING_AT_EVALUATION'
    ) THEN
        RAISE EXCEPTION 'Kline fallback overrode explicit historical non-TRADING status';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.mark_training_dataset_stale_for_replacement(
    :'builder_dataset_id', :'replacement_dataset_id',
    'c1000000-0000-0000-0000-000000000001',
    'source revision changed the replacement root fingerprint',
    'c1000000-0000-0000-0000-000000000011'
);

SELECT strategy_training.transition_training_dataset(
    :'replacement_dataset_id', 'BUILDING', 'READY',
    'c1000000-0000-0000-0000-000000000001', NULL,
    'replacement dataset passed all readiness gates',
    'c1000000-0000-0000-0000-000000000012'
);

SELECT strategy_training.transition_training_dataset(
    :'builder_dataset_id', 'STALE', 'SUPERSEDED',
    'c1000000-0000-0000-0000-000000000001', NULL,
    'READY replacement is available',
    'c1000000-0000-0000-0000-000000000013'
);

RESET ROLE;

DO $$
BEGIN
    IF (
        SELECT first.root_fingerprint = replacement.root_fingerprint
            OR first.status <> 'SUPERSEDED'
            OR replacement.status <> 'READY'
            OR replacement.supersedes_dataset_version_id <> first.dataset_version_id
        FROM strategy_training.training_dataset_versions first
        CROSS JOIN strategy_training.training_dataset_versions replacement
        WHERE first.source_revision_watermark = '{"fixture":"source-v1"}'::jsonb
          AND replacement.source_revision_watermark = '{"fixture":"source-v2"}'::jsonb
    ) THEN
        RAISE EXCEPTION 'source revision replacement lifecycle did not complete';
    END IF;
END
$$;

ROLLBACK;
