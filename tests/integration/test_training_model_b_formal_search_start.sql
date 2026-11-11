\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE initialize_source text;
        advance_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '096_training_model_b_formal_search_start' AND success
    ) THEN
        RAISE EXCEPTION '096 migration is not recorded as successful';
    END IF;
    IF to_regprocedure(
        'strategy_training.initialize_training_model_b_formal_search(uuid)'
    ) IS NULL OR to_regprocedure(
        'strategy_training.advance_training_model_b_formal_searches()'
    ) IS NULL THEN
        RAISE EXCEPTION 'formal Model-B automatic start functions are missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid =
              'strategy_training.training_model_b_formal_search_runs'::regclass
          AND conname = 'training_model_b_formal_search_runs_gate_key'
          AND contype = 'u'
    ) THEN
        RAISE EXCEPTION 'one formal Model-B run per gate is not enforced';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.initialize_training_model_b_formal_search(uuid)'::regprocedure
    ) INTO initialize_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_training_model_b_formal_searches()'::regprocedure
    ) INTO advance_source;

    IF position('baseline_record.evidence_hash' IN initialize_source) = 0
       OR position('training_go_no_go_round_zero_baselines' IN initialize_source) = 0
       OR position('portfolio_task.state = ''SUCCEEDED''' IN initialize_source) = 0
       OR position('iteration.state = ''SUCCEEDED''' IN initialize_source) = 0
       OR position('experiment.state = ''STOPPED''' IN initialize_source) = 0
       OR position('q019_search_budget,maximum_iterations' IN initialize_source) = 0
       OR position('outcome_fields_used' IN initialize_source) = 0
       OR position('FORMAL_MODEL_B' IN initialize_source) = 0
       OR position('create_model_b_formal_search_run' IN initialize_source) = 0
       OR position('training_model_b_formal_search_inputs' IN initialize_source) = 0
       OR position('input_count <> corpus_record.event_count' IN initialize_source) = 0
       OR position('fresh formal Model-B TPE search' IN initialize_source) = 0
       OR position('fresh formal Model-B RANDOM comparator' IN initialize_source) = 0 THEN
        RAISE EXCEPTION 'formal Model-B start is missing a frozen governance gate';
    END IF;
    IF position('baseline.state = ''SUCCEEDED''' IN advance_source) = 0
       OR position('FORMAL_CORPUS_READY' IN advance_source) = 0
       OR position('portfolio_task.state = ''SUCCEEDED''' IN advance_source) = 0
       OR position('initialize_training_model_b_formal_search' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'formal Model-B automatic advancement is incomplete';
    END IF;

    IF NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.advance_training_model_b_formal_searches()',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.advance_training_model_b_formal_searches()',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_model_b',
        'strategy_training.initialize_training_model_b_formal_search(uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'formal Model-B start privilege boundary is incorrect';
    END IF;
END
$$;
