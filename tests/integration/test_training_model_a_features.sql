\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '026_training_model_a_features' AND success
    ) OR NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '028_training_model_a_config_contracts' AND success
    ) THEN
        RAISE EXCEPTION 'model-A migrations were not recorded successfully';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES (
    'd1000000-0000-0000-0000-000000000001',
    'model-a-fixture@example.test', 'not-a-real-hash', 'model-a-fixture', 'ADMIN'
);

DO $$
DECLARE
    invalid_config jsonb := '{"sample_count":2,"minimum_frame_size":3,"exclusion_window_seconds":300,"matching_fields":["instrument_id","pool_identity"]}'::jsonb;
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_config_versions (
            config_version_id, config_type, semver, schema_version, config_json,
            content_hash, created_by_user_id
        ) VALUES (
            'd2000000-0000-0000-0000-000000000099', 'RANDOM_BASELINE',
            '26.0.99', 1, invalid_config,
            encode(digest(invalid_config::text, 'sha256'), 'hex'),
            'd1000000-0000-0000-0000-000000000001'
        );
        UPDATE strategy_training.training_config_versions
        SET status = 'READY',
            ready_by_user_id = 'd1000000-0000-0000-0000-000000000001',
            ready_at = clock_timestamp()
        WHERE config_version_id = 'd2000000-0000-0000-0000-000000000099';
        RAISE EXCEPTION 'incomplete random-baseline strata were accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json,
    content_hash, status, created_by_user_id, ready_by_user_id, ready_at
)
SELECT config_id, config_type, semver, 1, config_json,
       encode(digest(config_json::text, 'sha256'), 'hex'), 'READY',
       'd1000000-0000-0000-0000-000000000001',
       'd1000000-0000-0000-0000-000000000001', clock_timestamp()
FROM (VALUES
    ('d2000000-0000-0000-0000-000000000001'::uuid, 'TICKER_POOL_RULES'::varchar,
     '26.0.1'::varchar, '{"rule":"fixture"}'::jsonb),
    ('d2000000-0000-0000-0000-000000000002'::uuid, 'DATA_QUALITY_RULES'::varchar,
     '26.0.2'::varchar,
     '{"required_dependencies":["KLINE"],"dependency_rules":{"KLINE":{"minimum_coverage":1,"minimum_effective_samples":1,"minimum_effective_folds":1,"warmup_required":true}}}'::jsonb),
    ('d2000000-0000-0000-0000-000000000003'::uuid, 'HOLDING_HORIZON_RULES'::varchar,
     '26.0.3'::varchar,
     '{"label_horizon_seconds":86400,"max_holding_seconds":86400}'::jsonb),
    ('d2000000-0000-0000-0000-000000000004'::uuid, 'RESOURCE_LIMITS'::varchar,
     '26.0.4'::varchar,
     '{"db_workers_per_experiment":2,"pool_connections":6,"statement_timeout_seconds":900,"work_mem_bytes":67108864,"cpu_limit":4,"memory_bytes":8589934592,"temp_disk_min_free_bytes":1073741824,"max_candidate_count":1000,"max_signal_count":100000,"max_decision_row_count":1000000,"max_storage_bytes":10737418240}'::jsonb),
    ('d2000000-0000-0000-0000-000000000005'::uuid, 'FACTOR_REGISTRY'::varchar,
     '26.0.5'::varchar,
     '{"adapter_version":"feature-scan-v2","factors":["factor-a","factor-b"]}'::jsonb),
    ('d2000000-0000-0000-0000-000000000006'::uuid, 'SEARCH_SPACE'::varchar,
     '26.0.6'::varchar,
     '{"interval_seconds":300,"strategy_parameters":{"required_factors":["factor-a","factor-b"]}}'::jsonb),
    ('d2000000-0000-0000-0000-000000000007'::uuid,
     'OPPORTUNITY_DEFINITION'::varchar, '26.0.7'::varchar,
     '{"minimum_mfe_percent":5,"maximum_mae_percent":2,"minimum_return_percent":3}'::jsonb),
    ('d2000000-0000-0000-0000-000000000008'::uuid,
     'RANDOM_BASELINE'::varchar, '26.0.8'::varchar,
     '{"sample_count":2,"minimum_frame_size":3,"exclusion_window_seconds":300,"random_seed":42,"matching_fields":["instrument_id","pool_identity","time_bucket","volatility_bucket","liquidity_bucket","btc_regime"]}'::jsonb),
    ('d2000000-0000-0000-0000-000000000009'::uuid,
     'EXIT_RULES'::varchar, '26.0.9'::varchar,
     '{"stop_loss_percent":2,"take_profit_percent":3,"trailing_activation_percent":0,"trailing_distance_percent":0,"max_holding_seconds":600,"intrabar_conflict_policy":"WORST_CASE"}'::jsonb),
    ('d2000000-0000-0000-0000-000000000010'::uuid,
     'FEE_MODEL'::varchar, '26.0.10'::varchar,
     '{"maker_rate":0.0002,"taker_rate":0.0004}'::jsonb),
    ('d2000000-0000-0000-0000-000000000011'::uuid,
     'SLIPPAGE_MODEL'::varchar, '26.0.11'::varchar,
     '{"model_name":"bounded-linear-v1","notional_coefficient":0,"liquidity_coefficient":0,"volatility_coefficient":0,"base_basis_points":1,"reference_notional":1000,"maximum_basis_points":10}'::jsonb),
    ('d2000000-0000-0000-0000-000000000012'::uuid,
     'PORTFOLIO_RULES'::varchar, '26.0.12'::varchar,
     '{"initial_capital":2000,"notional_per_trade":1000,"maximum_concurrent_positions":1,"same_ticker_position_policy":"ONE_OPEN_POSITION"}'::jsonb)
) configs(config_id, config_type, semver, config_json);

