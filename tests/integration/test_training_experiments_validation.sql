\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '021_training_experiments_validation' AND success
    ) THEN
        RAISE EXCEPTION 'migration 021 was not recorded successfully';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES (
    'a1000000-0000-0000-0000-000000000001',
    'control-plane-admin@example.test', 'not-a-real-hash', 'control-plane-admin', 'ADMIN'
);

-- 020 already tests the full READY path. These fixtures isolate 021 guards.
SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json, content_hash,
    status, created_by_user_id, ready_by_user_id, ready_at
)
SELECT config_version_id, config_type, semver, 1, config_json,
       encode(digest(config_json::text, 'sha256'), 'hex'), 'READY',
       'a1000000-0000-0000-0000-000000000001',
       'a1000000-0000-0000-0000-000000000001', clock_timestamp()
FROM (VALUES
    ('a2000000-0000-0000-0000-000000000001'::uuid, 'TICKER_POOL_RULES'::varchar,
     '21.0.1'::varchar, '{"rule":"historical"}'::jsonb),
    ('a2000000-0000-0000-0000-000000000002'::uuid, 'DATA_QUALITY_RULES'::varchar,
     '21.0.2'::varchar, '{"required_dependencies":["KLINE"],"dependency_rules":{"KLINE":{"minimum_coverage":1,"minimum_effective_samples":1,"minimum_effective_folds":1,"warmup_required":true}}}'::jsonb),
    ('a2000000-0000-0000-0000-000000000003'::uuid, 'HOLDING_HORIZON_RULES'::varchar,
     '21.0.3'::varchar, '{"label_horizon_seconds":86400,"max_holding_seconds":86400}'::jsonb),
    ('a2000000-0000-0000-0000-000000000004'::uuid, 'RESOURCE_LIMITS'::varchar,
     '21.0.4'::varchar, '{"max_heavy_experiments":1}'::jsonb),
    ('a2000000-0000-0000-0000-000000000005'::uuid, 'SEARCH_SPACE'::varchar,
     '21.0.5'::varchar, '{"parameters":{"threshold":[0,1]}}'::jsonb),
    ('a2000000-0000-0000-0000-000000000006'::uuid, 'VALIDATION_PROTOCOL'::varchar,
     '21.0.6'::varchar, '{"method":"fixed-once"}'::jsonb),
    ('a2000000-0000-0000-0000-000000000007'::uuid, 'VALIDATION_PROTOCOL'::varchar,
     '21.0.7'::varchar, '{"method":"cannot-reset-identity"}'::jsonb),
    ('a2000000-0000-0000-0000-000000000008'::uuid, 'SCORING_MODEL_A'::varchar,
     '21.0.8'::varchar, '{"components":["mfe"]}'::jsonb)
) AS configs(config_version_id, config_type, semver, config_json);

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
) VALUES
(
    'a3000000-0000-0000-0000-000000000001', 'CONTROL_FIXTURE', 'TRAIN',
    '2026-01-01 00:00:00+00', '2026-07-01 00:00:00+00', 300,
    '2025-12-01 00:00:00+00', '2026-01-01 00:00:00+00',
    '2026-06-29 00:00:00+00', '2026-06-30 00:00:00+00',
    '2026-07-02 00:00:00+00', '2025-12-31 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'a2000000-0000-0000-0000-000000000001',
    'a2000000-0000-0000-0000-000000000002',
    'a2000000-0000-0000-0000-000000000003', interval '1 day', interval '1 day',
    repeat('1', 64), '{"revision":"fixture"}', 'READY',
    'a1000000-0000-0000-0000-000000000001', clock_timestamp()
),
(
    'a3000000-0000-0000-0000-000000000002', 'CONTROL_FIXTURE', 'VALIDATION',
    '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00', 300,
    '2026-06-01 00:00:00+00', '2026-07-01 00:00:00+00',
    '2026-07-29 00:00:00+00', '2026-07-30 00:00:00+00',
    '2026-08-02 00:00:00+00', '2026-06-30 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'a2000000-0000-0000-0000-000000000001',
    'a2000000-0000-0000-0000-000000000002',
    'a2000000-0000-0000-0000-000000000003', interval '1 day', interval '1 day',
    repeat('2', 64), '{"revision":"fixture"}', 'READY',
    'a1000000-0000-0000-0000-000000000001', clock_timestamp()
);

