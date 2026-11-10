\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE advance_source text; prepare_source text; wrapper_source text;
        stratum_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '080_training_cross_fit_prediction_evaluation' AND success
    ) OR to_regclass(
        'strategy_training.training_cross_fit_prediction_coverage_reports'
    ) IS NULL THEN
        RAISE EXCEPTION 'Cross-fit prediction evaluation migration is incomplete';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'strategy_training'
          AND table_name = 'training_cross_fit_predictions'
          AND column_name = 'evaluation_task_id'
    ) THEN
        RAISE EXCEPTION 'Cross-fit predictions do not bind their evaluator task';
    END IF;
    prepare_source := pg_get_functiondef(
        'strategy_training.prepare_cross_fit_evaluation_tasks(uuid,integer)'::regprocedure
    );
    IF position('MODEL_A_EVALUATION' IN prepare_source) = 0
       OR position('CROSS_FIT_EVALUATION_V1' IN prepare_source) = 0
       OR position('FOLD_EVALUATION_FAILED' IN prepare_source) = 0
       OR position('event_count = 0' IN prepare_source) = 0 THEN
        RAISE EXCEPTION 'Cross-fit evaluation scheduling is not fail-closed or zero-safe';
    END IF;
    advance_source := pg_get_functiondef(
        'strategy_training.advance_training_cross_fit_executions()'::regprocedure
    );
    IF position('prepare_cross_fit_evaluation_tasks' IN advance_source) = 0
       OR position('EVALUATION_PAIR_COMPLETED' IN advance_source) = 0
       OR position('prepare_cross_fit_fold_finalization_task' IN advance_source) = 0
       OR position('FOLD_FINALIZED' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'Cross-fit orchestration can bypass prediction evaluation';
    END IF;
    wrapper_source := pg_get_functiondef(
        'strategy_training.finalize_training_random_baseline_coverage(uuid,uuid)'::regprocedure
    );
    IF position('finalize_cross_fit_prediction_coverage' IN wrapper_source) = 0
       OR position('finalize_standard_training_random_baseline_coverage' IN wrapper_source) = 0 THEN
        RAISE EXCEPTION 'coverage finalization does not isolate Cross-fit from discovery';
    END IF;
    stratum_source := pg_get_functiondef(
        'strategy_training.record_cross_fit_prediction_signal_stratum(uuid,uuid,character,uuid,text,text,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,jsonb)'::regprocedure
    );
    IF position('CROSS_FIT_PREDICT' IN stratum_source) = 0
       OR position('training_random_baseline_signal_strata' IN stratum_source) = 0
       OR position('prediction_record.completed_at IS NOT NULL' IN stratum_source) = 0 THEN
        RAISE EXCEPTION 'Cross-fit strata are not bound to the active prediction lease';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_cross_fit_prediction_signal_stratum(uuid,uuid,character,uuid,text,text,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,jsonb)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.prepare_cross_fit_evaluation_tasks(uuid,integer)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Cross-fit prediction/evaluation role separation is incorrect';
    END IF;
END
$$;

ROLLBACK;