INSERT INTO strategy_training.training_dataset_versions (
    dataset_version_id, dataset_type, partition,
    partition_start_at, partition_end_at, interval_seconds,
    warmup_start_at, eligible_start_at, eligible_end_at, label_window_end_at,
    source_as_of_at, visibility_cutoff_at, fingerprint_schema_version,
    purge_duration, embargo_duration,
    ticker_pool_rule_version_id, data_quality_rule_version_id,
    holding_rule_version_id, label_horizon_duration, max_holding_duration,
    root_fingerprint, source_revision_watermark, status,
    created_by_user_id, ready_at
) VALUES (
    'd3000000-0000-0000-0000-000000000001', 'MODEL_A_FEATURES', 'TRAIN',
    '2026-06-01 00:00:00+00', '2026-07-01 00:00:00+00', 300,
    '2026-05-01 00:00:00+00', '2026-06-01 00:00:00+00',
    '2026-06-29 00:00:00+00', '2026-06-30 00:00:00+00',
    '2026-07-02 00:00:00+00', '2026-05-31 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'd2000000-0000-0000-0000-000000000001',
    'd2000000-0000-0000-0000-000000000002',
    'd2000000-0000-0000-0000-000000000003',
    interval '1 day', interval '1 day', repeat('1', 64),
    '{"fixture":"model-a"}', 'READY',
    'd1000000-0000-0000-0000-000000000001', clock_timestamp()
);

INSERT INTO strategy_training.training_experiments (
    experiment_id, experiment_mode, dataset_version_id,
    resource_limit_config_version_id, experiment_name, state,
    exposure_identity_hash, created_by_user_id, started_at
) VALUES (
    'd4000000-0000-0000-0000-000000000001', 'DISCOVERY',
    'd3000000-0000-0000-0000-000000000001',
    'd2000000-0000-0000-0000-000000000004',
    'model-a feature fixture', 'RUNNING', repeat('2', 64),
    'd1000000-0000-0000-0000-000000000001', clock_timestamp()
);

INSERT INTO strategy_training.training_experiment_config_bindings (
    experiment_id, config_type, config_version_id
) VALUES
    ('d4000000-0000-0000-0000-000000000001', 'FACTOR_REGISTRY',
     'd2000000-0000-0000-0000-000000000005'),
    ('d4000000-0000-0000-0000-000000000001', 'SEARCH_SPACE',
     'd2000000-0000-0000-0000-000000000006'),
    ('d4000000-0000-0000-0000-000000000001', 'OPPORTUNITY_DEFINITION',
     'd2000000-0000-0000-0000-000000000007'),
    ('d4000000-0000-0000-0000-000000000001', 'RANDOM_BASELINE',
     'd2000000-0000-0000-0000-000000000008');

INSERT INTO strategy_training.training_iterations (
    iteration_id, experiment_id, candidate_version, candidate_source,
    random_seed, candidate_parameters, candidate_content_hash,
    resource_budget, state, validation_started_at, run_started_at
)
SELECT 'd5000000-0000-0000-0000-000000000001',
       'd4000000-0000-0000-0000-000000000001', 1, 'FIXED_BASELINE', 7,
       parameters, encode(digest(parameters::text, 'sha256'), 'hex'),
       '{"worker":1}'::jsonb, 'RUNNING', clock_timestamp(), clock_timestamp()
FROM (SELECT '{"baseline":"v2"}'::jsonb AS parameters) fixture;

INSERT INTO strategy_training.training_experiments (
    experiment_id, experiment_mode, dataset_version_id,
    resource_limit_config_version_id, experiment_name, state,
    exposure_identity_hash, created_by_user_id, started_at
) VALUES (
    'd4000000-0000-0000-0000-000000000002', 'EXIT_POLICY',
    'd3000000-0000-0000-0000-000000000001',
    'd2000000-0000-0000-0000-000000000004',
    'model-b fixed exit fixture', 'RUNNING', repeat('8', 64),
    'd1000000-0000-0000-0000-000000000001', clock_timestamp()
);

INSERT INTO strategy_training.training_experiment_config_bindings (
    experiment_id, config_type, config_version_id
) VALUES
    ('d4000000-0000-0000-0000-000000000002', 'EXIT_RULES',
     'd2000000-0000-0000-0000-000000000009'),
    ('d4000000-0000-0000-0000-000000000002', 'FEE_MODEL',
     'd2000000-0000-0000-0000-000000000010'),
    ('d4000000-0000-0000-0000-000000000002', 'SLIPPAGE_MODEL',
     'd2000000-0000-0000-0000-000000000011'),
    ('d4000000-0000-0000-0000-000000000002', 'PORTFOLIO_RULES',
     'd2000000-0000-0000-0000-000000000012');

