\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- The gateway receives EXECUTE only on SECURITY DEFINER functions, but still
-- needs schema USAGE to resolve their qualified names. It receives no table
-- SELECT/INSERT/UPDATE/DELETE privileges.
GRANT USAGE ON SCHEMA strategy_training TO tb2_training_llm_gateway;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '037_training_llm_gateway_schema_usage',
    encode(digest('auto_trade_v2_037_training_llm_gateway_schema_usage_v1', 'sha256'), 'hex'),
    'Grant schema usage required to invoke the restricted LLM gateway functions'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
