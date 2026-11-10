\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE finalize_source text;
DECLARE prepare_source text;
DECLARE advance_source text;
DECLARE payload_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '082_training_cross_fit_candidate_corpus' AND success
    ) THEN
        RAISE EXCEPTION '082 candidate corpus migration is missing';
    END IF;
    finalize_source := pg_get_functiondef(
        'strategy_training.finalize_cross_fit_candidate_corpus(uuid,uuid)'
        ::regprocedure
    );
    IF position('optimizer_role = ''TPE''' IN finalize_source) = 0
       OR position('fitting_sample_qualified' IN finalize_source) = 0
       OR position('minimum_complete_events_per_fold' IN finalize_source) = 0
       OR position('random_report.power_status = ''READY''' IN finalize_source) = 0
       OR position('INSUFFICIENT_POWER' IN finalize_source) = 0
       OR position('training_random_entry_baselines' IN finalize_source) = 0 THEN
        RAISE EXCEPTION 'candidate corpus eligibility is not fail-closed';
    END IF;
    prepare_source := pg_get_functiondef(
        'strategy_training.prepare_cross_fit_candidate_corpus_task(uuid)'
        ::regprocedure
    );
    IF position('CROSS_FIT_FINALIZE_CORPUS' IN prepare_source) = 0
       OR position('CORPUS_FINALIZATION_FAILED' IN prepare_source) = 0 THEN
        RAISE EXCEPTION 'candidate corpus task lifecycle is incomplete';
    END IF;
    advance_source := pg_get_functiondef(
        'strategy_training.advance_training_cross_fit_executions()'::regprocedure
    );
    IF position('last_prediction_end' IN advance_source) = 0
       OR position('eligible_end_at' IN advance_source) = 0
       OR position('prepare_cross_fit_candidate_corpus_task' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'natural Cross-fit end does not finalize the corpus';
    END IF;
    payload_source := pg_get_functiondef(
        'strategy_training.enforce_training_task_payload_contract()'::regprocedure
    );
    IF position(
        'WHEN ''CROSS_FIT_FINALIZE_CORPUS'' THEN ''EVALUATOR''' IN payload_source
    ) = 0 THEN
        RAISE EXCEPTION 'candidate corpus task is not evaluator-isolated';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.finalize_cross_fit_candidate_corpus(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.finalize_cross_fit_candidate_corpus(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.prepare_cross_fit_candidate_corpus_task(uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'candidate corpus privileges are incorrect';
    END IF;
END
$$;

ROLLBACK;