INSERT INTO strategy_training.training_iterations (
    iteration_id, experiment_id, candidate_version, candidate_source,
    random_seed, candidate_parameters, candidate_content_hash,
    resource_budget, state, validation_started_at, run_started_at
)
SELECT 'd5000000-0000-0000-0000-000000000002',
       'd4000000-0000-0000-0000-000000000002', 1, 'FIXED_BASELINE', 11,
       parameters, encode(digest(parameters::text, 'sha256'), 'hex'),
       '{"worker":1}'::jsonb, 'RUNNING', clock_timestamp(), clock_timestamp()
FROM (SELECT '{"fixed_exit":"v1"}'::jsonb AS parameters) fixture;

INSERT INTO core.instruments (
    instrument_id, exchange, market, symbol, base_asset, quote_asset,
    contract_type, trading_status, onboard_at, first_seen_at,
    last_seen_at, status_effective_at
) OVERRIDING SYSTEM VALUE VALUES (
    2600001, 'BINANCE', 'USD_M_FUTURES', 'MODELUSDT', 'MODEL', 'USDT',
    'PERPETUAL', 'TRADING', '2025-01-01 00:00:00+00',
    '2025-01-01 00:00:00+00', '2026-07-01 00:00:00+00',
    '2026-01-01 00:00:00+00'
);

INSERT INTO strategy_training.training_historical_pool_evaluations (
    pool_evaluation_id, dataset_version_id, instrument_id, symbol,
    evaluation_at, onboard_at, contract_identity,
    exchange_status, system_status, status_effective_at,
    status_payload_hash, observed_quote_notional, liquidity_observed_at,
    liquidity_revision_hash, is_eligible, rejection_codes,
    evidence_json, evidence_hash
)
SELECT 'd6000000-0000-0000-0000-000000000001',
       'd3000000-0000-0000-0000-000000000001', 2600001, 'MODELUSDT',
       '2026-06-10 00:00:00+00', '2025-01-01 00:00:00+00',
       'USDT_PERPETUAL', 'TRADING', 'ACTIVE', '2026-06-01 00:00:00+00',
       repeat('3', 64), 1000000, '2026-06-10 00:00:00+00', repeat('4', 64),
       true, '[]'::jsonb, evidence,
       encode(digest(evidence::text, 'sha256'), 'hex')
FROM (SELECT '{"fixture":"eligible"}'::jsonb AS evidence) source;

INSERT INTO market.klines (
    instrument_id, price_type, interval_seconds, open_time, revision_no,
    is_current, close_time, open_price, high_price, low_price, close_price,
    base_volume, quote_volume, trade_count, is_closed, source,
    data_rule_version, payload_hash, quality_status, collected_at, effective_at
) VALUES
    (2600001, 'TRADE', 300, '2026-06-10 01:05:00+00', 1, true,
     '2026-06-10 01:10:00+00', 100, 102, 99, 101,
     10000, 1000000, 100, true, 'ARCHIVE', 'fixture-v1', repeat('b', 64),
     'VALID', '2026-06-10 01:11:00+00', '2026-06-10 01:11:00+00'),
    (2600001, 'TRADE', 300, '2026-06-10 01:10:00+00', 1, true,
     '2026-06-10 01:15:00+00', 101, 111, 100, 110,
     10000, 1100000, 100, true, 'ARCHIVE', 'fixture-v1', repeat('c', 64),
     'VALID', '2026-06-10 01:16:00+00', '2026-06-10 01:16:00+00');

SET LOCAL session_replication_role = origin;

SELECT strategy_training.compute_training_entry_event_id(
    'd3000000-0000-0000-0000-000000000001',
    'd5000000-0000-0000-0000-000000000001',
    'MODELUSDT', '2026-06-10 01:00:00+00', '2026-06-10 01:05:00+00', 'LONG'
) AS entry_event_id \gset

DO $$
BEGIN
    IF strategy_training.compute_training_entry_event_id(
        'd3000000-0000-0000-0000-000000000001',
        'd5000000-0000-0000-0000-000000000001',
        'MODELUSDT', '2026-06-10 01:00:00+00',
        '2026-06-10 01:05:00+00', 'LONG'
    ) <> 'ff15d4f70eae9cacf879d83da0eb772dc448e8e8170edf4e5930abef1d68c234' THEN
        RAISE EXCEPTION 'SQL/Python entry identity contract diverged';
    END IF;
END
$$;

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_entry_events', 'INSERT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_feature_snapshots', 'INSERT'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.create_training_entry_event(character,uuid,uuid,bigint,text,timestamptz,timestamptz,text,numeric,numeric,numeric,numeric,uuid,uuid,uuid,uuid,character)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'model-A feature privilege matrix is incorrect';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_rw;

DO $$
BEGIN
    BEGIN
        PERFORM strategy_training.create_training_entry_event(
            repeat('0', 64),
            'd3000000-0000-0000-0000-000000000001',
            'd5000000-0000-0000-0000-000000000001', 2600001, 'MODELUSDT',
            '2026-06-10 01:00:00+00', '2026-06-10 01:05:00+00', 'LONG',
            75, 80, 99, 100, 'd6000000-0000-0000-0000-000000000001',
            'd2000000-0000-0000-0000-000000000001',
            'd2000000-0000-0000-0000-000000000005',
            'd2000000-0000-0000-0000-000000000006', repeat('5', 64)
        );
        RAISE EXCEPTION 'forged entry identity was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT strategy_training.create_training_entry_event(
    :'entry_event_id',
    'd3000000-0000-0000-0000-000000000001',
    'd5000000-0000-0000-0000-000000000001', 2600001, 'MODELUSDT',
    '2026-06-10 01:00:00+00', '2026-06-10 01:05:00+00', 'LONG',
    75, 80, 99, 100, 'd6000000-0000-0000-0000-000000000001',
    'd2000000-0000-0000-0000-000000000001',
    'd2000000-0000-0000-0000-000000000005',
    'd2000000-0000-0000-0000-000000000006', repeat('5', 64)
);

