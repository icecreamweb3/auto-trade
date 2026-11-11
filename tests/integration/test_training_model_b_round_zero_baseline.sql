\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE initialize_source text; finalize_source text; advance_source text;
        effective_source text; candidate_constraint text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '095_training_model_b_round_zero_baseline'
    ) OR to_regclass(
        'strategy_training.training_model_b_round_zero_baseline_runs'
    ) IS NULL THEN
        RAISE EXCEPTION '095 round-zero baseline migration is missing';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO candidate_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_iterations'::regclass
      AND conname = 'training_iterations_candidate_source_check';
    SELECT pg_get_functiondef(
        'strategy_training.initialize_training_model_b_round_zero_baseline(uuid)'::regprocedure
    ) INTO initialize_source;
    SELECT pg_get_functiondef(
        'strategy_training.finalize_training_model_b_round_zero_baseline(uuid,uuid)'::regprocedure
    ) INTO finalize_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_training_model_b_round_zero_baselines()'::regprocedure
    ) INTO advance_source;
    SELECT pg_get_functiondef(
        'strategy_training.training_effective_model_b_exit_config(uuid,uuid)'::regprocedure
    ) INTO effective_source;
    IF position('ROUND_ZERO_BASELINE' IN candidate_constraint) = 0
       OR position('TIME_EXIT_V1' IN initialize_source) = 0
       OR position('interval ''24 hours''' IN initialize_source) = 0
       OR position('formal_model_b_cross_fit_entries' IN initialize_source) = 0
       OR position('MODEL_B_REPLAY' IN initialize_source) = 0 THEN
        RAISE EXCEPTION 'round-zero initialization is not a real 24h replay';
    END IF;
    IF position('training_portfolio_runs' IN finalize_source) = 0
       OR position('training_exit_outcomes' IN finalize_source) = 0
       OR position('training_portfolio_trades' IN finalize_source) = 0
       OR position('training_go_no_go_round_zero_baselines' IN finalize_source) = 0
       OR position('task_record.lease_token IS DISTINCT FROM p_lease_token'
                   IN finalize_source) = 0 THEN
        RAISE EXCEPTION 'round-zero evidence is not derived under evaluator lease';
    END IF;
    IF position('PORTFOLIO_EVALUATION' IN advance_source) = 0
       OR position('ROUND_ZERO_EVIDENCE_MISSING' IN advance_source) = 0
       OR position('training_model_b_round_zero_baseline_runs'
                   IN effective_source) = 0 THEN
        RAISE EXCEPTION 'round-zero orchestration is incomplete';
    END IF;
    IF has_function_privilege('tb2_training_orchestrator',
        'strategy_training.finalize_training_model_b_round_zero_baseline(uuid,uuid)',
        'EXECUTE')
       OR NOT has_function_privilege('tb2_training_evaluator',
        'strategy_training.finalize_training_model_b_round_zero_baseline(uuid,uuid)',
        'EXECUTE')
       OR has_function_privilege('tb2_training_evaluator',
        'strategy_training.advance_training_model_b_round_zero_baselines()',
        'EXECUTE')
       OR NOT has_function_privilege('tb2_training_orchestrator',
        'strategy_training.advance_training_model_b_round_zero_baselines()',
        'EXECUTE') THEN
        RAISE EXCEPTION 'round-zero role boundary is incorrect';
    END IF;
END
$$;
