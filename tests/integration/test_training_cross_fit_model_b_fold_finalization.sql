\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE finalize_source text; advance_source text; payload_source text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.schema_migrations
        WHERE version = '093_training_cross_fit_model_b_fold_finalization') THEN
        RAISE EXCEPTION '093 Model-B fold finalization migration is missing';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.finalize_cross_fit_model_b_fold_task(uuid,uuid)'::regprocedure
    ) INTO finalize_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_cross_fit_model_b_nested_searches()'::regprocedure
    ) INTO advance_source;
    SELECT pg_get_functiondef(
        'strategy_training.enforce_training_task_payload_contract()'::regprocedure
    ) INTO payload_source;
    IF position('task_record.lease_token IS DISTINCT FROM p_lease_token'
                IN finalize_source) = 0
       OR position('replay.state <> ''SUCCEEDED''' IN finalize_source) = 0
       OR position('episode.status <> ''DECIDED''' IN finalize_source) = 0
       OR position('finalize_cross_fit_model_b_fold_evidence' IN finalize_source) = 0
       OR position('transition_training_iteration' IN finalize_source) = 0
       OR position('transition_training_experiment' IN finalize_source) = 0 THEN
        RAISE EXCEPTION 'Model-B fold finalization lease boundary is incomplete';
    END IF;
    IF position('CROSS_FIT_MODEL_B_FINALIZE_FOLD' IN advance_source) = 0
       OR position('create_cross_fit_model_b_nested_fold_pair' IN advance_source) = 0
       OR position('eligibility.eligibility = ''ELIGIBLE''' IN advance_source) = 0
       OR position('CROSS_FIT_MODEL_B_FINALIZE_FOLD' IN payload_source) = 0 THEN
        RAISE EXCEPTION 'Model-B fold automatic progression is incomplete';
    END IF;
    IF has_function_privilege('tb2_training_orchestrator',
        'strategy_training.finalize_cross_fit_model_b_fold_task(uuid,uuid)',
        'EXECUTE')
       OR NOT has_function_privilege('tb2_training_evaluator',
        'strategy_training.finalize_cross_fit_model_b_fold_task(uuid,uuid)',
        'EXECUTE') THEN
        RAISE EXCEPTION 'Model-B fold finalizer privilege boundary is incorrect';
    END IF;
END
$$;
