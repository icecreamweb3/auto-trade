\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '020_training_versions_datasets' AND success
    ) THEN
        RAISE EXCEPTION 'migration 020 was not recorded successfully';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES (
    '51000000-0000-0000-0000-000000000001',
    'dataset-admin@example.test',
    'not-a-real-hash',
    'dataset-admin',
    'ADMIN'
);

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_config_versions (
            config_version_id, config_type, semver, schema_version, config_json,
            content_hash, status, created_by_user_id, ready_by_user_id, ready_at
        ) VALUES (
            '60000000-0000-0000-0000-000000000099',
            'TICKER_POOL_RULES', '99.0.0', 1, '{"rule":"illegal-direct-ready"}',
            encode(digest('{"rule": "illegal-direct-ready"}'::jsonb::text, 'sha256'), 'hex'),
            'READY',
            '51000000-0000-0000-0000-000000000001',
            '51000000-0000-0000-0000-000000000001',
            clock_timestamp()
        );
        RAISE EXCEPTION 'direct READY config insert was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json,
    content_hash, created_by_user_id
)
SELECT config_version_id, config_type, '1.0.0', 1, config_json,
       encode(digest(config_json::text, 'sha256'), 'hex'),
       '51000000-0000-0000-0000-000000000001'
FROM (VALUES
    (
        '60000000-0000-0000-0000-000000000001'::uuid,
        'TICKER_POOL_RULES'::varchar,
        '{"rule":"historical-as-of-pool"}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000002'::uuid,
        'DATA_QUALITY_RULES'::varchar,
        '{"required_dependencies":["KLINE","EMA"],"dependency_rules":{"KLINE":{"minimum_coverage":1,"minimum_effective_samples":1,"minimum_effective_folds":1,"warmup_required":true},"EMA":{"minimum_coverage":1,"minimum_effective_samples":1,"minimum_effective_folds":1,"warmup_required":true}}}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000003'::uuid,
        'HOLDING_HORIZON_RULES'::varchar,
        '{"label_horizon_seconds":86400,"max_holding_seconds":172800}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000004'::uuid,
        'ELIGIBLE_POOL_RULES'::varchar,
        '{"minimum_listing_age_seconds":86400,"minimum_notional_volume":1,"required_contract_type":"USDT_PERPETUAL","liquidity_lookback_seconds":86400}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000005'::uuid,
        'REPRODUCIBILITY_TOLERANCE'::varchar,
        '{"absolute_tolerance":0.000001,"relative_tolerance":0.000001}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000006'::uuid,
        'RESOURCE_LIMITS'::varchar,
        '{"max_heavy_experiments":1,"db_workers_per_experiment":2,"pool_connections":6,"statement_timeout_seconds":900,"lock_timeout_seconds":2,"idle_in_transaction_session_timeout_seconds":60,"work_mem_bytes":67108864,"cpu_limit":4,"memory_bytes":8589934592,"temp_disk_min_free_bytes":1073741824,"max_candidate_count":1000,"max_signal_count":100000,"max_decision_row_count":1000000,"max_storage_bytes":10737418240}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000007'::uuid,
        'FEE_MODEL'::varchar,
        '{"maker_rate":0.0002,"taker_rate":0.0005}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000008'::uuid,
        'SLIPPAGE_MODEL'::varchar,
        '{"model_name":"prototype","notional_coefficient":1,"liquidity_coefficient":1,"volatility_coefficient":1}'::jsonb
    ),
    (
        '60000000-0000-0000-0000-000000000009'::uuid,
        'VISIBILITY_CUTOFF_POLICY'::varchar,
        '{"policy_name":"pre-month","required_lead_seconds":86400}'::jsonb
    )
) AS configs(config_version_id, config_type, config_json);

UPDATE strategy_training.training_config_versions
SET status = 'READY',
    ready_by_user_id = '51000000-0000-0000-0000-000000000001',
    ready_at = clock_timestamp()
