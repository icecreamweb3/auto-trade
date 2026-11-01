\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '022_training_controlled_procedures' AND success
    ) THEN
        RAISE EXCEPTION 'migration 022 was not recorded successfully';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'procedure-admin@example.test', 'not-a-real-hash', 'procedure-admin', 'ADMIN'
), (
    'b1000000-0000-0000-0000-000000000009',
    'procedure-non-admin@example.test', 'not-a-real-hash', 'procedure-non-admin', 'NORMAL'
);

INSERT INTO core.app_user_training_identities (
    user_id, natural_person_id, declared_by_user_id, declaration_reason, request_id
) VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000002',
    'b1000000-0000-0000-0000-000000000001',
    'integration admin identity', 'b1000000-0000-0000-0000-000000000003'
);

INSERT INTO core.app_user_training_roles (
    user_id, training_role, granted_by_user_id, grant_reason,
    request_id, valid_from, expires_at
) VALUES (
    'b1000000-0000-0000-0000-000000000001', 'TRAINING_ADMIN',
    'b1000000-0000-0000-0000-000000000001', 'integration admin grant',
    'b1000000-0000-0000-0000-000000000004',
    clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 day'
);

-- 020 readiness is covered separately; use immutable ready fixtures to isolate 022 ACL/procedures.
SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json, content_hash,
    status, created_by_user_id, ready_by_user_id, ready_at
)
SELECT config_version_id, config_type, semver, 1, config_json,
       encode(digest(config_json::text, 'sha256'), 'hex'), 'READY',
       'b1000000-0000-0000-0000-000000000001',
       'b1000000-0000-0000-0000-000000000001', clock_timestamp()
FROM (VALUES
    ('b2000000-0000-0000-0000-000000000001'::uuid, 'TICKER_POOL_RULES'::varchar,
     '22.0.1'::varchar, '{"rule":"historical"}'::jsonb),
    ('b2000000-0000-0000-0000-000000000002'::uuid, 'DATA_QUALITY_RULES'::varchar,
     '22.0.2'::varchar, '{"required_dependencies":["KLINE"],"dependency_rules":{"KLINE":{"minimum_coverage":1,"minimum_effective_samples":1,"minimum_effective_folds":1,"warmup_required":true}}}'::jsonb),
    ('b2000000-0000-0000-0000-000000000003'::uuid, 'HOLDING_HORIZON_RULES'::varchar,
     '22.0.3'::varchar, '{"label_horizon_seconds":86400,"max_holding_seconds":86400}'::jsonb),
    ('b2000000-0000-0000-0000-000000000004'::uuid, 'RESOURCE_LIMITS'::varchar,
     '22.0.4'::varchar, '{"max_heavy_experiments":1}'::jsonb),
    ('b2000000-0000-0000-0000-000000000005'::uuid, 'SEARCH_SPACE'::varchar,
     '22.0.5'::varchar, '{"parameters":{"threshold":[0,1]}}'::jsonb),
    ('b2000000-0000-0000-0000-000000000006'::uuid, 'VALIDATION_PROTOCOL'::varchar,
     '22.0.6'::varchar, '{"method":"fixed-once"}'::jsonb),
    ('b2000000-0000-0000-0000-000000000007'::uuid, 'SCORING_MODEL_A'::varchar,
     '22.0.7'::varchar, '{"components":["mfe"]}'::jsonb)
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
) VALUES (
    'b3000000-0000-0000-0000-000000000001', 'PROCEDURE_FIXTURE', 'TRAIN',
    '2026-01-01 00:00:00+00', '2026-07-01 00:00:00+00', 300,
    '2025-12-01 00:00:00+00', '2026-01-01 00:00:00+00',
    '2026-06-29 00:00:00+00', '2026-06-30 00:00:00+00',
    '2026-07-02 00:00:00+00', '2025-12-31 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'b2000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000002',
    'b2000000-0000-0000-0000-000000000003', interval '1 day', interval '1 day',
    repeat('3', 64), '{"revision":"fixture"}', 'READY',
    'b1000000-0000-0000-0000-000000000001', clock_timestamp()
);

SET LOCAL session_replication_role = origin;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json,
    content_hash, created_by_user_id
) VALUES (
    'b2000000-0000-0000-0000-000000000009', 'RETENTION_POLICY', '22.0.9', 1,
    '{"training_days":365}',
    encode(digest('{"training_days":365}'::jsonb::text, 'sha256'), 'hex'),
    'b1000000-0000-0000-0000-000000000001'
);

