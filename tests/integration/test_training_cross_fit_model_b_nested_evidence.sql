\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE register_source text;
        finalize_source text;
        preparation_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '089_training_cross_fit_model_b_nested_evidence'
    ) THEN
        RAISE EXCEPTION '089 nested Model-B evidence migration is missing';
    END IF;
    IF to_regclass('strategy_training.training_cross_fit_model_b_fold_runs') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_model_b_fold_events') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_model_b_fold_metrics') IS NULL THEN
        RAISE EXCEPTION 'nested Model-B evidence tables are missing';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.register_cross_fit_model_b_fold_run(uuid,integer,uuid,uuid)'::regprocedure
    ) INTO register_source;
    IF position('TRAIN_PRIOR' IN register_source) = 0
       OR position('FOLD_OUT' IN register_source) = 0
       OR position('entry.signal_time < training_end' IN register_source) = 0
       OR position('entry.signal_time >= prediction_start' IN register_source) = 0
       OR position('prior.state = ''SUCCEEDED''' IN register_source) = 0 THEN
        RAISE EXCEPTION 'nested fold registration does not freeze prior/fold-out boundaries';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.finalize_cross_fit_model_b_fold_evidence(uuid,integer)'::regprocedure
    ) INTO finalize_source;
    IF position('gate_record.stress_multiplier' IN finalize_source) = 0
       OR position('outcome.entry_fee + outcome.exit_fee + outcome.slippage_total'
                   IN finalize_source) = 0
       OR position('observed_count <> expected_count' IN finalize_source) = 0 THEN
        RAISE EXCEPTION 'fold evidence does not recompute and completeness-check stress cost';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.training_model_b_candidate_preparation_context(uuid,uuid)'::regprocedure
    ) INTO preparation_source;
    IF position('event.event_role = ''TRAIN_PRIOR''' IN preparation_source) = 0
       OR position('entry.signal_time < fold_run.training_end_at' IN preparation_source) = 0
       OR position('temporary Model-B optimizer is not bound to an outer fold'
                   IN preparation_source) = 0 THEN
        RAISE EXCEPTION 'temporary candidate preparation can observe non-prior fold events';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.routine_privileges privilege
        WHERE privilege.routine_schema = 'strategy_training'
          AND privilege.routine_name = 'finalize_cross_fit_model_b_nested_gate'
          AND privilege.grantee = 'PUBLIC'
          AND privilege.privilege_type = 'EXECUTE'
    ) OR NOT has_function_privilege('tb2_training_evaluator',
        'strategy_training.finalize_cross_fit_model_b_nested_gate(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'nested Model-B evidence privilege boundary is incorrect';
    END IF;
END
$$;
