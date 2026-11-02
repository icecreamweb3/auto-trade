\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '036_training_test_evidence_shadow' AND success
    ) THEN
        RAISE EXCEPTION 'M9 migration was not recorded successfully';
    END IF;
    IF to_regclass('strategy_training_test.test_promotion_evidence') IS NULL
       OR to_regclass('strategy_training.training_shadow_export_requests') IS NULL
       OR to_regclass('strategy_training.training_promotion_audit_log') IS NULL THEN
        RAISE EXCEPTION 'M9 evidence tables are incomplete';
    END IF;
    IF NOT has_function_privilege(
            'tb2_training_test_auditor',
            'strategy_training_test.record_test_promotion_evidence(uuid, uuid, char, char, char, uuid, uuid)',
            'EXECUTE'
       ) OR has_table_privilege(
            'tb2_training_test_auditor',
            'strategy_training.training_portfolio_equity_points', 'SELECT'
       ) THEN
        RAISE EXCEPTION 'M9 evidence boundary is incorrect';
    END IF;
END
$$;

ROLLBACK;
