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

ROLLBACK;