SELECT strategy_training.record_training_feature_snapshot(
    :'entry_event_id', 'd2000000-0000-0000-0000-000000000005',
    'factor-a', true, true, '1.25'::jsonb, '>= 1', NULL,
    '{"window":4}', 80, 10, 8, repeat('6', 64)
);

DO $$
DECLARE
    fixture_entry_id char(64);
BEGIN
    SELECT entry_event_id INTO STRICT fixture_entry_id
    FROM strategy_training.training_entry_events
    WHERE symbol = 'MODELUSDT';
    BEGIN
        PERFORM strategy_training.finalize_training_entry_event(fixture_entry_id);
        RAISE EXCEPTION 'entry finalized without every registry factor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT strategy_training.record_training_feature_snapshot(
    :'entry_event_id', 'd2000000-0000-0000-0000-000000000005',
    'factor-b', false, false, NULL, '>= 1', 'OI unavailable',
    '{"availability":"missing"}', 0, 10, 0, repeat('7', 64)
);

SELECT strategy_training.finalize_training_entry_event(:'entry_event_id');

RESET ROLE;

DO $$
DECLARE
    fixture_entry_id char(64);
BEGIN
    SELECT entry_event_id INTO STRICT fixture_entry_id
    FROM strategy_training.training_entry_events
    WHERE symbol = 'MODELUSDT';
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_entry_events
        WHERE entry_event_id = fixture_entry_id AND status = 'COMPLETE'
    ) OR (SELECT count(*) FROM strategy_training.training_feature_snapshots
          WHERE entry_event_id = fixture_entry_id) <> 2
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_feature_snapshots
           WHERE entry_event_id = fixture_entry_id AND factor_name = 'factor-b'
             AND NOT available AND value_json IS NULL AND reason = 'OI unavailable'
       ) THEN
        RAISE EXCEPTION 'model-A entry/factor facts were not completed as expected';
    END IF;
    BEGIN
        UPDATE strategy_training.training_entry_events
        SET trigger_score = 99 WHERE entry_event_id = fixture_entry_id;
        RAISE EXCEPTION 'completed entry event was mutable';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END
$$;

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_entry_outcomes', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_opportunity_events', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_random_entry_baselines', 'SELECT'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.record_training_entry_outcome(character,uuid,timestamptz,integer,integer,integer,integer,boolean,text,numeric,numeric,numeric,timestamptz,timestamptz,timestamptz,character)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'model-A label privilege matrix is incorrect';
    END IF;
END
$$;

INSERT INTO strategy_training.training_tasks (
    task_id, experiment_id, iteration_id, task_type, executor_kind,
    idempotency_key, task_payload, state, attempt_count,
    lease_token, leased_by, lease_expires_at, started_at
) VALUES (
    'd9000000-0000-0000-0000-000000000001',
    'd4000000-0000-0000-0000-000000000001',
    'd5000000-0000-0000-0000-000000000001',
    'MODEL_A_EVALUATION', 'EVALUATOR', repeat('d', 64),
    jsonb_build_object(
        'task_type', 'MODEL_A_EVALUATION',
        'payload_version', 1,
        'entry_event_ids', jsonb_build_array(:'entry_event_id')
    ),
    'RUNNING', 1, 'd9000000-0000-0000-0000-000000000002',
    'model-a-evaluator-fixture', clock_timestamp() + interval '5 minutes',
    clock_timestamp()
);

SET LOCAL ROLE tb2_training_evaluator;

DO $$
DECLARE
    context_count integer;
BEGIN
    SELECT count(*) INTO context_count
    FROM strategy_training.training_model_a_evaluation_context(
        'd9000000-0000-0000-0000-000000000001',
        'd9000000-0000-0000-0000-000000000002',
        'ff15d4f70eae9cacf879d83da0eb772dc448e8e8170edf4e5930abef1d68c234'
    );
    IF context_count <> 1 THEN
        RAISE EXCEPTION 'leased MODEL_A evaluation context was not returned';
    END IF;
    BEGIN
        PERFORM strategy_training.training_model_a_evaluation_context(
            'd9000000-0000-0000-0000-000000000001',
            'd9000000-0000-0000-0000-000000000099',
            'ff15d4f70eae9cacf879d83da0eb772dc448e8e8170edf4e5930abef1d68c234'
        );
        RAISE EXCEPTION 'forged evaluator lease was accepted';
    EXCEPTION WHEN serialization_failure THEN NULL;
    END;
END
$$;

RESET ROLE;

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_rw',
        'strategy_training.training_random_baseline_candidates',
        'INSERT'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_training_random_baseline_candidate(character,uuid,uuid,bigint,timestamptz,text,uuid,uuid,numeric,numeric,text,text,text,timestamptz,timestamptz,timestamptz,jsonb)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_random_baseline_candidate_frame(uuid,uuid,character)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'random-baseline candidate frame privilege matrix is incorrect';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_rw;

