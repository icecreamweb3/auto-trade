\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '048_training_model_a_candidate_scan' AND success
    ) THEN
        RAISE EXCEPTION 'candidate scan migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '049_training_random_baseline_strata' AND success
    ) THEN
        RAISE EXCEPTION 'random-baseline strata migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '050_training_random_baseline_outcomes' AND success
    ) THEN
        RAISE EXCEPTION 'random-baseline outcome migration was not recorded successfully';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '051_training_model_a_discovery_l0' AND success
    ) THEN
        RAISE EXCEPTION 'model-A Discovery L0 migration was not recorded successfully';
    END IF;
    IF NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_context(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_bars(uuid,uuid,bigint)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.freeze_training_iteration_entry_batch(uuid,character)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_model_a_candidate_scan_random_config(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_rw',
        'strategy_training.record_training_candidate_random_baseline(uuid,uuid,uuid,uuid,bigint,timestamp with time zone,text,uuid,uuid,numeric,numeric,text,text,text,timestamp with time zone,timestamp with time zone,timestamp with time zone,jsonb)',
        'EXECUTE'
    ) OR has_table_privilege(
        'tb2_training_rw', 'market.klines', 'SELECT'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.training_random_candidate_outcome_context(uuid,uuid,character,character)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_rw',
        'strategy_training.training_random_candidate_outcome_context(uuid,uuid,character,character)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_evaluator',
        'strategy_training.finalize_training_model_a_discovery_l0(uuid,uuid)',
        'EXECUTE'
    ) OR has_function_privilege(
        'tb2_training_optimizer',
        'strategy_training.finalize_training_model_a_discovery_l0(uuid,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'tb2_training_orchestrator',
        'strategy_training.advance_training_model_a_l0_tasks()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'candidate scan least-privilege boundary is incorrect';
    END IF;
END
$$;

ROLLBACK;
