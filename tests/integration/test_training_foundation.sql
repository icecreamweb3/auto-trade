\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE
    role_name text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.schema_migrations
        WHERE version = '019_training_schemas_roles_audit' AND success
    ) THEN
        RAISE EXCEPTION 'migration 019 was not recorded successfully';
    END IF;

    IF (
        SELECT count(*) FROM pg_namespace
        WHERE nspname IN (
            'strategy_training', 'strategy_training_weak_holdout', 'strategy_training_test'
        )
    ) <> 3 THEN
        RAISE EXCEPTION 'training schemas are incomplete';
    END IF;

    FOREACH role_name IN ARRAY ARRAY[
        'tb2_training_owner',
        'tb2_training_rw',
        'tb2_training_orchestrator',
        'tb2_training_optimizer',
        'tb2_training_evaluator',
        'tb2_training_model_b',
        'tb2_training_test_executor',
        'tb2_training_weak_holdout_executor',
        'tb2_training_test_auditor',
        'tb2_training_test_backup'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_roles
            WHERE rolname = role_name
              AND NOT rolcanlogin
              AND NOT rolsuper
              AND NOT rolcreaterole
              AND NOT rolcreatedb
              AND NOT rolreplication
              AND NOT rolbypassrls
        ) THEN
            RAISE EXCEPTION 'role % is missing or over-privileged', role_name;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM pg_namespace namespace
        CROSS JOIN LATERAL aclexplode(namespace.nspacl) acl
        WHERE namespace.nspname = 'strategy_training_test'
          AND acl.grantee = 0
          AND acl.privilege_type = 'USAGE'
    )
       OR has_schema_privilege('tb2_analysis_ro', 'strategy_training_test', 'USAGE')
       OR has_schema_privilege('tb2_backup', 'strategy_training_test', 'USAGE')
       OR has_schema_privilege(
           'tb2_training_rw', 'strategy_training_weak_holdout', 'USAGE'
       ) THEN
        RAISE EXCEPTION 'isolated schema leaked to a generic or TRAIN role';
    END IF;

    IF NOT has_schema_privilege(
        'tb2_training_test_executor', 'strategy_training_test', 'USAGE'
    ) OR NOT has_schema_privilege(
        'tb2_training_weak_holdout_executor',
        'strategy_training_weak_holdout',
        'USAGE'
    ) THEN
        RAISE EXCEPTION 'dedicated executor is missing schema usage';
    END IF;
END
$$;

INSERT INTO core.app_users (user_id, email, password_hash, username, role)
VALUES
    ('10000000-0000-0000-0000-000000000001', 'grantor@example.test', 'not-a-real-hash', 'grantor', 'ADMIN'),
    ('10000000-0000-0000-0000-000000000002', 'admin@example.test', 'not-a-real-hash', 'training-admin', 'NORMAL'),
    ('10000000-0000-0000-0000-000000000003', 'auditor@example.test', 'not-a-real-hash', 'training-auditor', 'NORMAL');

INSERT INTO core.app_user_training_identities (
    user_id, natural_person_id, declared_by_user_id, declaration_reason, request_id
) VALUES
    (
        '10000000-0000-0000-0000-000000000002',
        '20000000-0000-0000-0000-000000000001',
        '10000000-0000-0000-0000-000000000001',
        'integration test identity',
        '30000000-0000-0000-0000-000000000001'
    ),
    (
        '10000000-0000-0000-0000-000000000003',
        '20000000-0000-0000-0000-000000000001',
        '10000000-0000-0000-0000-000000000001',
        'same natural person for conflict test',
        '30000000-0000-0000-0000-000000000002'
    );

INSERT INTO core.app_user_training_roles (
    grant_id, user_id, training_role, granted_by_user_id, grant_reason,
    request_id, valid_from, expires_at
) VALUES (
    '40000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    'TRAINING_ADMIN',
    '10000000-0000-0000-0000-000000000001',
    'integration test grant',
    '30000000-0000-0000-0000-000000000003',
    clock_timestamp() - interval '1 minute',
    clock_timestamp() + interval '1 day'
);

DO $$
BEGIN
    BEGIN
        INSERT INTO core.app_user_training_roles (
            user_id, training_role, granted_by_user_id, grant_reason,
            request_id, valid_from, expires_at
        ) VALUES (
            '10000000-0000-0000-0000-000000000003',
            'TRAINING_TEST_AUDITOR',
            '10000000-0000-0000-0000-000000000001',
            'must conflict',
            '30000000-0000-0000-0000-000000000004',
            clock_timestamp() - interval '1 minute',
            clock_timestamp() + interval '1 day'
        );
        RAISE EXCEPTION 'role separation trigger accepted a conflicting grant';
    EXCEPTION
        WHEN check_violation THEN
            NULL;
    END;
END
$$;

DO $$
BEGIN
    BEGIN
        UPDATE core.app_user_training_roles
        SET grant_reason = 'illegal rewrite'
        WHERE grant_id = '40000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'append-only trigger accepted an update';
    EXCEPTION
        WHEN object_not_in_prerequisite_state THEN
            NULL;
    END;
END
$$;

DO $$
DECLARE
    identity_events integer;
    grant_events integer;
BEGIN
    SELECT count(*) FILTER (WHERE event_type = 'IDENTITY_DECLARED'),
           count(*) FILTER (WHERE event_type = 'ROLE_GRANTED')
    INTO identity_events, grant_events
    FROM core.training_role_audit_log;

    IF identity_events <> 2 OR grant_events <> 1 THEN
        RAISE EXCEPTION 'unexpected RBAC audit counts: identities %, grants %',
            identity_events, grant_events;
    END IF;
END
$$;

ROLLBACK;
