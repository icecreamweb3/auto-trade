\set ON_ERROR_STOP on
\pset pager off

DO $$
DECLARE source text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.schema_migrations
        WHERE version = '090_training_cross_fit_model_b_fold_eligibility') THEN
        RAISE EXCEPTION '090 Model-B fold eligibility migration is missing';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.freeze_cross_fit_model_b_fold_eligibility(uuid)'::regprocedure
    ) INTO source;
    IF position('entry.signal_time < scope.effective_train_end_at' IN source) = 0
       OR position('entry.signal_time >= scope.prediction_start_at' IN source) = 0
       OR position('minimum_complete_events_per_fold' IN source) = 0
       OR position('MODEL_B_NESTED_INSUFFICIENT_POWER' IN source) = 0
       OR position('outcome' IN lower(source)) > 0 THEN
        RAISE EXCEPTION 'Model-B eligibility is not outcome-blind or lacks power gates';
    END IF;
    IF has_function_privilege('tb2_training_evaluator',
        'strategy_training.freeze_cross_fit_model_b_fold_eligibility(uuid)', 'EXECUTE')
       OR NOT has_function_privilege('tb2_training_orchestrator',
        'strategy_training.freeze_cross_fit_model_b_fold_eligibility(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Model-B eligibility execution privilege is incorrect';
    END IF;
END
$$;
