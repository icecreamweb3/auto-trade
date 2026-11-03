\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.create_training_config_draft(
    p_config_type text,
    p_semver text,
    p_schema_version integer,
    p_config_json jsonb,
    p_parent_version_id uuid,
    p_actor_user_id uuid,
    p_reason text,
    p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_RESEARCHER'
    );
    IF p_request_id IS NULL OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'request_id and non-blank reason are required'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_config_json) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'config_json must be a JSON object' USING ERRCODE = '22023';
    END IF;

    INSERT INTO strategy_training.training_config_versions (
        config_version_id, config_type, semver, schema_version, config_json,
        content_hash, parent_version_id, status, created_by_user_id
    ) VALUES (
        new_id, p_config_type, p_semver, p_schema_version, p_config_json,
        encode(public.digest(p_config_json::text, 'sha256'), 'hex'),
        p_parent_version_id, 'DRAFT', p_actor_user_id
    );

    PERFORM strategy_training.write_state_transition(
        'CONFIG', new_id, NULL, 'DRAFT', p_actor_user_id, NULL,
        p_reason, p_request_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.update_training_config_draft(
    p_config_version_id uuid,
    p_expected_content_hash char(64),
    p_semver text,
    p_schema_version integer,
    p_config_json jsonb,
    p_parent_version_id uuid,
    p_actor_user_id uuid,
    p_reason text,
    p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    current_record strategy_training.training_config_versions%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_RESEARCHER'
    );
    IF p_request_id IS NULL OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'request_id and non-blank reason are required'
            USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_config_json) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'config_json must be a JSON object' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO STRICT current_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_config_version_id
    FOR UPDATE;
    IF current_record.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'only DRAFT config can be edited' USING ERRCODE = '55000';
    END IF;
    IF current_record.content_hash <> p_expected_content_hash THEN
        RAISE EXCEPTION 'config content conflict: expected %, found %',
            p_expected_content_hash, current_record.content_hash
            USING ERRCODE = '40001';
    END IF;

    UPDATE strategy_training.training_config_versions
    SET semver = p_semver,
        schema_version = p_schema_version,
        config_json = p_config_json,
        content_hash = encode(public.digest(p_config_json::text, 'sha256'), 'hex'),
        parent_version_id = p_parent_version_id
    WHERE config_version_id = p_config_version_id;

    PERFORM strategy_training.write_state_transition(
        'CONFIG', p_config_version_id, 'DRAFT', 'DRAFT', p_actor_user_id, NULL,
        p_reason, p_request_id
    );
END
$$;

ALTER FUNCTION strategy_training.create_training_config_draft(
    text, text, integer, jsonb, uuid, uuid, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.update_training_config_draft(
    uuid, char(64), text, integer, jsonb, uuid, uuid, text, uuid
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.create_training_config_draft(
    text, text, integer, jsonb, uuid, uuid, text, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.update_training_config_draft(
    uuid, char(64), text, integer, jsonb, uuid, uuid, text, uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.create_training_config_draft(
    text, text, integer, jsonb, uuid, uuid, text, uuid
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.update_training_config_draft(
    uuid, char(64), text, integer, jsonb, uuid, uuid, text, uuid
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.transition_training_config(
    uuid, text, text, uuid, text, uuid
) TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '052_training_config_management',
    encode(digest('auto_trade_v2_052_training_config_management_v1', 'sha256'), 'hex'),
    'Add audited least-privilege DRAFT create and edit procedures for READY config management'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
