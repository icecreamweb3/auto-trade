\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.enforce_training_task_payload_contract()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE
    payload_version_text text;
BEGIN
    IF jsonb_typeof(NEW.task_payload -> 'task_type') <> 'string'
       OR NEW.task_payload ->> 'task_type' IS DISTINCT FROM NEW.task_type THEN
        RAISE EXCEPTION 'task payload task_type must match the task row'
            USING ERRCODE = '23514';
    END IF;
    payload_version_text := NEW.task_payload ->> 'payload_version';
    IF jsonb_typeof(NEW.task_payload -> 'payload_version') <> 'number'
       OR payload_version_text !~ '^[1-9][0-9]*$' THEN
        RAISE EXCEPTION 'task payload_version must be a positive integer'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_training_task_payload_contract
ON strategy_training.training_tasks;
CREATE TRIGGER trg_training_task_payload_contract
BEFORE INSERT OR UPDATE OF task_type, task_payload
ON strategy_training.training_tasks
FOR EACH ROW EXECUTE FUNCTION strategy_training.enforce_training_task_payload_contract();

ALTER FUNCTION strategy_training.enforce_training_task_payload_contract()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.enforce_training_task_payload_contract()
FROM PUBLIC;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '038_training_task_payload_contract',
    encode(digest('auto_trade_v2_038_training_task_payload_contract_v1', 'sha256'), 'hex'),
    'Bind versioned task payloads to their authoritative task type'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
