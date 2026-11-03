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
    expected_executor text;
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
    expected_executor := CASE NEW.task_type
        WHEN 'DATASET_BUILD' THEN 'WORKER'
        WHEN 'MODEL_A_EVALUATION' THEN 'EVALUATOR'
        WHEN 'MODEL_B_REPLAY' THEN 'MODEL_B'
        WHEN 'PORTFOLIO_EVALUATION' THEN 'EVALUATOR'
        WHEN 'OPTIMIZER_TRIAL' THEN 'OPTIMIZER'
        WHEN 'ARCHIVE_VERIFY' THEN 'EVALUATOR'
        ELSE NULL
    END;
    IF expected_executor IS NULL OR NEW.executor_kind <> expected_executor THEN
        RAISE EXCEPTION 'task type % requires executor %, received %',
            NEW.task_type, expected_executor, NEW.executor_kind
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_training_task_payload_contract
ON strategy_training.training_tasks;
CREATE TRIGGER trg_training_task_payload_contract
BEFORE INSERT OR UPDATE OF task_type, executor_kind, task_payload
ON strategy_training.training_tasks
FOR EACH ROW EXECUTE FUNCTION strategy_training.enforce_training_task_payload_contract();

ALTER FUNCTION strategy_training.enforce_training_task_payload_contract()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.enforce_training_task_payload_contract()
FROM PUBLIC;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '040_training_task_executor_contract',
    encode(digest('auto_trade_v2_040_training_task_executor_contract_v1', 'sha256'), 'hex'),
    'Bind every governed task type to its isolated executor role'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