SET LOCAL session_replication_role = origin;

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_experiments (
            experiment_id, experiment_mode, dataset_version_id,
            resource_limit_config_version_id, experiment_name,
            exposure_identity_hash, created_by_user_id
        ) VALUES (
            'a4000000-0000-0000-0000-000000000099', 'DISCOVERY',
            'a3000000-0000-0000-0000-000000000002',
            'a2000000-0000-0000-0000-000000000004', 'illegal validation search',
            repeat('9', 64), 'a1000000-0000-0000-0000-000000000001'
        );
        RAISE EXCEPTION 'VALIDATION dataset was accepted for an experiment';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_experiments (
    experiment_id, experiment_mode, dataset_version_id,
    resource_limit_config_version_id, experiment_name,
    exposure_identity_hash, created_by_user_id
) VALUES (
    'a4000000-0000-0000-0000-000000000001', 'DISCOVERY',
    'a3000000-0000-0000-0000-000000000001',
    'a2000000-0000-0000-0000-000000000004', 'TRAIN discovery',
    repeat('a', 64), 'a1000000-0000-0000-0000-000000000001'
), (
    'a4000000-0000-0000-0000-000000000002', 'END_TO_END',
    'a3000000-0000-0000-0000-000000000001',
    'a2000000-0000-0000-0000-000000000004', 'end-to-end report only',
    repeat('b', 64), 'a1000000-0000-0000-0000-000000000001'
);

INSERT INTO strategy_training.training_experiment_config_bindings (
    experiment_id, config_type, config_version_id
) VALUES (
    'a4000000-0000-0000-0000-000000000001', 'SCORING_MODEL_A',
    'a2000000-0000-0000-0000-000000000008'
);

UPDATE strategy_training.training_experiments
SET state = 'RUNNING', started_at = clock_timestamp()
WHERE experiment_id IN (
    'a4000000-0000-0000-0000-000000000001',
    'a4000000-0000-0000-0000-000000000002'
);

DO $$
DECLARE
    params jsonb := '{"threshold":0.5}'::jsonb;
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_iterations (
            iteration_id, experiment_id, candidate_version, candidate_source,
            random_seed, candidate_parameters, candidate_content_hash,
            resource_budget
        ) VALUES (
            'a5000000-0000-0000-0000-000000000099',
            'a4000000-0000-0000-0000-000000000002', 1, 'FIXED_BASELINE', 42,
            params, encode(digest(params::text, 'sha256'), 'hex'),
            '{"cpu":1,"memory_bytes":1024}'
        );
        RAISE EXCEPTION 'END_TO_END experiment created a search iteration';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_iterations (
    iteration_id, experiment_id, candidate_version, candidate_source,
    random_seed, candidate_parameters, candidate_content_hash, resource_budget
)
SELECT 'a5000000-0000-0000-0000-000000000001',
       'a4000000-0000-0000-0000-000000000001', 1, 'OPTUNA_TPE', 42,
       params, encode(digest(params::text, 'sha256'), 'hex'),
       '{"cpu":1,"memory_bytes":1024}'
FROM (SELECT '{"threshold":0.5}'::jsonb AS params) candidate;

UPDATE strategy_training.training_iterations
SET state = 'VALIDATING', validation_started_at = clock_timestamp()
WHERE iteration_id = 'a5000000-0000-0000-0000-000000000001';

UPDATE strategy_training.training_iterations
SET state = 'RUNNING', run_started_at = clock_timestamp()
WHERE iteration_id = 'a5000000-0000-0000-0000-000000000001';

