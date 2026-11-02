\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training_weak_holdout.weak_holdout_runs (
    weak_holdout_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    model_a_version_id uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    model_b_version_id uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    dataset_version_id uuid NOT NULL,
    exposure_status varchar(16) NOT NULL DEFAULT 'DECLARED'
        CHECK (exposure_status = 'DECLARED'),
    state varchar(16) NOT NULL DEFAULT 'DRAFT'
        CHECK (state IN ('DRAFT', 'RUNNING', 'SUCCEEDED', 'FAILED')),
    requested_by_user_id uuid NOT NULL REFERENCES core.app_users,
    result_hash char(64),
    failure_code varchar(64),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at timestamptz,
    ended_at timestamptz,
    CHECK (result_hash IS NULL OR result_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((state IN ('DRAFT', 'RUNNING') AND ended_at IS NULL) OR
           (state IN ('SUCCEEDED', 'FAILED') AND ended_at IS NOT NULL)),
    CHECK ((state = 'SUCCEEDED' AND result_hash IS NOT NULL AND failure_code IS NULL)
        OR (state = 'FAILED' AND failure_code IS NOT NULL)
        OR (state IN ('DRAFT', 'RUNNING'))
)
);

CREATE TABLE strategy_training_weak_holdout.weak_holdout_access_log (
    access_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    weak_holdout_run_id uuid NOT NULL REFERENCES strategy_training_weak_holdout.weak_holdout_runs,
    actor_user_id uuid REFERENCES core.app_users,
    actor_service text,
    access_kind varchar(16) NOT NULL CHECK (access_kind IN ('CREATE', 'READ', 'COMPLETE')),
    allowed boolean NOT NULL,
    reason_code varchar(64) NOT NULL,
    request_id uuid NOT NULL,
    accessed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((actor_user_id IS NOT NULL AND actor_service IS NULL)
        OR (actor_user_id IS NULL AND actor_service IS NOT NULL AND btrim(actor_service) <> '')),
    CHECK (btrim(reason_code) <> '')
);

CREATE OR REPLACE FUNCTION strategy_training_weak_holdout.create_run(
    p_model_a_version_id uuid, p_model_b_version_id uuid, p_dataset_version_id uuid,
    p_requested_by_user_id uuid, p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_weak_holdout, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_requested_by_user_id, 'TRAINING_ADMIN');
    IF NOT EXISTS (SELECT 1 FROM strategy_training.training_model_versions
                   WHERE model_version_id = p_model_a_version_id
                     AND model_type = 'MODEL_A' AND state = 'LOCKED')
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_model_versions
                      WHERE model_version_id = p_model_b_version_id
                        AND model_type = 'MODEL_B' AND state = 'LOCKED') THEN
        RAISE EXCEPTION 'weak holdout requires locked MODEL_A and MODEL_B' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training_weak_holdout.weak_holdout_runs (
        weak_holdout_run_id, model_a_version_id, model_b_version_id,
        dataset_version_id, requested_by_user_id
    ) VALUES (new_id, p_model_a_version_id, p_model_b_version_id,
              p_dataset_version_id, p_requested_by_user_id);
    INSERT INTO strategy_training_weak_holdout.weak_holdout_access_log (
        weak_holdout_run_id, actor_user_id, access_kind, allowed, reason_code, request_id
    ) VALUES (new_id, p_requested_by_user_id, 'CREATE', true, 'CREATED', p_request_id);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_weak_holdout.start_run(
    p_run_id uuid, p_request_id uuid, p_requester_service text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_weak_holdout
AS $$
BEGIN
    UPDATE strategy_training_weak_holdout.weak_holdout_runs
    SET state = 'RUNNING', started_at = clock_timestamp()
    WHERE weak_holdout_run_id = p_run_id AND state = 'DRAFT';
    IF NOT FOUND THEN RAISE EXCEPTION 'weak holdout run is not DRAFT' USING ERRCODE = '55000'; END IF;
    INSERT INTO strategy_training_weak_holdout.weak_holdout_access_log (
        weak_holdout_run_id, actor_service, access_kind, allowed, reason_code, request_id
    ) VALUES (p_run_id, p_requester_service, 'READ', true, 'STARTED', p_request_id);
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_weak_holdout.complete_run(
    p_run_id uuid, p_result_hash char(64), p_failure_code text,
    p_request_id uuid, p_requester_service text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_weak_holdout
AS $$
DECLARE new_state text;
BEGIN
    IF p_result_hash IS NULL OR p_result_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'weak holdout result hash is required' USING ERRCODE = '22023';
    END IF;
    new_state := CASE WHEN p_failure_code IS NULL THEN 'SUCCEEDED' ELSE 'FAILED' END;
    UPDATE strategy_training_weak_holdout.weak_holdout_runs
    SET state = new_state, result_hash = CASE WHEN new_state = 'SUCCEEDED' THEN p_result_hash END,
        failure_code = CASE WHEN new_state = 'FAILED' THEN p_failure_code END,
        ended_at = clock_timestamp()
    WHERE weak_holdout_run_id = p_run_id AND state = 'RUNNING';
    IF NOT FOUND THEN RAISE EXCEPTION 'weak holdout run is not RUNNING' USING ERRCODE = '55000'; END IF;
    INSERT INTO strategy_training_weak_holdout.weak_holdout_access_log (
        weak_holdout_run_id, actor_service, access_kind, allowed, reason_code, request_id
    ) VALUES (p_run_id, p_requester_service, 'COMPLETE', true, new_state, p_request_id);
END
$$;

DO $$
DECLARE object_name text;
BEGIN
    FOREACH object_name IN ARRAY ARRAY['weak_holdout_access_log'] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%I_append_only BEFORE UPDATE OR DELETE ON strategy_training_weak_holdout.%I FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()',
            object_name, object_name
        );
    END LOOP;
END
$$;

ALTER TABLE strategy_training_weak_holdout.weak_holdout_runs OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_weak_holdout.weak_holdout_access_log OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_weak_holdout.create_run(uuid, uuid, uuid, uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_weak_holdout.start_run(uuid, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_weak_holdout.complete_run(uuid, char(64), text, uuid, text) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training_weak_holdout FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training_weak_holdout FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training_weak_holdout.create_run(uuid, uuid, uuid, uuid, uuid)
    TO tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION strategy_training_weak_holdout.start_run(uuid, uuid, text),
    strategy_training_weak_holdout.complete_run(uuid, char(64), text, uuid, text)
    TO tb2_training_weak_holdout_executor;
GRANT SELECT ON strategy_training_weak_holdout.weak_holdout_runs,
    strategy_training_weak_holdout.weak_holdout_access_log
    TO tb2_training_weak_holdout_executor;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '034_training_weak_holdout',
    encode(digest('auto_trade_v2_034_training_weak_holdout_v1', 'sha256'), 'hex'),
    'Add declared weak-holdout runs and isolated access audit'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
