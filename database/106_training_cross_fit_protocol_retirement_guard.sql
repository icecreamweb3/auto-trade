\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- A Cross-fit execution resolves its frozen runtime contract through the bound
-- config row during later fold transitions.  Retiring that row while an
-- execution is still active would make an already-started run fail midway.
CREATE OR REPLACE FUNCTION strategy_training.guard_active_cross_fit_protocol_retirement()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $function$
BEGIN
    IF OLD.config_type = 'CROSS_FIT_PROTOCOL'
       AND OLD.status = 'READY'
       AND NEW.status = 'RETIRED'
       AND EXISTS (
            SELECT 1
            FROM strategy_training.training_cross_fit_executions execution
            WHERE execution.protocol_config_version_id = OLD.config_version_id
              AND execution.completed_at IS NULL
       ) THEN
        RAISE EXCEPTION
            'active Cross-fit execution still binds protocol config %',
            OLD.config_version_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

ALTER FUNCTION strategy_training.guard_active_cross_fit_protocol_retirement()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.guard_active_cross_fit_protocol_retirement()
FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_guard_active_cross_fit_protocol_retirement
ON strategy_training.training_config_versions;
CREATE TRIGGER trg_guard_active_cross_fit_protocol_retirement
BEFORE UPDATE OF status ON strategy_training.training_config_versions
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION strategy_training.guard_active_cross_fit_protocol_retirement();

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '106_training_cross_fit_protocol_retirement_guard',
    encode(public.digest(
        'auto_trade_v2_106_training_cross_fit_protocol_retirement_guard_v1',
        'sha256'
    ), 'hex'),
    'Prevent retirement of protocols bound to active Cross-fit executions'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
