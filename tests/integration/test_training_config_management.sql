\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '053_training_config_approval_hash' AND success
    ) THEN
        RAISE EXCEPTION 'migration 053 was not recorded successfully';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES
    ('52000000-0000-0000-0000-000000000001', 'config-researcher@example.test',
     'not-a-real-hash', 'config-researcher', 'ADVANCED'),
    ('52000000-0000-0000-0000-000000000002', 'config-approver@example.test',
     'not-a-real-hash', 'config-approver', 'ADMIN');

INSERT INTO core.app_user_training_identities (
    user_id, natural_person_id, declared_by_user_id, declaration_reason, request_id
) VALUES
    ('52000000-0000-0000-0000-000000000001',
     '52000000-0000-0000-0000-000000000011',
     '52000000-0000-0000-0000-000000000002', 'integration researcher',
     '52000000-0000-0000-0000-000000000021'),
    ('52000000-0000-0000-0000-000000000002',
     '52000000-0000-0000-0000-000000000012',
     '52000000-0000-0000-0000-000000000002', 'integration approver',
     '52000000-0000-0000-0000-000000000022');

INSERT INTO core.app_user_training_roles (
    grant_id, user_id, training_role, granted_by_user_id, grant_reason,
    request_id, valid_from, expires_at
) VALUES
    ('52000000-0000-0000-0000-000000000031',
     '52000000-0000-0000-0000-000000000001', 'TRAINING_RESEARCHER',
     '52000000-0000-0000-0000-000000000002', 'integration test',
     '52000000-0000-0000-0000-000000000041', clock_timestamp() - interval '1 hour',
     clock_timestamp() + interval '1 hour'),
    ('52000000-0000-0000-0000-000000000032',
     '52000000-0000-0000-0000-000000000002', 'TRAINING_ADMIN',
     '52000000-0000-0000-0000-000000000002', 'integration test',
     '52000000-0000-0000-0000-000000000042', clock_timestamp() - interval '1 hour',
     clock_timestamp() + interval '1 hour');

SELECT strategy_training.create_training_config_draft(
    'FEE_MODEL', '52.0.0', 1, '{"maker_rate":0.0002,"taker_rate":0.0005}'::jsonb,
    NULL, '52000000-0000-0000-0000-000000000001', 'create integration draft',
    '52000000-0000-0000-0000-000000000051'
);

DO $$
DECLARE
    config_id uuid;
    old_hash char(64);
BEGIN
    SELECT config_version_id, content_hash INTO STRICT config_id, old_hash
    FROM strategy_training.training_config_versions
    WHERE config_type = 'FEE_MODEL' AND semver = '52.0.0';

    PERFORM strategy_training.update_training_config_draft(
        config_id, old_hash, '52.0.1', 1,
        '{"maker_rate":0.0001,"taker_rate":0.0004}'::jsonb, NULL,
        '52000000-0000-0000-0000-000000000001', 'edit integration draft',
        '52000000-0000-0000-0000-000000000052'
    );

    BEGIN
        PERFORM strategy_training.approve_training_config_ready(
            config_id, repeat('0', 64)::char(64),
            '52000000-0000-0000-0000-000000000002', 'stale approval attempt',
            '52000000-0000-0000-0000-000000000055'
        );
        RAISE EXCEPTION 'stale content hash approval was accepted';
    EXCEPTION WHEN serialization_failure THEN NULL;
    END;

    PERFORM strategy_training.approve_training_config_ready(
        config_id,
        (SELECT content_hash FROM strategy_training.training_config_versions
         WHERE config_version_id = config_id),
        '52000000-0000-0000-0000-000000000002', 'approve integration config',
        '52000000-0000-0000-0000-000000000053'
    );

    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_config_versions
        WHERE config_version_id = config_id AND status = 'READY'
          AND semver = '52.0.1'
          AND ready_by_user_id = '52000000-0000-0000-0000-000000000002'
    ) THEN
        RAISE EXCEPTION 'config was not approved with the expected actor';
    END IF;
    IF (SELECT count(*) FROM strategy_training.training_state_transition_log
        WHERE object_type = 'CONFIG' AND object_id = config_id) <> 3 THEN
        RAISE EXCEPTION 'create/edit/approve audit transitions were not all recorded';
    END IF;

    BEGIN
        PERFORM strategy_training.update_training_config_draft(
            config_id,
            (SELECT content_hash FROM strategy_training.training_config_versions
             WHERE config_version_id = config_id),
            '52.0.2', 1, '{"maker_rate":0,"taker_rate":0}'::jsonb, NULL,
            '52000000-0000-0000-0000-000000000001', 'illegal READY edit',
            '52000000-0000-0000-0000-000000000054'
        );
        RAISE EXCEPTION 'READY config edit was accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END
$$;

ROLLBACK;
