\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '034_training_weak_holdout' AND success
    ) THEN
        RAISE EXCEPTION 'M7 migration was not recorded successfully';
    END IF;
    IF to_regclass('strategy_training.training_validation_scopes') IS NULL
       OR to_regclass('strategy_training_weak_holdout.weak_holdout_runs') IS NULL
       OR to_regclass('strategy_training_weak_holdout.weak_holdout_access_log') IS NULL
       OR to_regclass('strategy_training_test.test_logical_scopes') IS NULL
       OR to_regclass('strategy_training_test.test_retry_approval_requests') IS NULL THEN
        RAISE EXCEPTION 'M7 isolation tables are incomplete';
    END IF;
    IF NOT has_schema_privilege(
            'tb2_training_weak_holdout_executor',
            'strategy_training_weak_holdout', 'USAGE'
       ) OR has_schema_privilege(
            'tb2_training_test_executor',
            'strategy_training_weak_holdout', 'USAGE'
       ) THEN
        RAISE EXCEPTION 'M7 service-account schema boundaries are incorrect';
    END IF;
END
$$;

ROLLBACK;
