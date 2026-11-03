\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.approve_training_config_ready(
    p_config_version_id uuid,
    p_expected_content_hash char(64),
    p_actor_user_id uuid,
    p_reason text,
    p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    current_record strategy_training.training_config_versions%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_ADMIN'
    );
    SELECT * INTO STRICT current_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_config_version_id
    FOR UPDATE;
    IF current_record.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'config state conflict: expected DRAFT, found %',
            current_record.status USING ERRCODE = '40001';
    END IF;
    IF current_record.content_hash <> p_expected_content_hash THEN
        RAISE EXCEPTION 'config content conflict: expected %, found %',
            p_expected_content_hash, current_record.content_hash
            USING ERRCODE = '40001';
    END IF;
    PERFORM strategy_training.transition_training_config(
        p_config_version_id, 'DRAFT', 'READY', p_actor_user_id,
        p_reason, p_request_id
    );
END
$$;

ALTER FUNCTION strategy_training.approve_training_config_ready(
    uuid, char(64), uuid, text, uuid
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.approve_training_config_ready(
    uuid, char(64), uuid, text, uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.approve_training_config_ready(
    uuid, char(64), uuid, text, uuid
) TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '053_training_config_approval_hash',
    encode(digest('auto_trade_v2_053_training_config_approval_hash_v1', 'sha256'), 'hex'),
    'Bind READY approval to the exact server-validated DRAFT content hash'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
