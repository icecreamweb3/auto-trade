\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '032_training_model_test_governance' AND success
    ) THEN
        RAISE EXCEPTION 'migration 032 was not recorded successfully';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES
    ('e1000000-0000-0000-0000-000000000001', 'governance-admin-1@example.test', 'x', 'governance-admin-1', 'ADMIN'),
    ('e1000000-0000-0000-0000-000000000002', 'governance-admin-2@example.test', 'x', 'governance-admin-2', 'ADMIN'),
    ('e1000000-0000-0000-0000-000000000003', 'governance-auditor@example.test', 'x', 'governance-auditor', 'ADMIN');

INSERT INTO core.app_user_training_identities (
    user_id, natural_person_id, declared_by_user_id, declaration_reason, request_id
) VALUES
    ('e1000000-0000-0000-0000-000000000001', 'e1100000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000001', 'fixture', 'e1200000-0000-0000-0000-000000000001'),
    ('e1000000-0000-0000-0000-000000000002', 'e1100000-0000-0000-0000-000000000002',
     'e1000000-0000-0000-0000-000000000001', 'fixture', 'e1200000-0000-0000-0000-000000000002'),
    ('e1000000-0000-0000-0000-000000000003', 'e1100000-0000-0000-0000-000000000003',
     'e1000000-0000-0000-0000-000000000001', 'fixture', 'e1200000-0000-0000-0000-000000000003');

