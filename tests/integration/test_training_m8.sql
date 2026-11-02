\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '035_training_llm_advisor' AND success
    ) THEN
        RAISE EXCEPTION 'M8 migration was not recorded successfully';
    END IF;
    IF to_regclass('strategy_training.training_model_advice_batches') IS NULL
       OR to_regclass('strategy_training.training_model_advice_batch_iterations') IS NULL
       OR to_regclass('strategy_training.training_search_space_requests') IS NULL
       OR to_regclass('strategy_training.training_llm_audit_log') IS NULL THEN
        RAISE EXCEPTION 'M8 audit tables are incomplete';
    END IF;
    IF NOT has_function_privilege(
            'tb2_training_llm_gateway',
            'strategy_training.record_model_advice_batch(char, text, text, jsonb, jsonb, text, jsonb, text, uuid)',
            'EXECUTE'
       ) OR has_table_privilege(
            'tb2_training_llm_gateway',
            'strategy_training.training_validation_evaluations', 'SELECT'
       ) THEN
        RAISE EXCEPTION 'M8 LLM gateway can access an invalid boundary';
    END IF;
END
$$;

ROLLBACK;
