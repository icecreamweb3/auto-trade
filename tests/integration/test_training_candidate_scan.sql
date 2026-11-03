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
    ) OR has_table_privilege(
        'tb2_training_rw', 'market.klines', 'SELECT'
    ) THEN
        RAISE EXCEPTION 'candidate scan least-privilege boundary is incorrect';
    END IF;
END
$$;

ROLLBACK;