UPDATE strategy_training.training_iterations
SET state = 'SUCCEEDED', completed_at = clock_timestamp()
WHERE iteration_id = 'a5000000-0000-0000-0000-000000000001';

INSERT INTO strategy_training.training_optimizer_runs (
    optimizer_run_id, experiment_id, optimizer_kind, search_space_config_version_id,
    trial_budget, random_seed, worker_identity
) VALUES (
    'a6000000-0000-0000-0000-000000000001',
    'a4000000-0000-0000-0000-000000000001', 'TPE',
    'a2000000-0000-0000-0000-000000000005', 10, 42, 'optimizer-integration-1'
);

INSERT INTO strategy_training.training_optimizer_checkpoints (
    optimizer_checkpoint_id, optimizer_run_id, trial_number, study_state_hash,
    checkpoint_uri_hash, completed_trial_count, failed_trial_count
) VALUES (
    'a7000000-0000-0000-0000-000000000001',
    'a6000000-0000-0000-0000-000000000001', 1,
    repeat('c', 64), repeat('d', 64), 1, 0
);

DO $$
BEGIN
    BEGIN
        UPDATE strategy_training.training_optimizer_checkpoints
        SET completed_trial_count = 2
        WHERE optimizer_checkpoint_id = 'a7000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'optimizer checkpoint history was overwritten';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END
$$;

UPDATE strategy_training.training_experiments
SET state = 'STOPPED', stop_reason = 'TRAIN search complete', stopped_at = clock_timestamp()
WHERE experiment_id = 'a4000000-0000-0000-0000-000000000001';

INSERT INTO strategy_training.training_final_candidate_freezes (
    final_candidate_freeze_id, experiment_id, iteration_id,
    candidate_content_hash, freeze_manifest_hash, frozen_by_user_id
)
SELECT 'a8000000-0000-0000-0000-000000000001', experiment_id, iteration_id,
       candidate_content_hash, repeat('e', 64),
       'a1000000-0000-0000-0000-000000000001'
FROM strategy_training.training_iterations
WHERE iteration_id = 'a5000000-0000-0000-0000-000000000001';

INSERT INTO strategy_training.training_validation_scopes (
    validation_scope_id, scope_hash, partition_start_at, partition_end_at,
    ticker_pool_rule_version_id, validation_protocol_version_id,
    max_evaluation_count, alpha_total,
    model_a_max_evaluation_count, model_a_alpha_total,
    model_b_max_evaluation_count, model_b_alpha_total, created_by_user_id
) VALUES (
    'a9000000-0000-0000-0000-000000000001',
    strategy_training.compute_validation_scope_hash(
        '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
        'a2000000-0000-0000-0000-000000000001'
    ),
    '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
    'a2000000-0000-0000-0000-000000000001',
    'a2000000-0000-0000-0000-000000000006',
    1, 0.025, 1, 0.025, 0, 0,
    'a1000000-0000-0000-0000-000000000001'
);

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_validation_scopes (
            scope_hash, partition_start_at, partition_end_at,
            ticker_pool_rule_version_id, validation_protocol_version_id,
            max_evaluation_count, alpha_total,
            model_a_max_evaluation_count, model_a_alpha_total,
            model_b_max_evaluation_count, model_b_alpha_total, created_by_user_id
        ) VALUES (
            strategy_training.compute_validation_scope_hash(
                '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
                'a2000000-0000-0000-0000-000000000001'
            ),
            '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
            'a2000000-0000-0000-0000-000000000001',
            'a2000000-0000-0000-0000-000000000007',
            1, 0.025, 1, 0.025, 0, 0,
            'a1000000-0000-0000-0000-000000000001'
        );
        RAISE EXCEPTION 'protocol version reset a logical validation identity';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_validation_reservations (
    validation_reservation_id, validation_scope_id, final_candidate_freeze_id,
    model_family, evaluation_count, alpha_reserved,
    reservation_request_id, reserved_by_user_id
) VALUES (
    'aa000000-0000-0000-0000-000000000001',
    'a9000000-0000-0000-0000-000000000001',
    'a8000000-0000-0000-0000-000000000001', 'MODEL_A', 1, 0.025,
    'aa000000-0000-0000-0000-000000000002',
    'a1000000-0000-0000-0000-000000000001'
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_validation_scopes
        WHERE validation_scope_id = 'a9000000-0000-0000-0000-000000000001'
          AND reserved_evaluation_count = 1 AND reserved_alpha = 0.025
          AND model_a_reserved_evaluation_count = 1
    ) THEN
        RAISE EXCEPTION 'validation reservation did not atomically consume budget';
    END IF;

    BEGIN
        INSERT INTO strategy_training.training_validation_reservations (
            validation_scope_id, final_candidate_freeze_id, model_family,
            evaluation_count, alpha_reserved, reservation_request_id, reserved_by_user_id
        ) VALUES (
            'a9000000-0000-0000-0000-000000000001',
            'a8000000-0000-0000-0000-000000000001', 'MODEL_A', 1, 0.025,
            'aa000000-0000-0000-0000-000000000003',
            'a1000000-0000-0000-0000-000000000001'
        );
        RAISE EXCEPTION 'exhausted validation budget accepted another reservation';
    EXCEPTION WHEN program_limit_exceeded THEN NULL;
    END;

    BEGIN
        UPDATE strategy_training.training_validation_scopes
        SET reserved_evaluation_count = 0,
            reserved_alpha = 0,
            model_a_reserved_evaluation_count = 0,
            model_a_reserved_alpha = 0
        WHERE validation_scope_id = 'a9000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'validation budget was reset';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END
