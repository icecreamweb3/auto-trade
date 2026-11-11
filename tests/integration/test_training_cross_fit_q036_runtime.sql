\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE context_source text; finalize_source text; payload_source text;
BEGIN
    IF to_regclass('strategy_training.training_cross_fit_model_b_gate_runs') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_model_b_gate_metrics') IS NULL THEN
        RAISE EXCEPTION 'Q-036 temporary Model-B evidence tables are missing';
    END IF;
    context_source := pg_get_functiondef(
        'strategy_training.training_cross_fit_gate_context(uuid,uuid)'::regprocedure
    );
    IF position('training_random_baseline_candidate_outcomes' IN context_source) = 0
       OR position('training_cross_fit_model_b_gate_metrics' IN context_source) = 0
       OR position('evidence_count <> corpus_record.event_count' IN context_source) = 0
       OR position('CROSS_FIT_MODEL_A_CANDIDATE' IN context_source) = 0 THEN
        RAISE EXCEPTION 'Q-036 context does not require one fixed complete evidence set';
    END IF;
    finalize_source := pg_get_functiondef(
        'strategy_training.finalize_cross_fit_model_b_gate_run(uuid)'::regprocedure
    );
    IF position('observed_count <> expected_count' IN finalize_source) = 0
       OR position('run.state = ''SUCCEEDED''' IN finalize_source) = 0 THEN
        RAISE EXCEPTION 'temporary Model-B evidence can finalize incompletely';
    END IF;
    payload_source := pg_get_functiondef(
        'strategy_training.enforce_training_task_payload_contract()'::regprocedure
    );
    IF position(
        'WHEN ''CROSS_FIT_EVALUATE_GATE'' THEN ''EVALUATOR''' IN payload_source
    ) = 0 THEN
        RAISE EXCEPTION 'Q-036 task is not evaluator-isolated';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_cross_fit_gate_context(uuid,uuid)', 'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_cross_fit_gate_context(uuid,uuid)', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Q-036 runtime privilege boundary is incorrect';
    END IF;
END
$$;

ROLLBACK;