WHERE config_version_id::text LIKE '60000000-0000-0000-0000-00000000000%';

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_dataset_versions (
            dataset_version_id, dataset_type, partition,
            partition_start_at, partition_end_at, interval_seconds,
            warmup_start_at, eligible_start_at, eligible_end_at, label_window_end_at,
            source_as_of_at, visibility_cutoff_at, fingerprint_schema_version,
            purge_duration, embargo_duration,
            ticker_pool_rule_version_id, data_quality_rule_version_id,
            holding_rule_version_id, label_horizon_duration, max_holding_duration,
            source_revision_watermark, created_by_user_id
        ) VALUES (
            '70000000-0000-0000-0000-000000000099', 'MODEL_A_FEATURES', 'TEST',
            '2026-08-01 00:00:00+00', '2026-09-01 00:00:00+00', 300,
            '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
            '2026-08-29 00:00:00+00', '2026-08-30 00:00:00+00',
            '2026-10-01 00:00:00+00', '2026-07-31 00:00:00+00', 1,
            interval '2 days', interval '2 days',
            '60000000-0000-0000-0000-000000000001',
            '60000000-0000-0000-0000-000000000002',
            '60000000-0000-0000-0000-000000000003',
            interval '1 day', interval '2 days', '{"revision":"r1"}',
            '51000000-0000-0000-0000-000000000001'
        );
        RAISE EXCEPTION 'TEST partition was accepted in the main training schema';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_dataset_versions (
    dataset_version_id, dataset_type, partition,
    partition_start_at, partition_end_at, interval_seconds,
    warmup_start_at, eligible_start_at, eligible_end_at, label_window_end_at,
    source_as_of_at, visibility_cutoff_at, fingerprint_schema_version,
    purge_duration, embargo_duration,
    ticker_pool_rule_version_id, data_quality_rule_version_id,
    holding_rule_version_id, label_horizon_duration, max_holding_duration,
    source_revision_watermark, created_by_user_id
) VALUES (
    '70000000-0000-0000-0000-000000000001', 'MODEL_A_FEATURES', 'TRAIN',
    '2026-08-01 00:00:00+00', '2026-09-01 00:00:00+00', 300,
    '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
    '2026-08-29 00:00:00+00', '2026-08-30 00:00:00+00',
    '2026-10-01 00:00:00+00', '2026-07-31 00:00:00+00', 1,
    interval '2 days', interval '2 days',
    '60000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000002',
    '60000000-0000-0000-0000-000000000003',
    interval '1 day', interval '2 days', '{"revision":"r1"}',
    '51000000-0000-0000-0000-000000000001'
);

INSERT INTO strategy_training.training_dataset_config_bindings (
    dataset_version_id, config_type, config_version_id
)
SELECT '70000000-0000-0000-0000-000000000001', config_type, config_version_id
FROM strategy_training.training_config_versions
WHERE config_version_id::text LIKE '60000000-0000-0000-0000-00000000000%';

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_dataset_members (
            dataset_version_id, source_schema, source_table, source_shard_identity,
            member_start_at, member_end_at, source_revision_watermark, row_count,
            member_hash, shard_fingerprint, normalized_query_hash
        ) VALUES (
            '70000000-0000-0000-0000-000000000001',
            'strategy_training_test', 'test_entry_events', 'forbidden',
            '2026-07-01 00:00:00+00', '2026-08-30 00:00:00+00',
            '{"revision":"forbidden"}', 1, repeat('1', 64), repeat('2', 64), repeat('3', 64)
        );
        RAISE EXCEPTION 'isolated TEST schema was accepted as a dataset member';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_dataset_members (
    dataset_version_id, source_schema, source_table, source_shard_identity,
    member_start_at, member_end_at, source_revision_watermark, row_count,
    member_hash, shard_fingerprint, normalized_query_hash
) VALUES (
    '70000000-0000-0000-0000-000000000001',
    'market', 'klines', 'BTCUSDT:300:2026-07-01/2026-08-30',
    '2026-07-01 00:00:00+00', '2026-08-30 00:00:00+00',
    '{"revision":"market-r1"}', 17280, repeat('a', 64), repeat('b', 64), repeat('c', 64)
);