SELECT strategy_training.record_training_random_baseline_signal_stratum(
    :'entry_event_id', 'd2000000-0000-0000-0000-000000000008',
    'VOL-2', 'LIQ-3', 'BTC-UP',
    '2026-06-09 01:00:00+00', '2026-06-09 01:00:00+00',
    '2026-06-09 01:00:00+00',
    '{"source":"pre-signal-strata","version":1}'::jsonb
);

DO $$
DECLARE
    candidate_time timestamptz;
    candidate_id char(64);
BEGIN
    FOREACH candidate_time IN ARRAY ARRAY[
        '2026-06-10 01:05:00+00'::timestamptz,
        '2026-06-10 01:15:00+00'::timestamptz,
        '2026-06-10 01:20:00+00'::timestamptz,
        '2026-06-10 01:25:00+00'::timestamptz,
        '2026-06-10 01:30:00+00'::timestamptz
    ] LOOP
        candidate_id := strategy_training.compute_training_random_baseline_candidate_id(
            'd3000000-0000-0000-0000-000000000001',
            'd5000000-0000-0000-0000-000000000001',
            2600001, candidate_time, 'LONG'
        );
        PERFORM strategy_training.record_training_random_baseline_candidate(
            candidate_id,
            'd3000000-0000-0000-0000-000000000001',
            'd5000000-0000-0000-0000-000000000001',
            2600001, candidate_time, 'LONG',
            'd6000000-0000-0000-0000-000000000001',
            'd2000000-0000-0000-0000-000000000008',
            60, 75, 'VOL-2', 'LIQ-3', 'BTC-UP',
            candidate_time - interval '1 hour',
            candidate_time - interval '1 hour',
            candidate_time - interval '1 hour',
            jsonb_build_object(
                'candidate_triggered', true,
                'observed_at', candidate_time,
                'source', 'low-cost-scan-v1'
            )
        );
    END LOOP;

    BEGIN
        PERFORM strategy_training.record_training_random_baseline_candidate(
            repeat('0', 64),
            'd3000000-0000-0000-0000-000000000001',
            'd5000000-0000-0000-0000-000000000001',
            2600001, '2026-06-10 01:35:00+00', 'LONG',
            'd6000000-0000-0000-0000-000000000001',
            'd2000000-0000-0000-0000-000000000008',
            60, 75, 'VOL-2', 'LIQ-3', 'BTC-UP',
            '2026-06-10 00:35:00+00', '2026-06-10 00:35:00+00',
            '2026-06-10 00:35:00+00',
            '{"candidate_triggered":true,"source":"forged-id"}'::jsonb
        );
        RAISE EXCEPTION 'forged random-baseline candidate identity was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

RESET ROLE;
SET LOCAL ROLE tb2_training_evaluator;

DO $$
DECLARE
    context_record record;
    frame_count integer;
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_random_baseline_evaluation_context(
        'd9000000-0000-0000-0000-000000000001',
        'd9000000-0000-0000-0000-000000000002',
        'ff15d4f70eae9cacf879d83da0eb772dc448e8e8170edf4e5930abef1d68c234'
    );
    IF context_record.sample_count <> 2
       OR context_record.minimum_frame_size <> 3
       OR context_record.random_seed <> 42
       OR cardinality(context_record.signal_times) <> 1
       OR context_record.pool_identity <> 'd2000000-0000-0000-0000-000000000001'
       OR context_record.time_bucket <> 'UTC-01' THEN
        RAISE EXCEPTION 'leased random-baseline context is incomplete';
    END IF;
    SELECT count(*) INTO frame_count
    FROM strategy_training.training_random_baseline_candidate_frame(
        'd9000000-0000-0000-0000-000000000001',
        'd9000000-0000-0000-0000-000000000002',
        'ff15d4f70eae9cacf879d83da0eb772dc448e8e8170edf4e5930abef1d68c234'
    );
    IF frame_count <> 5 THEN
        RAISE EXCEPTION 'trusted random-baseline frame expected 5 candidates, received %',
            frame_count;
    END IF;
    BEGIN
        PERFORM strategy_training.training_random_baseline_candidate_frame(
            'd9000000-0000-0000-0000-000000000001',
            'd9000000-0000-0000-0000-000000000099',
            'ff15d4f70eae9cacf879d83da0eb772dc448e8e8170edf4e5930abef1d68c234'
        );
        RAISE EXCEPTION 'forged lease read a random-baseline frame';
    EXCEPTION WHEN serialization_failure THEN NULL;
    END;
END
$$;

DO $$
DECLARE
    fixture_entry_id char(64);
BEGIN
    SELECT entry_event_id INTO STRICT fixture_entry_id
    FROM strategy_training.training_entry_events
    WHERE symbol = 'MODELUSDT';
    BEGIN
        PERFORM strategy_training.record_training_entry_outcome(
            fixture_entry_id, 'd2000000-0000-0000-0000-000000000003',
            '2026-06-11 01:05:00+00', 300, 288, 287, 1,
            false, 'MISSING_BARS', NULL, NULL, NULL,
            NULL, NULL, '2026-06-11 01:05:00+00', repeat('8', 64)
        );
        PERFORM strategy_training.record_training_opportunity_event(
            fixture_entry_id, 'd2000000-0000-0000-0000-000000000007'
        );
        RAISE EXCEPTION 'incomplete label became opportunity truth';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT strategy_training.record_training_entry_outcome(
    :'entry_event_id', 'd2000000-0000-0000-0000-000000000003',
    '2026-06-11 01:05:00+00', 300, 288, 288, 0,
    true, NULL, 6, 1, 4,
    '2026-06-10 08:00:00+00', '2026-06-10 03:00:00+00',
    '2026-06-11 01:05:00+00', repeat('9', 64)
);

