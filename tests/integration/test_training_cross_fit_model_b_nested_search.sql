\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE initialize_source text; pair_source text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.schema_migrations
        WHERE version = '091_training_cross_fit_model_b_nested_search') THEN
        RAISE EXCEPTION '091 nested Model-B search migration is missing';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.initialize_cross_fit_model_b_nested_search(uuid)'::regprocedure
    ) INTO initialize_source;
    SELECT pg_get_functiondef(
        'strategy_training.create_cross_fit_model_b_nested_fold_pair(uuid,integer)'::regprocedure
    ) INTO pair_source;
    IF position('freeze_cross_fit_model_b_fold_eligibility' IN initialize_source) = 0
       OR position('Q036_MODEL_B_TEMPORARY' IN initialize_source) = 0
       OR position('MODEL_B_SEARCH_SPACE' IN initialize_source) = 0
       OR position('first_fold' IN initialize_source) = 0
       OR position('prior_eligible_fold' IN pair_source) = 0
       OR position('eligibility_record.eligibility_hash' IN pair_source) = 0 THEN
        RAISE EXCEPTION 'nested search does not consume frozen eligible folds';
    END IF;
    IF has_function_privilege('tb2_training_evaluator',
        'strategy_training.initialize_cross_fit_model_b_nested_search(uuid)','EXECUTE')
       OR NOT has_function_privilege('tb2_training_orchestrator',
        'strategy_training.initialize_cross_fit_model_b_nested_search(uuid)','EXECUTE') THEN
        RAISE EXCEPTION 'nested search privilege boundary is incorrect';
    END IF;
END
$$;