INSERT INTO strategy_training.training_data_quality_reports (
    dataset_version_id, data_quality_rule_version_id, dependency_name, dependency_kind,
    is_required, coverage_ratio, missing_ratio, warmup_complete,
    effective_sample_count, effective_fold_count,
    expected_row_count, observed_row_count, missing_row_count,
    status, evidence_json, evidence_hash
)
SELECT '70000000-0000-0000-0000-000000000001',
       '60000000-0000-0000-0000-000000000002', dependency_name, 'MARKET_DATA',
       true, 1, 0, true,
       CASE WHEN dependency_name = 'KLINE' THEN 17280 ELSE 100 END, 1,
       CASE WHEN dependency_name = 'KLINE' THEN 17280 ELSE 100 END,
       CASE WHEN dependency_name = 'KLINE' THEN 17280 ELSE 100 END,
       0, 'PASS', evidence_json,
       encode(digest(evidence_json::text, 'sha256'), 'hex')
FROM (VALUES
    ('KLINE'::varchar, '{"check":"kline-complete"}'::jsonb),
    ('EMA'::varchar, '{"check":"ema-complete"}'::jsonb)
) AS reports(dependency_name, evidence_json);

-- Migration 023 adds later-stage READY gates. Its own integration test covers
-- provenance; these isolated fixtures keep this 020 test focused on 020 guards.
SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_historical_pool_evaluations (
    dataset_version_id, instrument_id, symbol, evaluation_at, onboard_at,
    contract_identity, exchange_status, system_status, status_effective_at,
    status_payload_hash, observed_quote_notional, liquidity_observed_at,
    liquidity_revision_hash, is_eligible, rejection_codes,
    evidence_json, evidence_hash
)
SELECT '70000000-0000-0000-0000-000000000001', 1, 'FIXTUREUSDT',
       '2026-08-01 00:00:00+00', '2025-01-01 00:00:00+00',
       'USDT_PERPETUAL', 'TRADING', 'ACTIVE', '2026-08-01 00:00:00+00',
       repeat('1', 64), 1000, '2026-08-01 00:00:00+00', repeat('2', 64),
       true, '[]'::jsonb, evidence_json,
       encode(digest(evidence_json::text, 'sha256'), 'hex')
FROM (SELECT '{"fixture":"020-isolation"}'::jsonb AS evidence_json) evidence;

INSERT INTO strategy_training.training_resource_preflight_reports (
    dataset_version_id, resource_limit_config_version_id,
    estimated_candidate_count, estimated_signal_count,
    estimated_decision_row_count, estimated_storage_bytes,
    estimated_db_workers, estimated_pool_connections,
    estimated_statement_seconds, estimated_work_mem_bytes,
    estimated_cpu, estimated_memory_bytes, estimated_temp_bytes, available_temp_bytes,
    status, blocking_reasons, evidence_json, evidence_hash
)
SELECT '70000000-0000-0000-0000-000000000001',
       '60000000-0000-0000-0000-000000000006',
       10, 100, 1000, 1048576, 1, 2, 60, 1048576, 1, 1073741824,
       1048576, 2147483648, 'PASS', '[]'::jsonb, evidence_json,
       encode(digest(evidence_json::text, 'sha256'), 'hex')
FROM (SELECT '{"fixture":"020-resource-isolation"}'::jsonb AS evidence_json) evidence;

SET LOCAL session_replication_role = origin;

UPDATE strategy_training.training_dataset_versions
SET root_fingerprint = strategy_training.compute_dataset_root_fingerprint(dataset_version_id)
WHERE dataset_version_id = '70000000-0000-0000-0000-000000000001';

DO $$
BEGIN
    BEGIN
        UPDATE strategy_training.training_dataset_versions
        SET status = 'READY', ready_at = clock_timestamp()
        WHERE dataset_version_id = '70000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'dataset became READY without a COMPLETE manifest';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.reproducibility_manifests (
    reproducibility_manifest_id, object_type, object_id, dataset_version_id
) VALUES (
    '80000000-0000-0000-0000-000000000001', 'DATASET',
    '70000000-0000-0000-0000-000000000001',
    '70000000-0000-0000-0000-000000000001'
);