INSERT INTO core.app_user_training_roles (
    user_id, training_role, granted_by_user_id, grant_reason,
    request_id, valid_from, expires_at
) VALUES
    ('e1000000-0000-0000-0000-000000000001', 'TRAINING_ADMIN',
     'e1000000-0000-0000-0000-000000000001', 'fixture',
     'e1200000-0000-0000-0000-000000000011', clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 day'),
    ('e1000000-0000-0000-0000-000000000002', 'TRAINING_ADMIN',
     'e1000000-0000-0000-0000-000000000001', 'fixture',
     'e1200000-0000-0000-0000-000000000012', clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 day'),
    ('e1000000-0000-0000-0000-000000000003', 'TRAINING_TEST_AUDITOR',
     'e1000000-0000-0000-0000-000000000001', 'fixture',
     'e1200000-0000-0000-0000-000000000013', clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 day');

SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json, content_hash,
    status, created_by_user_id, ready_by_user_id, ready_at
)
SELECT config_version_id, config_type, semver, 1, config_json,
       encode(digest(config_json::text, 'sha256'), 'hex'), 'READY',
       'e1000000-0000-0000-0000-000000000001',
       'e1000000-0000-0000-0000-000000000001', clock_timestamp()
FROM (VALUES
    ('e2000000-0000-0000-0000-000000000001'::uuid, 'TICKER_POOL_RULES'::varchar,
     '31.0.1'::varchar, '{"rule":"historical"}'::jsonb),
    ('e2000000-0000-0000-0000-000000000002'::uuid, 'DATA_QUALITY_RULES'::varchar,
     '31.0.2'::varchar, '{"required_dependencies":["KLINE"],"dependency_rules":{"KLINE":{"minimum_coverage":1,"minimum_effective_samples":1,"minimum_effective_folds":1,"warmup_required":true}}}'::jsonb),
    ('e2000000-0000-0000-0000-000000000003'::uuid, 'HOLDING_HORIZON_RULES'::varchar,
     '31.0.3'::varchar, '{"label_horizon_seconds":86400,"max_holding_seconds":86400}'::jsonb),
    ('e2000000-0000-0000-0000-000000000004'::uuid, 'RESOURCE_LIMITS'::varchar,
     '31.0.4'::varchar, '{"max_heavy_experiments":1,"db_workers_per_experiment":2,"pool_connections":6,"statement_timeout_seconds":900,"lock_timeout_seconds":2,"idle_in_transaction_session_timeout_seconds":60,"work_mem_bytes":67108864,"cpu_limit":4,"memory_bytes":8589934592,"temp_disk_min_free_bytes":1073741824,"max_candidate_count":100,"max_signal_count":1000,"max_decision_row_count":10000,"max_storage_bytes":100000000}'::jsonb),
    ('e2000000-0000-0000-0000-000000000005'::uuid, 'SCORING_MODEL_A'::varchar,
     '31.0.5'::varchar, '{"components":["mfe"]}'::jsonb),
    ('e2000000-0000-0000-0000-000000000006'::uuid, 'RETENTION_POLICY'::varchar,
     '31.0.6'::varchar, '{"detail_days":30,"archive_format":"PARQUET","compression":"ZSTD"}'::jsonb),
    ('e2000000-0000-0000-0000-000000000007'::uuid, 'SEARCH_SPACE'::varchar,
     '31.0.7'::varchar, '{"parameters":{"threshold":[0,1]}}'::jsonb)
) AS configs(config_version_id, config_type, semver, config_json);

INSERT INTO strategy_training.training_dataset_versions (
    dataset_version_id, dataset_type, partition, partition_start_at, partition_end_at,
    interval_seconds, warmup_start_at, eligible_start_at, eligible_end_at,
    label_window_end_at, source_as_of_at, visibility_cutoff_at,
    fingerprint_schema_version, purge_duration, embargo_duration,
    ticker_pool_rule_version_id, data_quality_rule_version_id,
    holding_rule_version_id, label_horizon_duration, max_holding_duration,
    root_fingerprint, source_revision_watermark, status, created_by_user_id, ready_at
) VALUES (
    'e3000000-0000-0000-0000-000000000001', 'GOVERNANCE_FIXTURE', 'TRAIN',
    '2026-01-01 00:00:00+00', '2026-07-01 00:00:00+00', 300,
    '2025-12-01 00:00:00+00', '2026-01-01 00:00:00+00',
    '2026-06-29 00:00:00+00', '2026-06-30 00:00:00+00',
    '2026-07-02 00:00:00+00', '2025-12-31 00:00:00+00', 1,
    interval '1 day', interval '1 day',
    'e2000000-0000-0000-0000-000000000001',
    'e2000000-0000-0000-0000-000000000002',
    'e2000000-0000-0000-0000-000000000003', interval '1 day', interval '1 day',
    repeat('3', 64), '{"revision":"fixture"}', 'READY',
    'e1000000-0000-0000-0000-000000000001', clock_timestamp()
);

INSERT INTO strategy_training.training_resource_preflight_reports (
    resource_preflight_id, dataset_version_id, resource_limit_config_version_id,
    estimated_candidate_count, estimated_signal_count, estimated_decision_row_count,
    estimated_storage_bytes, estimated_db_workers, estimated_pool_connections,
    estimated_statement_seconds, estimated_work_mem_bytes, estimated_cpu,
    estimated_memory_bytes, estimated_temp_bytes, available_temp_bytes,
    status, blocking_reasons, evidence_json, evidence_hash
) VALUES (
    'e4000000-0000-0000-0000-000000000001',
    'e3000000-0000-0000-0000-000000000001',
    'e2000000-0000-0000-0000-000000000004',
    10, 20, 30, 1000, 2, 4, 600, 33554432, 2, 4294967296,
    1000, 2147483648, 'PASS', '[]', '{"fixture":"pass"}',
    encode(digest('{"fixture":"pass"}'::jsonb::text, 'sha256'), 'hex')
);

SET LOCAL session_replication_role = origin;

SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.create_training_experiment(
    'DISCOVERY', NULL, 'e3000000-0000-0000-0000-000000000001',
    'e2000000-0000-0000-0000-000000000004', 'governed experiment',
    repeat('a', 64), 'e1000000-0000-0000-0000-000000000001'
) AS experiment_id \gset

SELECT strategy_training.bind_training_experiment_config(
    :'experiment_id', 'SCORING_MODEL_A', 'e2000000-0000-0000-0000-000000000005'
);
SELECT strategy_training.bind_training_experiment_config(
    :'experiment_id', 'RETENTION_POLICY', 'e2000000-0000-0000-0000-000000000006'
);
SELECT strategy_training.bind_training_experiment_config(
    :'experiment_id', 'SEARCH_SPACE', 'e2000000-0000-0000-0000-000000000007'
);
SELECT strategy_training.create_training_l2_retention_plan(
    :'experiment_id', 'e2000000-0000-0000-0000-000000000006',
    '{"rule":"first_n_before_results"}', 100
) AS retention_plan_id \gset

SELECT strategy_training.transition_training_experiment(
    :'experiment_id', 'DRAFT', 'RUNNING', NULL, 'orchestrator-test',
    'start governed experiment', 'e5000000-0000-0000-0000-000000000001'
);
SELECT strategy_training.create_training_optimizer_run(
    :'experiment_id', 'TPE', 'e2000000-0000-0000-0000-000000000007',
    2, 42, 'optimizer-adapter-fixture'
) AS optimizer_run_id \gset
SELECT strategy_training.transition_training_optimizer_run(
    :'optimizer_run_id', 'CREATED', 'RUNNING', NULL, NULL,
    'orchestrator-test', 'start optimizer',
    'e5000000-0000-0000-0000-000000000009'
);
SELECT strategy_training.create_training_iteration(
    :'experiment_id', 1, NULL, 'OPTUNA_TPE', 42,
    '{"threshold":0.5}', '{"cpu":1}', NULL
) AS iteration_id \gset
SELECT strategy_training.transition_training_iteration(
    :'iteration_id', 'CREATED', 'VALIDATING', NULL, NULL::char(64), NULL,
    'orchestrator-test', 'validate', 'e5000000-0000-0000-0000-000000000002'
);
SELECT strategy_training.transition_training_iteration(
    :'iteration_id', 'VALIDATING', 'RUNNING', NULL, NULL::char(64), NULL,
    'orchestrator-test', 'run', 'e5000000-0000-0000-0000-000000000003'
);

SELECT strategy_training.enqueue_training_task(
    :'experiment_id', :'iteration_id', :'optimizer_run_id', NULL, 'OPTIMIZER_TRIAL', 'OPTIMIZER',
    repeat('b', 64), '{"task_type":"OPTIMIZER_TRIAL","payload_version":1,"trial_number":1}', 10
) AS task_id \gset
SELECT strategy_training.enqueue_training_task(
    :'experiment_id', :'iteration_id', :'optimizer_run_id', NULL, 'OPTIMIZER_TRIAL', 'OPTIMIZER',
    repeat('b', 64), '{"task_type":"OPTIMIZER_TRIAL","payload_version":1,"trial_number":1}', 10
) AS same_task_id \gset
SELECT strategy_training.enqueue_training_task(
    :'experiment_id', :'iteration_id', NULL, NULL, 'DATASET_BUILD', 'WORKER',
    repeat('0', 64), '{"task_type":"DATASET_BUILD","payload_version":1,"dataset":"fixture"}', 20
) AS cancelled_task_id \gset

RESET ROLE;
DO $$
BEGIN
    BEGIN
        UPDATE strategy_training.training_tasks
        SET task_payload = jsonb_set(task_payload, '{task_type}', '"DATASET_BUILD"')
        WHERE idempotency_key = repeat('b', 64);
        RAISE EXCEPTION 'mismatched task payload type was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    BEGIN
        UPDATE strategy_training.training_tasks
        SET task_payload = jsonb_set(task_payload, '{payload_version}', '0')
        WHERE idempotency_key = repeat('b', 64);
        RAISE EXCEPTION 'non-positive task payload version was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    BEGIN
        UPDATE strategy_training.training_tasks
        SET executor_kind = 'WORKER'
        WHERE idempotency_key = repeat('b', 64);
        RAISE EXCEPTION 'task type was assigned to the wrong executor';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
END
$$;
SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.request_training_task_cancellation(
    :'cancelled_task_id', 'operator cancelled queued task'
);

RESET ROLE;
SET LOCAL ROLE tb2_training_optimizer;
SELECT * FROM strategy_training.claim_training_optimizer_task('optimizer-1', 60) \gset first_
SELECT strategy_training.start_training_task(:'first_claimed_task_id', :'first_claimed_lease_token', 'optimizer-1');
SELECT strategy_training.heartbeat_training_task(
    :'first_claimed_task_id', :'first_claimed_lease_token', 'optimizer-1', 60
) AS cancellation_requested \gset heartbeat_
SELECT strategy_training.record_training_task_checkpoint(
    :'first_claimed_task_id', :'first_claimed_lease_token', 'optimizer-1', 1,
    repeat('c', 64), repeat('d', 64), '{"last_trial":0}'
);
SELECT strategy_training.pause_training_task(
    :'first_claimed_task_id', :'first_claimed_lease_token', 'optimizer-1'
);

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;
SELECT strategy_training.resume_training_task(:'task_id');

RESET ROLE;
SET LOCAL ROLE tb2_training_optimizer;
SELECT * FROM strategy_training.claim_training_optimizer_task('optimizer-2', 60) \gset resumed_
SELECT strategy_training.start_training_task(:'resumed_claimed_task_id', :'resumed_claimed_lease_token', 'optimizer-2');

RESET ROLE;
UPDATE strategy_training.training_tasks
SET lease_expires_at = clock_timestamp() - interval '1 second'
WHERE task_id = :'task_id';

SET LOCAL ROLE tb2_training_optimizer;
SELECT * FROM strategy_training.claim_training_optimizer_task('optimizer-3', 60) \gset recovered_
SELECT strategy_training.start_training_task(:'recovered_claimed_task_id', :'recovered_claimed_lease_token', 'optimizer-3');
SELECT strategy_training.complete_training_task(
    :'recovered_claimed_task_id', :'recovered_claimed_lease_token', 'optimizer-3',
    'SUCCEEDED', repeat('e', 64), NULL
);

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;
SELECT strategy_training.transition_training_iteration(
    :'iteration_id', 'RUNNING', 'SUCCEEDED', NULL, NULL::char(64), NULL,
    'orchestrator-test', 'complete', 'e5000000-0000-0000-0000-000000000004'
);

RESET ROLE;
SET LOCAL ROLE tb2_training_evaluator;
SELECT strategy_training.record_training_iteration_l0(
    :'iteration_id', 'TRAIN', NULL, 'SUCCEEDED', true, '[]', 12.5,
    '{"sample_count":10}', repeat('f', 64)
);
SELECT strategy_training.record_training_iteration_l1(
    :'iteration_id', 'PARTITION', 10, repeat('1', 64), repeat('2', 64),
    repeat('f', 64), 'MATCH', NULL
);
SELECT strategy_training.record_training_archive_manifest(
    :'retention_plan_id', :'iteration_id', 'SIGNALS',
    encode(digest('experiment/iteration/signals.parquet', 'sha256'), 'hex'), 10,
    '2026-01-01 00:00:00+00', '2026-01-02 00:00:00+00', 1000, repeat('4', 64)
) AS archive_manifest_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;
SELECT strategy_training.enqueue_training_task(
    :'experiment_id', :'iteration_id', NULL, NULL,
    'ARCHIVE_VERIFY', 'EVALUATOR',
    encode(digest('archive-verify-task', 'sha256'), 'hex'),
    jsonb_build_object(
        'task_type', 'ARCHIVE_VERIFY', 'payload_version', 1,
        'archive_manifest_id', :'archive_manifest_id',
        'storage_key', 'experiment/iteration/signals.parquet'
    ), 5
) AS archive_task_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_evaluator;
SELECT * FROM strategy_training.claim_training_evaluator_task(
    'archive-verifier', 60
) \gset archive_
SELECT strategy_training.start_training_task(
    :'archive_claimed_task_id', :'archive_claimed_lease_token', 'archive-verifier'
);
SELECT set_config('test.archive_task_id', :'archive_claimed_task_id', true);
SELECT set_config('test.archive_lease_token', :'archive_claimed_lease_token', true);
SELECT set_config('test.archive_manifest_id', :'archive_manifest_id', true);

DO $$
DECLARE context_record record;
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_archive_verify_context(
        current_setting('test.archive_task_id')::uuid,
        current_setting('test.archive_lease_token')::uuid
    );
    IF context_record.archive_manifest_id
           <> current_setting('test.archive_manifest_id')::uuid
       OR context_record.row_count <> 10
       OR context_record.content_sha256 <> repeat('4', 64) THEN
        RAISE EXCEPTION 'archive task context differs from its frozen manifest';
    END IF;
    BEGIN
        PERFORM strategy_training.verify_training_archive_restore(
            current_setting('test.archive_manifest_id')::uuid,
            10, '2026-01-01 00:00:00+00',
            '2026-01-02 00:00:00+00', 1000, repeat('4', 64)
        );
        RAISE EXCEPTION 'evaluator bypassed the leased archive verification procedure';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM strategy_training.training_archive_verify_context(
            current_setting('test.archive_task_id')::uuid,
            'e9000000-0000-0000-0000-000000000099'
        );
        RAISE EXCEPTION 'forged archive lease read the manifest';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;

SELECT strategy_training.record_training_archive_verify_result(
    :'archive_claimed_task_id', :'archive_claimed_lease_token', 10,
    '2026-01-01 00:00:00+00', '2026-01-02 00:00:00+00',
    1000, repeat('4', 64)
) AS archive_matches \gset
SELECT strategy_training.complete_training_task(
    :'archive_claimed_task_id', :'archive_claimed_lease_token', 'archive-verifier',
    'SUCCEEDED', repeat('4', 64), NULL
);

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;
SELECT strategy_training.enqueue_training_task(
    :'experiment_id', :'iteration_id', :'optimizer_run_id', NULL,
    'OPTIMIZER_TRIAL', 'OPTIMIZER', repeat('8', 64),
    '{"task_type":"OPTIMIZER_TRIAL","payload_version":1,"trial_number":0}', 5
) AS optimizer_result_task_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_optimizer;
SELECT * FROM strategy_training.claim_training_optimizer_task(
    'optimizer-result', 60
) \gset optimizer_result_
SELECT strategy_training.start_training_task(
    :'optimizer_result_claimed_task_id',
    :'optimizer_result_claimed_lease_token', 'optimizer-result'
);
SELECT set_config(
    'test.optimizer_result_task_id', :'optimizer_result_claimed_task_id', true
);
SELECT set_config(
    'test.optimizer_result_lease_token', :'optimizer_result_claimed_lease_token', true
);

DO $$
DECLARE
    context_record record;
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_optimizer_trial_context(
        current_setting('test.optimizer_result_task_id')::uuid,
        current_setting('test.optimizer_result_lease_token')::uuid
    );
    IF context_record.trial_number <> 0
       OR context_record.train_objective <> 12.5
       OR context_record.train_evidence_hash <> repeat('f', 64)
       OR context_record.candidate_parameters <> '{"threshold":0.5}'::jsonb THEN
        RAISE EXCEPTION 'optimizer trial context did not expose its TRAIN-only facts';
    END IF;
    BEGIN
        PERFORM strategy_training.record_training_optimizer_trial_result(
            current_setting('test.optimizer_result_task_id')::uuid,
            current_setting('test.optimizer_result_lease_token')::uuid,
            'COMPLETE', 99, '[]', repeat('f', 64), repeat('9', 64)
        );
        RAISE EXCEPTION 'forged optimizer objective was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM strategy_training.training_optimizer_trial_context(
            current_setting('test.optimizer_result_task_id')::uuid,
            'e9000000-0000-0000-0000-000000000099'
        );
        RAISE EXCEPTION 'forged optimizer lease read the trial context';
    EXCEPTION WHEN serialization_failure THEN NULL;
    END;
END
$$;

SELECT strategy_training.record_training_optimizer_trial_result(
    :'optimizer_result_claimed_task_id',
    :'optimizer_result_claimed_lease_token',
    'COMPLETE', 12.5, '[]', repeat('f', 64), repeat('9', 64)
);
SELECT strategy_training.complete_training_task(
    :'optimizer_result_claimed_task_id',
    :'optimizer_result_claimed_lease_token', 'optimizer-result',
    'SUCCEEDED', repeat('9', 64), NULL
);

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;
SELECT strategy_training.create_training_model_version(
    'MODEL_A', :'iteration_id', repeat('5', 64),
    'e1000000-0000-0000-0000-000000000001'
) AS model_version_id \gset
SELECT strategy_training.request_training_model_lock(
    :'model_version_id', 'e1000000-0000-0000-0000-000000000001', repeat('6', 64)
) AS lock_approval_id \gset

SELECT set_config('test.lock_approval_id', :'lock_approval_id', true);

DO $$
BEGIN
    BEGIN
        PERFORM strategy_training.decide_training_model_lock(
            current_setting('test.lock_approval_id')::uuid,
            'e1000000-0000-0000-0000-000000000001', true, 'self approval'
        );
        RAISE EXCEPTION 'same natural person approved their own model lock';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END
$$;

SELECT strategy_training.decide_training_model_lock(
    :'lock_approval_id', 'e1000000-0000-0000-0000-000000000002', true,
    'independent lock review'
);

SELECT strategy_training_test.create_test_logical_scope(
    '2026-08-01 00:00:00+00', '2026-09-01 00:00:00+00',
    'e2000000-0000-0000-0000-000000000001',
    'e1000000-0000-0000-0000-000000000001'
) AS test_scope_id \gset
SELECT strategy_training_test.create_test_dataset_version(
    :'test_scope_id', repeat('7', 64), '{"revision":"test-v1"}', NULL
) AS test_dataset_id \gset
SELECT strategy_training_test.freeze_test_dataset_version(:'test_dataset_id');
SELECT strategy_training_test.create_test_set(
    :'test_dataset_id', :'model_version_id', NULL,
    '2026-07-31 00:00:00+00', 'NONE'
) AS test_set_id \gset
SELECT strategy_training_test.request_test_readiness(
    :'test_set_id', 'e1000000-0000-0000-0000-000000000001', repeat('8', 64)
) AS readiness_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_test_auditor;
SELECT strategy_training_test.decide_and_seal_test_readiness(
    :'readiness_id', 'e1000000-0000-0000-0000-000000000003', true,
    'independent TEST readiness review', 'e5000000-0000-0000-0000-000000000005'
);

RESET ROLE;
SET LOCAL ROLE tb2_training_test_executor;
SELECT * FROM strategy_training_test.consume_test_set(
    :'test_set_id', 'e5000000-0000-0000-0000-000000000006', 'test-executor-1'
) \gset consume_
SELECT * FROM strategy_training_test.consume_test_set(
    :'test_set_id', 'e5000000-0000-0000-0000-000000000007', 'test-executor-1'
) \gset duplicate_

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;
SELECT strategy_training_test.request_test_retry(
    :'test_set_id', 'e1000000-0000-0000-0000-000000000001',
    repeat('9', 64), repeat('a', 64), 'same version crash retry'
) AS retry_id \gset

RESET ROLE;
SET LOCAL ROLE tb2_training_test_auditor;
SELECT strategy_training_test.decide_test_retry(
    :'retry_id', 'e1000000-0000-0000-0000-000000000003', true
);

RESET ROLE;
SET LOCAL ROLE tb2_training_test_executor;
SELECT * FROM strategy_training_test.consume_test_retry(
    :'retry_id', 'e5000000-0000-0000-0000-000000000008', 'test-executor-1'
) \gset retry_

RESET ROLE;

SELECT set_config('test.recovered_attempt', :'recovered_claimed_attempt_number', true);
SELECT set_config('test.recovered_checkpoint', :'recovered_claimed_checkpoint_sequence', true);
SELECT set_config('test.archive_matches', :'archive_matches', true);
SELECT set_config('test.consume_allowed', :'consume_allowed', true);
SELECT set_config('test.duplicate_allowed', :'duplicate_allowed', true);
SELECT set_config('test.retry_allowed', :'retry_allowed', true);
SELECT set_config('test.task_id', :'task_id', true);
SELECT set_config('test.same_task_id', :'same_task_id', true);
SELECT set_config('test.cancelled_task_id', :'cancelled_task_id', true);
SELECT set_config('test.heartbeat_cancel', :'heartbeat_cancellation_requested', true);
SELECT set_config('test.model_version_id', :'model_version_id', true);
SELECT set_config('test.test_set_id', :'test_set_id', true);

DO $$
BEGIN
    IF current_setting('test.recovered_attempt')::integer <> 3
       OR current_setting('test.recovered_checkpoint')::integer <> 1
       OR current_setting('test.task_id') <> current_setting('test.same_task_id')
       OR current_setting('test.heartbeat_cancel')::boolean IS NOT FALSE
       OR current_setting('test.archive_matches')::boolean IS NOT TRUE
       OR current_setting('test.consume_allowed')::boolean IS NOT TRUE
       OR current_setting('test.duplicate_allowed')::boolean IS NOT FALSE
       OR current_setting('test.retry_allowed')::boolean IS NOT TRUE
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_tasks
                      WHERE task_id = current_setting('test.task_id')::uuid
                        AND state = 'SUCCEEDED'
                        AND attempt_count = 3 AND checkpoint_sequence = 1)
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_tasks
                      WHERE task_id = current_setting('test.cancelled_task_id')::uuid
                        AND state = 'CANCELLED'
                        AND failure_code = 'CANCELLED_BEFORE_START')
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_model_versions
                      WHERE model_version_id = current_setting('test.model_version_id')::uuid
                        AND state = 'LOCKED')
       OR NOT EXISTS (SELECT 1 FROM strategy_training_test.test_sets
                      WHERE test_set_id = current_setting('test.test_set_id')::uuid
                        AND state = 'CONSUMED')
       OR NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_optimizer_trial_results
            WHERE task_id = current_setting('test.optimizer_result_task_id')::uuid
              AND trial_state = 'COMPLETE'
              AND train_objective = 12.5
              AND train_evidence_hash = repeat('f', 64)
       ) THEN
        RAISE EXCEPTION 'orchestration/governance lifecycle assertions failed';
    END IF;
    IF has_table_privilege(
        'tb2_training_optimizer', 'strategy_training.training_iteration_evidence_l0', 'SELECT'
    ) OR has_table_privilege(
        'tb2_training_optimizer',
        'strategy_training.training_optimizer_trial_results', 'SELECT'
    ) OR NOT has_table_privilege(
        'tb2_training_optimizer', 'strategy_training.optimizer_train_objectives', 'SELECT'
    ) OR NOT has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.training_optimizer_trial_context(uuid,uuid)', 'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.verify_training_archive_restore(uuid,bigint,timestamptz,timestamptz,bigint,character)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_archive_verify_context(uuid,uuid)', 'EXECUTE'
    ) OR has_schema_privilege('tb2_training_optimizer', 'strategy_training_test', 'USAGE')
       OR has_table_privilege(
            'tb2_training_test_executor', 'strategy_training_test.test_sets', 'SELECT'
       ) THEN
        RAISE EXCEPTION 'governance privilege boundaries are incorrect';
    END IF;
END
$$;

ROLLBACK;