DO $$
BEGIN
    IF has_table_privilege(
        'tb2_training_orchestrator', 'strategy_training.training_experiments', 'INSERT'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        to_regproc('strategy_training.create_training_experiment'),
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        to_regproc('strategy_training.create_training_iteration'),
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_orchestrator',
        to_regproc('strategy_training.write_state_transition'),
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'controlled procedure privilege matrix is incorrect';
    END IF;
END
$$;

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.transition_training_config(
    'b2000000-0000-0000-0000-000000000009', 'DRAFT', 'READY',
    'b1000000-0000-0000-0000-000000000001', 'approve explicit retention policy',
    'b4000000-0000-0000-0000-000000000009'
);

DO $$
BEGIN
    BEGIN
        PERFORM strategy_training.create_training_experiment(
            'DISCOVERY', NULL,
            'b3000000-0000-0000-0000-000000000001',
            'b2000000-0000-0000-0000-000000000004',
            'unauthorized experiment', repeat('9', 64),
            'b1000000-0000-0000-0000-000000000009'
        );
        RAISE EXCEPTION 'user without TRAINING_ADMIN created an experiment';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;

SELECT strategy_training.create_training_experiment(
    'DISCOVERY', NULL,
    'b3000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000004',
    'controlled experiment', repeat('a', 64),
    'b1000000-0000-0000-0000-000000000001'
) AS controlled_experiment_id \gset

SELECT strategy_training.bind_training_experiment_config(
    :'controlled_experiment_id', 'SCORING_MODEL_A',
    'b2000000-0000-0000-0000-000000000007'
);

SELECT strategy_training.transition_training_experiment(
    :'controlled_experiment_id', 'DRAFT', 'RUNNING', NULL,
    'orchestrator-integration', 'start TRAIN search',
    'b4000000-0000-0000-0000-000000000001'
);

SELECT strategy_training.create_training_iteration(
    :'controlled_experiment_id', 1, NULL, 'OPTUNA_TPE', 42,
    '{"threshold":0.5}', '{"cpu":1,"memory_bytes":1024}', NULL
) AS controlled_iteration_id \gset

SELECT strategy_training.transition_training_iteration(
    :'controlled_iteration_id', 'CREATED', 'VALIDATING', NULL, NULL::char(64), NULL,
    'orchestrator-integration', 'validate candidate',
    'b4000000-0000-0000-0000-000000000002'
);

SELECT strategy_training.transition_training_iteration(
    :'controlled_iteration_id', 'VALIDATING', 'RUNNING', NULL, NULL::char(64), NULL,
    'orchestrator-integration', 'run TRAIN evaluation',
    'b4000000-0000-0000-0000-000000000003'
);

SELECT strategy_training.transition_training_iteration(
    :'controlled_iteration_id', 'RUNNING', 'SUCCEEDED', NULL, NULL::char(64), NULL,
    'orchestrator-integration', 'TRAIN evaluation complete',
    'b4000000-0000-0000-0000-000000000004'
);

SELECT strategy_training.create_training_optimizer_run(
    :'controlled_experiment_id', 'TPE',
    'b2000000-0000-0000-0000-000000000005', 10, 42, 'optimizer-adapter-1'
) AS controlled_optimizer_run_id \gset

SELECT strategy_training.transition_training_optimizer_run(
    :'controlled_optimizer_run_id', 'CREATED', 'RUNNING', NULL, NULL,
    'orchestrator-integration', 'start optimizer adapter',
    'b4000000-0000-0000-0000-000000000005'
);

SELECT strategy_training.record_optimizer_checkpoint(
    :'controlled_optimizer_run_id', 1, repeat('b', 64), repeat('c', 64), 1, 0
);

SELECT strategy_training.transition_training_optimizer_run(
    :'controlled_optimizer_run_id', 'RUNNING', 'SUCCEEDED', NULL, NULL,
    'orchestrator-integration', 'optimizer complete',
    'b4000000-0000-0000-0000-000000000006'
);

SELECT strategy_training.transition_training_experiment(
    :'controlled_experiment_id', 'RUNNING', 'STOPPED', NULL,
    'orchestrator-integration', 'TRAIN search complete',
    'b4000000-0000-0000-0000-000000000007'
);

SELECT strategy_training.freeze_training_final_candidate(
    :'controlled_experiment_id', :'controlled_iteration_id', repeat('d', 64),
    'b1000000-0000-0000-0000-000000000001'
) AS controlled_freeze_id \gset

SELECT strategy_training.create_training_validation_scope(
    '2026-07-01 00:00:00+00', '2026-08-01 00:00:00+00',
    'b2000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000006',
    1, 0.025, 1, 0.025, 0, 0,
    'b1000000-0000-0000-0000-000000000001'
) AS controlled_validation_scope_id \gset

SELECT strategy_training.reserve_training_validation_budget(
    :'controlled_validation_scope_id', :'controlled_freeze_id', 'MODEL_A', 0.025,
    'b4000000-0000-0000-0000-000000000008',
    'b1000000-0000-0000-0000-000000000001'
) AS controlled_reservation_id \gset

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_validation_scopes
        WHERE partition_start_at = '2026-07-01 00:00:00+00'
          AND partition_end_at = '2026-08-01 00:00:00+00'
          AND ticker_pool_rule_version_id = 'b2000000-0000-0000-0000-000000000001'
          AND state = 'EXHAUSTED' AND reserved_evaluation_count = 1
    ) OR (
        SELECT count(*) FROM strategy_training.training_state_transition_log
    ) <> 9 THEN
        RAISE EXCEPTION 'controlled transitions did not persist expected audit facts';
    END IF;
END
$$;

RESET ROLE;
SET LOCAL ROLE tb2_training_evaluator;

SELECT strategy_training.record_training_validation_evaluation(
    :'controlled_reservation_id', 0.025,
    '{"lower":0.1,"upper":0.2}',
    '{"method":"bonferroni","passed":true}', repeat('e', 64)
) AS controlled_evaluation_id \gset

SELECT strategy_training.record_training_iteration_metric(
    :'controlled_iteration_id', 'VALIDATION', :'controlled_evaluation_id',
    'profit_factor', 1.05, 30, 10, 'metric-v1', repeat('f', 64)
);

RESET ROLE;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_iteration_metrics metric
        JOIN strategy_training.training_iterations iteration_record
          ON iteration_record.iteration_id = metric.iteration_id
        JOIN strategy_training.training_experiments experiment
          ON experiment.experiment_id = iteration_record.experiment_id
        WHERE experiment.experiment_name = 'controlled experiment'
          AND metric.iteration_id = iteration_record.iteration_id
          AND metric.partition = 'VALIDATION'
          AND metric.validation_evaluation_id IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'evaluator controlled facts were not recorded';
    END IF;
END
$$;

ROLLBACK;