UPDATE strategy_training.reproducibility_manifests manifest
SET status = 'COMPLETE',
    code_commit = repeat('d', 40),
    image_digest = 'sha256:integration',
    python_version = '3.12',
    system_version = 'integration-linux',
    dependency_lock_hash = repeat('e', 64),
    database_migration_version = '020_training_versions_datasets',
    config_version_ids = (
        SELECT jsonb_agg(config_version_id::text ORDER BY config_type)
        FROM strategy_training.training_dataset_config_bindings
        WHERE dataset_version_id = manifest.dataset_version_id
    ),
    dataset_version_ids = jsonb_build_array(manifest.dataset_version_id::text),
    rule_and_scoring_versions = '{"rules":"bound-configs"}',
    source_root_fingerprint = (
        SELECT root_fingerprint FROM strategy_training.training_dataset_versions
        WHERE dataset_version_id = manifest.dataset_version_id
    ),
    random_seed = 42,
    blas_thread_count = 1,
    openmp_thread_count = 1,
    cpu_count = 4,
    worker_concurrency = 2,
    float_absolute_tolerance = 0.000001,
    float_relative_tolerance = 0.000001,
    normalized_query_hash = repeat('f', 64),
    input_hashes = '{"input":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}',
    output_hashes = '{"output":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}',
    run_command = 'python -m auto_trade.training.dataset_builder',
    completed_at = clock_timestamp()
WHERE reproducibility_manifest_id = '80000000-0000-0000-0000-000000000001';

UPDATE strategy_training.training_dataset_versions
SET status = 'READY', ready_at = clock_timestamp()
WHERE dataset_version_id = '70000000-0000-0000-0000-000000000001';

DO $$
BEGIN
    BEGIN
        UPDATE strategy_training.training_dataset_versions
        SET root_fingerprint = repeat('9', 64)
        WHERE dataset_version_id = '70000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'READY dataset content was rewritten';
    EXCEPTION WHEN check_violation OR object_not_in_prerequisite_state THEN NULL;
    END;
    BEGIN
        INSERT INTO strategy_training.training_dataset_members (
            dataset_version_id, source_schema, source_table, source_shard_identity,
            member_start_at, member_end_at, source_revision_watermark, row_count,
            member_hash, shard_fingerprint, normalized_query_hash
        ) VALUES (
            '70000000-0000-0000-0000-000000000001', 'market', 'klines', 'late-member',
            '2026-07-01 00:00:00+00', '2026-08-30 00:00:00+00',
            '{"revision":"late"}', 1, repeat('1', 64), repeat('2', 64), repeat('3', 64)
        );
        RAISE EXCEPTION 'member was added after dataset READY';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_exposure_records (
    exposure_month, partition, research_exposure_status, visibility_cutoff_at,
    artifact_or_query, impact, evaluation_conclusion, request_id
) VALUES (
    '2026-10-01', 'WEAK_HOLDOUT', 'DECLARED', '2026-10-02 00:00:00+00',
    'diagnostic result', 'weak holdout exposed', 'cannot become TEST',
    '90000000-0000-0000-0000-000000000001'
);

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_exposure_records (
            exposure_month, partition, research_exposure_status, visibility_cutoff_at,
            artifact_or_query, impact, evaluation_conclusion, request_id
        ) VALUES (
            '2026-10-01', 'WEAK_HOLDOUT', 'NONE', '2026-09-01 00:00:00+00',
            'reset attempt', 'none', 'illegal reset',
            '90000000-0000-0000-0000-000000000002'
        );
        RAISE EXCEPTION 'DECLARED exposure was reset to NONE';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_optimizer',
        'strategy_training.training_dataset_versions',
        'SELECT'
    ) OR has_table_privilege(
        'tb2_analysis_ro',
        'strategy_training.training_dataset_versions',
        'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_dataset_versions',
        'SELECT'
    ) THEN
        RAISE EXCEPTION 'training dataset table privilege matrix is incorrect';
    END IF;
END
$$;

ROLLBACK;
