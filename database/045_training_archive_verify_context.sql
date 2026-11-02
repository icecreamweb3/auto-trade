\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.training_archive_verify_context(
    p_task_id uuid,
    p_lease_token uuid
)
RETURNS TABLE (
    archive_manifest_id uuid,
    artifact_kind text,
    storage_uri_hash char(64),
    row_count bigint,
    minimum_observed_at timestamptz,
    maximum_observed_at timestamptz,
    object_size_bytes bigint,
    content_sha256 char(64)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    leased_task strategy_training.training_tasks%ROWTYPE;
    manifest strategy_training.training_archive_manifests%ROWTYPE;
    payload_manifest_id uuid;
    storage_key text;
BEGIN
    SELECT * INTO STRICT leased_task
    FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;

    IF leased_task.task_type <> 'ARCHIVE_VERIFY'
       OR leased_task.executor_kind <> 'EVALUATOR'
       OR leased_task.state <> 'RUNNING'
       OR leased_task.lease_token IS DISTINCT FROM p_lease_token
       OR leased_task.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'archive verification requires the current active evaluator lease'
            USING ERRCODE = '42501';
    END IF;

    IF jsonb_typeof(leased_task.task_payload -> 'archive_manifest_id') <> 'string'
       OR jsonb_typeof(leased_task.task_payload -> 'storage_key') <> 'string' THEN
        RAISE EXCEPTION 'archive verification payload is incomplete'
            USING ERRCODE = '23514';
    END IF;
    payload_manifest_id := (leased_task.task_payload ->> 'archive_manifest_id')::uuid;
    storage_key := leased_task.task_payload ->> 'storage_key';
    IF btrim(storage_key) = '' THEN
        RAISE EXCEPTION 'archive storage key cannot be blank' USING ERRCODE = '23514';
    END IF;

    SELECT * INTO STRICT manifest
    FROM strategy_training.training_archive_manifests
    WHERE training_archive_manifests.archive_manifest_id = payload_manifest_id;

    IF manifest.state <> 'STORED'
       OR manifest.iteration_id IS DISTINCT FROM leased_task.iteration_id
       OR NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_l2_retention_plans plan
            WHERE plan.retention_plan_id = manifest.retention_plan_id
              AND plan.experiment_id = leased_task.experiment_id
       ) THEN
        RAISE EXCEPTION 'archive manifest is not a stored artifact in the leased task scope'
            USING ERRCODE = '23514';
    END IF;
    IF encode(public.digest(storage_key, 'sha256'), 'hex') <> manifest.storage_uri_hash THEN
        RAISE EXCEPTION 'archive storage key does not match the frozen manifest'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY SELECT manifest.archive_manifest_id, manifest.artifact_kind::text,
        manifest.storage_uri_hash, manifest.row_count, manifest.minimum_observed_at,
        manifest.maximum_observed_at, manifest.object_size_bytes, manifest.content_sha256;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_archive_verify_result(
    p_task_id uuid,
    p_lease_token uuid,
    p_restored_row_count bigint,
    p_restored_minimum_at timestamptz,
    p_restored_maximum_at timestamptz,
    p_restored_size_bytes bigint,
    p_restored_sha256 char(64)
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    context_record record;
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_archive_verify_context(p_task_id, p_lease_token);
    RETURN strategy_training.verify_training_archive_restore(
        context_record.archive_manifest_id,
        p_restored_row_count,
        p_restored_minimum_at,
        p_restored_maximum_at,
        p_restored_size_bytes,
        p_restored_sha256
    );
END
$$;

ALTER FUNCTION strategy_training.training_archive_verify_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_archive_verify_result(
    uuid, uuid, bigint, timestamptz, timestamptz, bigint, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.training_archive_verify_context(uuid, uuid)
FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.record_training_archive_verify_result(
    uuid, uuid, bigint, timestamptz, timestamptz, bigint, char(64)
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION strategy_training.verify_training_archive_restore(
    uuid, bigint, timestamptz, timestamptz, bigint, char(64)
) FROM tb2_training_evaluator;

GRANT EXECUTE ON FUNCTION strategy_training.training_archive_verify_context(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.record_training_archive_verify_result(
    uuid, uuid, bigint, timestamptz, timestamptz, bigint, char(64)
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '045_training_archive_verify_context',
    encode(digest('auto_trade_v2_045_training_archive_verify_context_v1', 'sha256'), 'hex'),
    'Bind isolated Parquet restore verification to the active evaluator task lease'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
