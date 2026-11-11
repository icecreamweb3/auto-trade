\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE advance_source text; restart_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '100_training_cross_fit_scan_scope_recovery'
          AND success
    ) THEN
        RAISE EXCEPTION 'migration 100 was not recorded';
    END IF;
    IF to_regclass('strategy_training.training_cross_fit_restarts') IS NULL THEN
        RAISE EXCEPTION 'Cross-fit restart audit facts are missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'strategy_training.training_cross_fit_restarts'::regclass
          AND tgname = 'trg_training_cross_fit_restarts_append_only'
          AND tgenabled <> 'D'
    ) THEN
        RAISE EXCEPTION 'Cross-fit restart facts are not append-only';
    END IF;
    SELECT pg_get_functiondef(
        'strategy_training.advance_training_candidate_scans()'::regprocedure
    ) INTO advance_source;
    SELECT pg_get_functiondef(
        'strategy_training.restart_cross_fit_after_scan_scope_failure(uuid,uuid)'
        ::regprocedure
    ) INTO restart_source;
    IF position('run.optimizer_run_id' IN advance_source) = 0
       OR position('candidate.optimizer_run_id' IN advance_source) = 0
       OR position('enqueue_training_task' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'candidate scan enqueue loses its optimizer scope link';
    END IF;
    IF position('assert_active_training_role' IN restart_source) = 0
       OR position('CANDIDATE_SCAN_SCOPE_LINK_MISSING' IN restart_source) = 0
       OR position('task.optimizer_run_id IS NULL' IN restart_source) = 0
       OR position('request_training_task_cancellation' IN restart_source) = 0
       OR position('transition_training_optimizer_run' IN restart_source) = 0
       OR position('transition_training_experiment' IN restart_source) = 0
       OR position('create_cross_fit_execution' IN restart_source) = 0
       OR position('training_cross_fit_restarts' IN restart_source) = 0 THEN
        RAISE EXCEPTION 'audited Cross-fit recovery contract is incomplete';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.restart_cross_fit_after_scan_scope_failure(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.restart_cross_fit_after_scan_scope_failure(uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Cross-fit recovery permission boundary is invalid';
    END IF;
END
$$;

ROLLBACK;
