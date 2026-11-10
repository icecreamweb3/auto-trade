\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE prepare_source text;
DECLARE context_source text;
DECLARE write_source text;
DECLARE completion_source text;
DECLARE guard_source text;
DECLARE advance_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '079_training_cross_fit_predictions'
    ) OR to_regclass(
        'strategy_training.training_cross_fit_predictions'
    ) IS NULL THEN
        RAISE EXCEPTION '079 Cross-fit prediction migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'strategy_training'
          AND indexname = 'ux_training_iterations_candidate_scope'
          AND indexdef LIKE '%optimizer_run_id%'
    ) THEN
        RAISE EXCEPTION 'Cross-fit candidates still collide across optimizer runs';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.prepare_cross_fit_prediction_tasks(uuid,integer)'::regprocedure
    ) INTO prepare_source;
    IF position('train_objective DESC' IN prepare_source) = 0
       OR position('trial_number' IN prepare_source) = 0
       OR position('trial_state = ''COMPLETE''' IN prepare_source) = 0
       OR position('CROSS_FIT_PREDICT' IN prepare_source) = 0 THEN
        RAISE EXCEPTION 'best TRAIN-only trial selection is not deterministic';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.training_cross_fit_prediction_context(uuid,uuid)'::regprocedure
    ) INTO context_source;
    SELECT pg_get_functiondef(
        'strategy_training.create_cross_fit_prediction_entry_event(uuid,uuid,character,uuid,uuid,bigint,text,timestamptz,timestamptz,text,numeric,numeric,numeric,numeric,uuid,uuid,uuid,uuid,character)'::regprocedure
    ) INTO write_source;
    IF position('prediction_start_at' IN context_source) = 0
       OR position('prediction_end_at' IN context_source) = 0
       OR position('p_signal_time < prediction_record.prediction_start_at' IN write_source) = 0
       OR position('p_signal_time >= prediction_record.prediction_end_at' IN write_source) = 0 THEN
        RAISE EXCEPTION 'prediction reads or writes are not bounded to the outer fold';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.complete_cross_fit_prediction(uuid,uuid,bigint,character)'::regprocedure
    ) INTO completion_source;
    IF position('COALESCE(string_agg' IN completion_source) = 0
       OR position('persisted_count <> p_event_count' IN completion_source) = 0 THEN
        RAISE EXCEPTION 'zero-event or persisted event-set completion is not audited';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.guard_training_entry_event_insert()'::regprocedure
    ) INTO guard_source;
    IF position('iteration_state = ''SUCCEEDED''' IN guard_source) = 0
       OR position('training_cross_fit_predictions' IN guard_source) = 0 THEN
        RAISE EXCEPTION 'terminal selected iteration prediction is not separately authorized';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.advance_training_cross_fit_executions()'::regprocedure
    ) INTO advance_source;
    IF position('PREDICTION_PAIR_COMPLETED' IN advance_source) = 0
       OR position('prepare_cross_fit_evaluation_tasks' IN advance_source) = 0
       OR position('EVALUATION_PAIR_COMPLETED' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'fold progression does not wait for both predictions';
    END IF;

    IF NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.prepare_cross_fit_prediction_tasks(uuid,integer)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.prepare_cross_fit_prediction_tasks(uuid,integer)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_cross_fit_prediction_context(uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Cross-fit prediction role permissions are incorrect';
    END IF;
END
$$;

ROLLBACK;
