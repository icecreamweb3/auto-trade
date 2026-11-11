\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE finalize_source text;
        advance_source text;
        payload_source text;
        task_constraint text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '097_training_model_b_formal_search_finalization'
          AND success
    ) THEN
        RAISE EXCEPTION '097 migration is not recorded as successful';
    END IF;
    IF to_regclass(
        'strategy_training.training_model_b_formal_search_comparisons'
    ) IS NULL OR to_regclass(
        'strategy_training.training_model_b_formal_search_finalists'
    ) IS NULL THEN
        RAISE EXCEPTION 'formal Model-B comparison or finalist table is missing';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO task_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_tasks'::regclass
      AND conname = 'training_tasks_task_type_check';
    IF position('MODEL_B_FINALIZE_FORMAL' IN task_constraint) = 0 THEN
        RAISE EXCEPTION 'formal Model-B finalizer task type is missing';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.finalize_training_model_b_formal_search(uuid,uuid)'::regprocedure
    ) INTO finalize_source;
    SELECT pg_get_functiondef(
        'strategy_training.advance_training_model_b_formal_searches()'::regprocedure
    ) INTO advance_source;
    SELECT pg_get_functiondef(
        'strategy_training.enforce_training_task_payload_contract()'::regprocedure
    ) INTO payload_source;

    IF position('MODEL_B_FINALIZE_FORMAL' IN payload_source) = 0
       OR position('fixed_finalist_count' IN finalize_source) = 0
       OR position('tpe_result_count <> stop_record.effective_trial_count'
                   IN finalize_source) = 0
       OR position('random_result_count <> stop_record.effective_trial_count'
                   IN finalize_source) = 0
       OR position('formal_stop_evidence_hash' IN finalize_source) = 0
       OR position('count(DISTINCT candidate_content_hash)' IN finalize_source) = 0
       OR position('DISTINCT ON (result.candidate_content_hash)' IN finalize_source) = 0
       OR position('finalist_manifest_hash' IN finalize_source) = 0
       OR position('baseline_net_expectancy_percentage_points' IN finalize_source) = 0
       OR position('tpe_minus_random_objective' IN finalize_source) = 0
       OR position('training_model_b_formal_search_selections' IN finalize_source) > 0 THEN
        RAISE EXCEPTION 'formal comparison/finalist governance is incomplete';
    END IF;
    IF position('MODEL_B_FINALIZE_FORMAL' IN advance_source) = 0
       OR position('FORMAL_OPTIMIZER_FAILED' IN advance_source) = 0
       OR position('FORMAL_FINALIZATION_FAILED' IN advance_source) = 0
       OR position('FORMAL_EVIDENCE_MISSING' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'formal search automatic finalization is incomplete';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.finalize_training_model_b_formal_search(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.finalize_training_model_b_formal_search(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.finalize_training_model_b_formal_search(uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'formal finalization privilege boundary is incorrect';
    END IF;
END
$$;
