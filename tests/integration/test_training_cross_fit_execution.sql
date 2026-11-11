\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE source_check text;
DECLARE use_check text;
DECLARE start_source text;
DECLARE fold_source text;
DECLARE promote_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '054_training_cross_fit_execution'
    ) THEN
        RAISE EXCEPTION '054 Cross-fit execution migration is missing';
    END IF;
    IF to_regclass('strategy_training.training_cross_fit_executions') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_fold_executions') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_corpora') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_corpus_events') IS NULL THEN
        RAISE EXCEPTION 'M6 execution facts are incomplete';
    END IF;

    SELECT pg_get_constraintdef(oid) INTO source_check
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_entry_events'::regclass
      AND conname = 'training_entry_events_source_check';
    SELECT pg_get_constraintdef(oid) INTO use_check
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_entry_events'::regclass
      AND conname = 'training_entry_events_source_use_check';
    IF position('CROSS_FIT_MODEL_A_CANDIDATE' IN source_check) = 0
       OR position('CROSS_FIT_MODEL_A' IN source_check) = 0
       OR position('IN_SAMPLE_MODEL_A' IN use_check) = 0
       OR position('MODEL_A_DISCOVERY' IN use_check) = 0 THEN
        RAISE EXCEPTION 'latest entry source/use isolation is not installed';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.start_cross_fit_execution(uuid,uuid)'::regprocedure
    ) INTO start_source;
    IF position('assert_cross_fit_execution_lease' IN start_source) = 0
       OR position('coverage_gate_status' IN start_source) = 0
       OR position('ACCEPTED' IN start_source) = 0
       OR position('Q-019' IN start_source) = 0
       OR position('Q-029' IN start_source) = 0
       OR position('Q-030' IN start_source) = 0
       OR position('Q-036' IN start_source) = 0
       OR position('Q-039' IN start_source) = 0
       OR position('source_revision_watermark_hash' IN start_source) = 0
       OR position('coverage_evidence_hash' IN start_source) = 0 THEN
        RAISE EXCEPTION 'Cross-fit start is not fail closed on lease, READY Qs and coverage';
    END IF;

    SELECT pg_get_functiondef(oid) INTO fold_source
    FROM pg_proc
    WHERE pronamespace = 'strategy_training'::regnamespace
      AND proname = 'record_cross_fit_fold_execution';
    IF position('inner_validation_count' IN fold_source) = 0
       OR position('SUCCEEDED' IN fold_source) = 0
       OR position('trial_budget' IN fold_source) = 0
       OR position('random_seed' IN fold_source) = 0 THEN
        RAISE EXCEPTION 'fold execution does not persist from-scratch controls';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.promote_cross_fit_corpus(uuid,uuid)'::regprocedure
    ) INTO promote_source;
    IF position('GO_NO_GO_PASSED' IN promote_source) = 0
       OR position('CROSS_FIT_MODEL_A_CANDIDATE' IN promote_source) = 0
       OR position('MODEL_B_TRAIN' IN promote_source) = 0 THEN
        RAISE EXCEPTION 'formal corpus promotion is not gated and isolated';
    END IF;

    IF has_table_privilege('tb2_training_evaluator',
            'strategy_training.training_cross_fit_folds', 'INSERT')
       OR has_table_privilege('tb2_training_evaluator',
            'strategy_training.training_go_no_go_evaluations', 'INSERT')
       OR NOT has_function_privilege('tb2_training_evaluator',
            'strategy_training.start_cross_fit_execution(uuid,uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'M6 facts bypass controlled lease procedures';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'strategy_training'
          AND table_name = 'formal_model_b_cross_fit_entries'
          AND column_name = 'underlying_source'
    ) OR NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'strategy_training'
          AND table_name = 'formal_model_b_cross_fit_entries'
          AND column_name = 'promoted_source'
    ) THEN
        RAISE EXCEPTION 'formal mapping must expose candidate origin and promoted use';
    END IF;
END
$$;

-- A READY protocol is part of an active execution's frozen contract.  The
-- config can be retired only after every bound execution reaches a terminal
-- state.  Replica mode is used only to create isolated FK fixtures; the guard
-- itself is exercised with normal trigger execution.
INSERT INTO core.app_users (user_id, email, password_hash)
VALUES (
    '54f00000-0000-0000-0000-000000000001',
    'cross-fit-retirement-guard@example.test',
    'not-a-real-hash'
);

SET LOCAL session_replication_role = replica;

INSERT INTO strategy_training.training_config_versions (
    config_version_id, config_type, semver, schema_version, config_json,
    content_hash, status, created_by_user_id, ready_by_user_id, ready_at
) VALUES (
    '54f00000-0000-0000-0000-000000000106',
    'CROSS_FIT_PROTOCOL', '106.0.0', 1,
    '{"protocol":"integration-retirement-guard"}'::jsonb,
    encode(digest(
        '{"protocol":"integration-retirement-guard"}'::jsonb::text,
        'sha256'
    ), 'hex'),
    'READY',
    '54f00000-0000-0000-0000-000000000001',
    '54f00000-0000-0000-0000-000000000001',
    clock_timestamp()
);

INSERT INTO strategy_training.training_cross_fit_executions (
    cross_fit_execution_id, experiment_id, dataset_version_id,
    protocol_config_version_id, coverage_evidence_hash,
    source_revision_watermark_hash, coverage_gate_status, state,
    question_readiness, minimum_effective_folds, minimum_effective_days,
    minimum_event_count
) VALUES (
    '54f00000-0000-0000-0000-000000000206',
    '54f00000-0000-0000-0000-000000000306',
    '54f00000-0000-0000-0000-000000000406',
    '54f00000-0000-0000-0000-000000000106',
    repeat('a', 64), repeat('b', 64), 'ACCEPTED', 'PLANNED',
    '{}'::jsonb, 1, 1, 1
);

SET LOCAL session_replication_role = origin;

DO $$
BEGIN
    BEGIN
        UPDATE strategy_training.training_config_versions
        SET status = 'RETIRED',
            retired_by_user_id = '54f00000-0000-0000-0000-000000000001',
            retired_at = clock_timestamp()
        WHERE config_version_id = '54f00000-0000-0000-0000-000000000106';
        RAISE EXCEPTION 'active Cross-fit protocol retirement was allowed';
    EXCEPTION WHEN check_violation THEN
        IF position(
            'active Cross-fit execution still binds protocol config'
            IN SQLERRM
        ) = 0 THEN
            RAISE;
        END IF;
    END;
END
$$;

SET LOCAL session_replication_role = replica;

UPDATE strategy_training.training_cross_fit_executions
SET state = 'FAILED', completed_at = clock_timestamp(),
    failure_code = 'INTEGRATION_TERMINAL'
WHERE cross_fit_execution_id = '54f00000-0000-0000-0000-000000000206';

SET LOCAL session_replication_role = origin;

UPDATE strategy_training.training_config_versions
SET status = 'RETIRED',
    retired_by_user_id = '54f00000-0000-0000-0000-000000000001',
    retired_at = clock_timestamp()
WHERE config_version_id = '54f00000-0000-0000-0000-000000000106';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_config_versions
        WHERE config_version_id = '54f00000-0000-0000-0000-000000000106'
          AND status = 'RETIRED'
    ) THEN
        RAISE EXCEPTION 'terminal Cross-fit protocol retirement was blocked';
    END IF;
END
$$;

ROLLBACK;
