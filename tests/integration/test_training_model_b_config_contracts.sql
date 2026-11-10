\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE
    constraint_source text;
    guard_source text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '083_training_model_b_config_contracts'
    ) THEN
        RAISE EXCEPTION '083 Model-B config contracts migration is missing';
    END IF;

    SELECT pg_get_constraintdef(oid)
    INTO STRICT constraint_source
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_config_versions'::regclass
      AND conname = 'training_config_versions_config_type_check';
    IF position('MODEL_B_SEARCH_SPACE' IN constraint_source) = 0 THEN
        RAISE EXCEPTION 'MODEL_B_SEARCH_SPACE is absent from the database config contract';
    END IF;

    SELECT pg_get_functiondef(
        'strategy_training.guard_training_model_b_config_ready()'::regprocedure
    ) INTO guard_source;
    IF position('RULE_BASED_EXIT_V1' IN guard_source) = 0
       OR position('hard_max_holding_seconds' IN guard_source) = 0
       OR position('BCA_CLUSTER_BOOTSTRAP' IN guard_source) = 0
       OR position('CROSS_FIT_MODEL_A' IN guard_source) = 0
       OR position('ORACLE_ENTRY_BENCHMARK' IN guard_source) = 0 THEN
        RAISE EXCEPTION 'Model-B READY guard omits a governed search/scoring/source boundary';
    END IF;

    IF has_function_privilege(
        'tb2_training_rw',
        'strategy_training.guard_training_model_b_config_ready()',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'training worker can execute the Model-B READY trigger directly';
    END IF;
END
$$;

ROLLBACK;