SELECT strategy_training.record_training_opportunity_event(
    :'entry_event_id', 'd2000000-0000-0000-0000-000000000007'
);

DO $$
DECLARE
    fixture_entry_id char(64);
    selected_ids jsonb;
    frame_size integer;
    overlap_count integer;
    frame_hash char(64);
BEGIN
    SELECT entry_event_id INTO STRICT fixture_entry_id
    FROM strategy_training.training_entry_events WHERE symbol = 'MODELUSDT';
    BEGIN
        PERFORM strategy_training.record_training_random_baseline(
            fixture_entry_id, 'd2000000-0000-0000-0000-000000000008',
            '{"instrument_id":2600001,"pool_identity":"d2000000-0000-0000-0000-000000000001","time_bucket":"UTC-01","volatility_bucket":"VOL-2","liquidity_bucket":"LIQ-3","btc_regime":"BTC-UP"}',
            '["candidate-a","candidate-b"]', 4, 0.5, 42, repeat('a', 64), 1
        );
        RAISE EXCEPTION 'forged baseline candidate IDs were accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    WITH eligible AS (
        SELECT candidate.*
        FROM strategy_training.training_random_baseline_candidates candidate
        WHERE candidate.generating_iteration_id =
              'd5000000-0000-0000-0000-000000000001'
          AND candidate.instrument_id = 2600001
          AND NOT EXISTS (
              SELECT 1 FROM strategy_training.training_entry_events signal
              WHERE signal.generating_iteration_id = candidate.generating_iteration_id
                AND signal.instrument_id = candidate.instrument_id
                AND signal.status = 'COMPLETE'
                AND abs(extract(epoch FROM (
                    candidate.observed_at - signal.signal_time
                ))) <= 300
          )
    ), ranked AS (
        SELECT eligible.*,
               encode(digest(format('%s:%s:%s', 42, fixture_entry_id, candidate_id),
                             'sha256'), 'hex') AS sampling_rank
        FROM eligible
    )
    SELECT count(*),
           5 - count(*),
           encode(digest(string_agg(
               candidate_id::text || '|' ||
               to_char(observed_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               E'\n' ORDER BY candidate_id
           ), 'sha256'), 'hex'),
           (SELECT jsonb_agg(to_jsonb(candidate_id::text)
                             ORDER BY sampling_rank, candidate_id)
            FROM (SELECT * FROM ranked
                  ORDER BY sampling_rank, candidate_id LIMIT 2) selected)
    INTO frame_size, overlap_count, frame_hash, selected_ids
    FROM eligible;

    PERFORM strategy_training.record_training_random_baseline(
        fixture_entry_id, 'd2000000-0000-0000-0000-000000000008',
        '{"instrument_id":2600001,"pool_identity":"d2000000-0000-0000-0000-000000000001","time_bucket":"UTC-01","volatility_bucket":"VOL-2","liquidity_bucket":"LIQ-3","btc_regime":"BTC-UP"}',
        selected_ids, frame_size, 2::numeric / frame_size,
        42, frame_hash, overlap_count
    );
END
$$;

RESET ROLE;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_entry_outcomes
        WHERE is_complete AND mfe_percent = 6 AND mae_percent = 1
          AND return_percent = 4
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_opportunity_events
        WHERE is_opportunity AND reason_codes = '[]'::jsonb
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_random_entry_baselines
        WHERE sampling_frame_size = 4 AND inclusion_probability = 0.5
          AND overlap_excluded_count = 1
    ) THEN
        RAISE EXCEPTION 'model-A label/opportunity/baseline facts are incomplete';
    END IF;
