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
        WHERE version = '081_training_cross_fit_fold_finalization'
    ) THEN
        RAISE EXCEPTION '081 Cross-fit fold finalization migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid =
              'strategy_training.training_cross_fit_fold_executions'::regclass
          AND conname = 'training_cross_fit_fold_runtime_evidence_check'
          AND position('selected_iteration_id IS NULL' IN
                       pg_get_constraintdef(oid)) > 0
          AND position('tpe_coverage_report_hash' IN
                       pg_get_constraintdef(oid)) > 0
          AND position('random_coverage_report_hash' IN
                       pg_get_constraintdef(oid)) > 0
    ) THEN
        RAISE EXCEPTION 'paired fold runtime evidence constraint is missing';
    END IF;

    finalize_source := pg_get_functiondef(
        'strategy_training.finalize_cross_fit_fold(uuid,uuid)'::regprocedure
    );
    IF position('fold_model_version_id' IN finalize_source) = 0
       OR position('selected_iteration_id' IN finalize_source) = 0
       OR position('random_optimizer_run_id' IN finalize_source) = 0
       OR position('fitting_sample_qualified' IN finalize_source) = 0
       OR position('tpe_coverage_report_hash' IN finalize_source) = 0
       OR position('random_coverage_report_hash' IN finalize_source) = 0
       OR position('complete paired evaluation' IN finalize_source) = 0 THEN
        RAISE EXCEPTION 'fold finalization evidence is incomplete';
    END IF;

    prepare_source := pg_get_functiondef(
        'strategy_training.prepare_cross_fit_fold_finalization_task(uuid,integer)'
        ::regprocedure
    );
    IF position('CROSS_FIT_FINALIZE_FOLD' IN prepare_source) = 0
       OR position('WAITING_FOLD_FINALIZATION' IN prepare_source) = 0
       OR position('FOLD_FINALIZATION_FAILED' IN prepare_source) = 0 THEN
        RAISE EXCEPTION 'fold finalization task lifecycle is incomplete';
    END IF;

    advance_source := pg_get_functiondef(
        'strategy_training.advance_training_cross_fit_executions()'::regprocedure
    );
    IF position('prepare_cross_fit_fold_finalization_task' IN advance_source) = 0
       OR position('FOLD_FINALIZED' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'fold finalization is not part of Cross-fit progression';
    END IF;

    payload_source := pg_get_functiondef(
        'strategy_training.enforce_training_task_payload_contract()'::regprocedure
    );
    IF position(
        'WHEN ''CROSS_FIT_FINALIZE_FOLD'' THEN ''EVALUATOR''' IN payload_source
    ) = 0 THEN
        RAISE EXCEPTION 'fold finalization is not isolated to evaluator';
    END IF;

    IF NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.finalize_cross_fit_fold(uuid,uuid)', 'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.finalize_cross_fit_fold(uuid,uuid)', 'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.prepare_cross_fit_fold_finalization_task(uuid,integer)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Cross-fit fold finalization privileges are incorrect';
    END IF;
END
$$;

ROLLBACK;
