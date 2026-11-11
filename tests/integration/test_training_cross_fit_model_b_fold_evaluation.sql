\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE function_source text; advance_source text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.schema_migrations
        WHERE version = '092_training_cross_fit_model_b_fold_evaluation') THEN
        RAISE EXCEPTION '092 fold-out evaluation migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'strategy_training'
          AND table_name = 'training_cross_fit_model_b_fold_runs'
          AND column_name = 'evaluation_experiment_id'
    ) THEN
        RAISE EXCEPTION 'fold evaluation experiment anchor is missing';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.prepare_cross_fit_model_b_fold_evaluation(uuid,integer)'::regprocedure
    ) INTO function_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_cross_fit_model_b_nested_searches()'::regprocedure
    ) INTO advance_source;
    IF position('fold_record.tpe_optimizer_run_id' IN function_source) = 0
       OR position('fold_record.random_optimizer_run_id' IN function_source) = 0
       OR position('objective.net_expectancy_percentage_points DESC' IN function_source) = 0
       OR position('INDEPENDENT_FOLD_OUT' IN function_source) = 0
       OR position('event.event_role = ''FOLD_OUT''' IN function_source) = 0
       OR position('bind_cross_fit_model_b_fold_episode' IN function_source) = 0
       OR position('MODEL_B_REPLAY' IN function_source) = 0
       OR position('eligibility.prior_training_event_count' IN function_source) = 0
       OR position('eligibility.fold_out_event_count' IN function_source) = 0 THEN
        RAISE EXCEPTION 'fold-out evaluation does not preserve nested isolation';
    END IF;
    IF position('gate_run.state = ''RUNNING''' IN advance_source) = 0
       OR position('tpe.state = ''SUCCEEDED''' IN advance_source) = 0
       OR position('random_control.state = ''SUCCEEDED''' IN advance_source) = 0
       OR position('prepare_cross_fit_model_b_fold_evaluation' IN advance_source) = 0
       OR position('initialize_cross_fit_model_b_nested_search' IN advance_source) > 0 THEN
        RAISE EXCEPTION 'nested automatic advancement violates its activation boundary';
    END IF;
    IF has_function_privilege('tb2_training_evaluator',
        'strategy_training.prepare_cross_fit_model_b_fold_evaluation(uuid,integer)',
        'EXECUTE')
       OR NOT has_function_privilege('tb2_training_orchestrator',
        'strategy_training.prepare_cross_fit_model_b_fold_evaluation(uuid,integer)',
        'EXECUTE') THEN
        RAISE EXCEPTION 'fold-out evaluation privilege boundary is incorrect';
    END IF;
    IF has_function_privilege('tb2_training_evaluator',
        'strategy_training.advance_cross_fit_model_b_nested_searches()', 'EXECUTE')
       OR NOT has_function_privilege('tb2_training_orchestrator',
        'strategy_training.advance_cross_fit_model_b_nested_searches()', 'EXECUTE') THEN
        RAISE EXCEPTION 'nested advancement privilege boundary is incorrect';
    END IF;
END
$$;