$$;

INSERT INTO strategy_training.training_validation_evaluations (
    validation_evaluation_id, validation_reservation_id, validation_scope_id,
    experiment_id, final_candidate_freeze_id, alpha_used,
    confidence_interval, correction_result, result_hash
) VALUES (
    'ab000000-0000-0000-0000-000000000001',
    'aa000000-0000-0000-0000-000000000001',
    'a9000000-0000-0000-0000-000000000001',
    'a4000000-0000-0000-0000-000000000001',
    'a8000000-0000-0000-0000-000000000001', 0.025,
    '{"lower":0.1,"upper":0.2}', '{"method":"bonferroni","passed":true}',
    repeat('f', 64)
);

INSERT INTO strategy_training.training_iteration_metrics (
    iteration_id, partition, validation_evaluation_id, metric_name, metric_value,
    sample_count, effective_independent_day_count, calculation_version, evidence_hash
) VALUES (
    'a5000000-0000-0000-0000-000000000001', 'TRAIN', NULL,
    'profit_factor', 1.1, 100, 20, 'metric-v1', repeat('1', 64)
), (
    'a5000000-0000-0000-0000-000000000001', 'VALIDATION',
    'ab000000-0000-0000-0000-000000000001',
    'profit_factor', 1.05, 30, 10, 'metric-v1', repeat('2', 64)
);

DO $$
BEGIN
    BEGIN
        INSERT INTO strategy_training.training_iteration_metrics (
            iteration_id, partition, metric_name, metric_value, sample_count,
            effective_independent_day_count, calculation_version, evidence_hash
        ) VALUES (
            'a5000000-0000-0000-0000-000000000001', 'VALIDATION',
            'illegal_unreferenced_metric', 1, 1, 1, 'metric-v1', repeat('3', 64)
        );
        RAISE EXCEPTION 'VALIDATION metric without evaluation reference was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_optimizer', 'strategy_training.training_iteration_metrics', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_optimizer', 'strategy_training.training_validation_evaluations', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_validation_evaluations', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_rw', 'strategy_training.training_iteration_metrics', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_evaluator', 'strategy_training.training_iteration_metrics', 'SELECT'
    ) THEN
        RAISE EXCEPTION 'training control-plane privilege matrix is incorrect';
    END IF;
END
$$;

ROLLBACK;