END
$$;

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_model_b', 'strategy_training.training_model_b_sample_map', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_model_b', 'strategy_training.training_entry_outcomes', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_model_b', 'strategy_training.training_exit_outcomes', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_model_b', 'market.klines', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_model_b', 'strategy_training.model_b_entry_inputs', 'SELECT'
    ) OR NOT has_function_privilege(
        'tb2_training_model_b',
        'strategy_training.model_b_market_asof(character,timestamptz,integer)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_model_b',
        'strategy_training.training_model_b_replay_context(uuid,uuid,character)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_portfolio_evaluation_context(uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'model-B isolation privilege matrix is incorrect';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_evaluator;

SELECT * FROM strategy_training.create_training_exit_episode(
    :'entry_event_id', 'd5000000-0000-0000-0000-000000000002',
    'd2000000-0000-0000-0000-000000000009',
    'd2000000-0000-0000-0000-000000000010',
    'd2000000-0000-0000-0000-000000000011'
) \gset

RESET ROLE;

SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_resource_preflight_reports (
    resource_preflight_id, dataset_version_id, resource_limit_config_version_id,
    estimated_candidate_count, estimated_signal_count, estimated_decision_row_count,
    estimated_storage_bytes, estimated_db_workers, estimated_pool_connections,
    estimated_statement_seconds, estimated_work_mem_bytes, estimated_cpu,
    estimated_memory_bytes, estimated_temp_bytes, available_temp_bytes,
    status, blocking_reasons, evidence_json, evidence_hash
) VALUES (
    'd7000000-0000-0000-0000-000000000001',
    'd3000000-0000-0000-0000-000000000001',
    'd2000000-0000-0000-0000-000000000004',
    1, 1, 10, 1000, 1, 1, 60, 1048576, 1, 1048576,
    1000, 1048576, 'PASS', '[]', '{"fixture":"model-b-task"}',
    encode(digest('{"fixture":"model-b-task"}'::jsonb::text, 'sha256'), 'hex')
);

SET LOCAL session_replication_role = origin;

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.enqueue_training_task(
    'd4000000-0000-0000-0000-000000000002',
    'd5000000-0000-0000-0000-000000000002', NULL, NULL,
    'MODEL_B_REPLAY', 'MODEL_B', repeat('6', 64),
    jsonb_build_object(
        'task_type', 'MODEL_B_REPLAY',
        'payload_version', 1,
        'model_b_sample_ids', jsonb_build_array(:'created_model_b_sample_id')
    ), 10
) AS model_b_task_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_model_b;

SELECT claimed_task_id AS model_b_claimed_task_id,
       claimed_lease_token AS model_b_lease_token
FROM strategy_training.claim_training_model_b_task('model-b-integration', 300) \gset

SELECT strategy_training.start_training_task(
    :'model_b_claimed_task_id', :'model_b_lease_token', 'model-b-integration'
);

SELECT notional AS model_b_notional, episode_status AS model_b_episode_status
FROM strategy_training.training_model_b_replay_context(
    :'model_b_claimed_task_id', :'model_b_lease_token', :'created_model_b_sample_id'
) \gset

SELECT set_config('test.model_b_notional', :'model_b_notional', true);
SELECT set_config('test.model_b_episode_status', :'model_b_episode_status', true);
SELECT set_config('test.model_b_task_id', :'model_b_claimed_task_id', true);
SELECT set_config('test.model_b_sample_id', :'created_model_b_sample_id', true);

DO $$
BEGIN
    IF current_setting('test.model_b_notional')::numeric <> 1000
       OR current_setting('test.model_b_episode_status') <> 'RUNNING' THEN
        RAISE EXCEPTION 'model-B task context did not return frozen replay inputs';
    END IF;
END
$$;

DO $$
BEGIN
    BEGIN
        PERFORM * FROM strategy_training.training_model_b_replay_context(
            current_setting('test.model_b_task_id')::uuid,
            '00000000-0000-0000-0000-000000000001',
            current_setting('test.model_b_sample_id')::char(64)
        );
        RAISE EXCEPTION 'model-B replay context accepted a forged lease token';
    EXCEPTION WHEN serialization_failure THEN
        NULL;
    END;
END
$$;

SELECT decision_feature_snapshot_id AS first_snapshot_id
FROM strategy_training.model_b_market_asof(
    :'created_model_b_sample_id', '2026-06-10 01:10:00+00', 300
) \gset

SELECT strategy_training.record_training_exit_decision(
    :'created_exit_episode_id', 1, '2026-06-10 01:10:00+00',
    :'first_snapshot_id', 'HOLD', 'NO_EXIT_TRIGGER',
    '{"direction":"LONG","stop_before":98,"stop_after":98}',
    NULL, NULL, NULL, repeat('d', 64)
);

DO $$
DECLARE sample_id char(64);
BEGIN
    SELECT model_b_sample_id INTO STRICT sample_id
    FROM strategy_training.model_b_entry_inputs LIMIT 1;
    BEGIN
        PERFORM strategy_training.model_b_market_asof(
            sample_id, '2026-06-10 01:20:00+00', 300
        );
        RAISE EXCEPTION 'model-B as-of exceeded the holding boundary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT decision_feature_snapshot_id AS second_snapshot_id
FROM strategy_training.model_b_market_asof(
    :'created_model_b_sample_id', '2026-06-10 01:15:00+00', 300
) \gset

SELECT strategy_training.record_training_exit_decision(
    :'created_exit_episode_id', 2, '2026-06-10 01:15:00+00',
    :'second_snapshot_id', 'EXIT', 'MAX_HOLDING',
    '{"direction":"LONG","stop_before":98,"stop_after":98}',
    110, 109.99, 1, repeat('e', 64)
);

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.enqueue_training_task(
    'd4000000-0000-0000-0000-000000000002',
    'd5000000-0000-0000-0000-000000000002', NULL, NULL,
    'PORTFOLIO_EVALUATION', 'EVALUATOR', repeat('5', 64),
    jsonb_build_object(
        'task_type', 'PORTFOLIO_EVALUATION',
        'payload_version', 1
    ), 10
) AS portfolio_task_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_evaluator;

SELECT claimed_task_id AS portfolio_claimed_task_id,
       claimed_lease_token AS portfolio_lease_token
FROM strategy_training.claim_training_evaluator_task(
    'portfolio-evaluator-integration', 300
) \gset

SELECT strategy_training.start_training_task(
    :'portfolio_claimed_task_id', :'portfolio_lease_token',
    'portfolio-evaluator-integration'
);

SELECT portfolio_rule_version_id AS evaluated_portfolio_rule_version_id
FROM strategy_training.training_portfolio_evaluation_context(
    :'portfolio_claimed_task_id', :'portfolio_lease_token'
) \gset

SELECT set_config(
    'test.evaluated_portfolio_rule_version_id',
    :'evaluated_portfolio_rule_version_id', true
);
SELECT set_config(
    'test.portfolio_task_id', :'portfolio_claimed_task_id', true
);

DO $$
BEGIN
    IF current_setting('test.evaluated_portfolio_rule_version_id')::uuid
       <> 'd2000000-0000-0000-0000-000000000012'::uuid THEN
        RAISE EXCEPTION 'portfolio evaluator did not receive frozen rules';
    END IF;
    BEGIN
        PERFORM * FROM strategy_training.training_portfolio_evaluation_context(
            current_setting('test.portfolio_task_id')::uuid,
            '00000000-0000-0000-0000-000000000001'
        );
        RAISE EXCEPTION 'portfolio evaluation accepted a forged lease token';
    EXCEPTION WHEN serialization_failure THEN
        NULL;
    END;
END
$$;

SELECT strategy_training.record_training_exit_outcome(
    :'created_exit_episode_id', '2026-06-10 01:15:00+00', 109.99,
    'MAX_HOLDING', 9, 0.4, 0.44, 0, 1, 8.16, '[]', repeat('f', 64)
);

SELECT strategy_training.create_training_portfolio_run(
    'd5000000-0000-0000-0000-000000000002',
    'd2000000-0000-0000-0000-000000000012',
    'd2000000-0000-0000-0000-000000000010',
    'd2000000-0000-0000-0000-000000000011'
) AS portfolio_run_id \gset

SELECT strategy_training.record_training_portfolio_disposition(
    :'portfolio_run_id', :'entry_event_id', :'created_exit_episode_id',
    '2026-06-10 01:05:00+00', 'ACCEPTED', 2000, 0, 0, repeat('1', 64)
);

SELECT strategy_training.record_training_portfolio_trade(
    :'portfolio_run_id', :'entry_event_id', :'created_exit_episode_id',
    10, 1000, repeat('2', 64)
) AS portfolio_trade_id \gset

SELECT strategy_training.record_training_portfolio_fill(
    :'portfolio_trade_id', 1, 'ENTRY', '2026-06-10 01:05:00+00',
    100.01, 10, 0.4, 0.5, repeat('3', 64)
);
SELECT strategy_training.record_training_portfolio_fill(
    :'portfolio_trade_id', 2, 'EXIT', '2026-06-10 01:15:00+00',
    109.99, 10, 0.44, 0.5, repeat('4', 64)
);

SELECT strategy_training.record_training_portfolio_equity_point(
    :'portfolio_run_id', 1, '2026-06-10 01:05:00+00',
    2000, 1000, 1000, 1, 2000, 0, 'ENTRY', :'entry_event_id', repeat('5', 64)
);
SELECT strategy_training.record_training_portfolio_equity_point(
    :'portfolio_run_id', 2, '2026-06-10 01:15:00+00',
    2008.16, 0, 2008.16, 0, 2008.16, 0, 'EXIT', :'entry_event_id', repeat('6', 64)
);

SELECT strategy_training.finalize_training_portfolio_run(
    :'portfolio_run_id', 2008.16, 0, 1000, repeat('7', 64)
);

SELECT set_config('test.portfolio_run_id', :'portfolio_run_id', true);
SELECT set_config('test.portfolio_trade_id', :'portfolio_trade_id', true);
SELECT set_config('test.entry_event_id', :'entry_event_id', true);

DO $$
BEGIN
    BEGIN
        PERFORM strategy_training.record_training_portfolio_equity_point(
            current_setting('test.portfolio_run_id')::uuid,
            3, '2026-06-10 01:20:00+00',
            2008.16, 0, 2008.16, 0, 2008.16, 0, 'EXIT',
            current_setting('test.entry_event_id')::char(64), repeat('8', 64)
        );
        RAISE EXCEPTION 'completed portfolio run accepted another equity point';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    BEGIN
        PERFORM strategy_training.record_training_portfolio_fill(
            current_setting('test.portfolio_trade_id')::uuid,
            3, 'EXIT', '2026-06-10 01:20:00+00',
            109.99, 10, 0, 0, repeat('9', 64)
        );
        RAISE EXCEPTION 'completed portfolio run accepted another fill';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END
$$;

RESET ROLE;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_portfolio_runs
        WHERE status = 'COMPLETE' AND final_balance = 2008.16
          AND peak_occupied_capital = 1000
    ) OR (SELECT count(*) FROM strategy_training.training_exit_decisions) <> 2
       OR (SELECT count(*) FROM strategy_training.training_portfolio_trade_fills) <> 2
       OR EXISTS (
           SELECT 1 FROM strategy_training.model_b_entry_inputs input
           JOIN strategy_training.training_model_b_sample_map mapping
             ON mapping.model_b_sample_id = input.model_b_sample_id
           WHERE mapping.natural_source <> 'FIXED_BASELINE_MODEL_A'
       ) THEN
        RAISE EXCEPTION 'model-B/portfolio simulation facts are incomplete';
    END IF;
END
$$;

ROLLBACK;
