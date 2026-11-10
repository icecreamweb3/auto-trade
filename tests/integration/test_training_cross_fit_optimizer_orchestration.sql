\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE prepare_source text;
DECLARE advance_source text;
DECLARE payload_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '078_training_cross_fit_optimizer_orchestration'
    ) THEN
        RAISE EXCEPTION '078 Cross-fit optimizer orchestration migration is missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'strategy_training.training_tasks'::regclass
          AND conname = 'training_tasks_task_type_check'
          AND position(
              'CROSS_FIT_COORDINATE' IN pg_get_constraintdef(oid)
          ) > 0
    ) THEN
        RAISE EXCEPTION 'Cross-fit coordination task type is not installed';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.prepare_cross_fit_optimizer_pair(uuid,uuid)'::regprocedure
    ) INTO prepare_source;
    IF position('start_cross_fit_execution' IN prepare_source) = 0
       OR position('register_cross_fit_optimizer_scope' IN prepare_source) = 0
       OR position('previous Cross-fit fold is not finalized' IN prepare_source) = 0
       OR position('TPE' IN prepare_source) = 0
       OR position('RANDOM' IN prepare_source) = 0 THEN
        RAISE EXCEPTION 'optimizer pair preparation is not lease-bound and sequential';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.advance_training_cross_fit_executions()'::regprocedure
    ) INTO advance_source;
    IF position('CROSS_FIT_COORDINATE' IN advance_source) = 0
       OR position('WAITING_OPTIMIZER_PAIR' IN advance_source) = 0
       OR position('WAITING_FOLD_FINALIZATION' IN advance_source) = 0
       OR position('FOLD_OPTIMIZER_FAILED' IN advance_source) = 0
       OR position('CROSS_FIT_WALL_CLOCK_EXCEEDED' IN advance_source) = 0 THEN
        RAISE EXCEPTION 'Cross-fit orchestrator progression is incomplete';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.enforce_training_task_payload_contract()'::regprocedure
    ) INTO payload_source;
    IF position(
        'WHEN ''CROSS_FIT_COORDINATE'' THEN ''EVALUATOR''' IN payload_source
    ) = 0 THEN
        RAISE EXCEPTION 'Cross-fit coordination is not isolated to evaluator';
    END IF;

    IF NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.prepare_cross_fit_optimizer_pair(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.prepare_cross_fit_optimizer_pair(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.advance_training_cross_fit_executions()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Cross-fit optimizer orchestration privileges are incorrect';
    END IF;
END
$$;

ROLLBACK;
