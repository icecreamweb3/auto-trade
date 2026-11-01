\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

DO $$
DECLARE
    role_name text;
BEGIN
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
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format(
                'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
                'NOINHERIT NOREPLICATION NOBYPASSRLS',
                role_name
            );
        END IF;
    END LOOP;
END
$$;

CREATE SCHEMA IF NOT EXISTS strategy_training AUTHORIZATION tb2_training_owner;
CREATE SCHEMA IF NOT EXISTS strategy_training_weak_holdout AUTHORIZATION tb2_training_owner;
CREATE SCHEMA IF NOT EXISTS strategy_training_test AUTHORIZATION tb2_training_owner;

ALTER SCHEMA strategy_training OWNER TO tb2_training_owner;
ALTER SCHEMA strategy_training_weak_holdout OWNER TO tb2_training_owner;
ALTER SCHEMA strategy_training_test OWNER TO tb2_training_owner;

REVOKE ALL ON SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON SCHEMA strategy_training_weak_holdout FROM PUBLIC;
REVOKE ALL ON SCHEMA strategy_training_test FROM PUBLIC;

REVOKE ALL ON SCHEMA strategy_training_weak_holdout, strategy_training_test
FROM tb2_collector, tb2_trader, tb2_analysis_ro, tb2_analysis_rw, tb2_backup;

GRANT USAGE ON SCHEMA strategy_training
TO tb2_training_rw,
   tb2_training_orchestrator,
   tb2_training_optimizer,
   tb2_training_evaluator,
   tb2_training_model_b;

GRANT USAGE ON SCHEMA strategy_training_weak_holdout
TO tb2_training_weak_holdout_executor;

GRANT USAGE ON SCHEMA strategy_training_test
TO tb2_training_test_executor,
   tb2_training_test_auditor,
   tb2_training_test_backup;

ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training
REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training_weak_holdout
REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training_test
REVOKE ALL ON TABLES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training
REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training_weak_holdout
REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training_test
REVOKE ALL ON SEQUENCES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training
REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training_weak_holdout
REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE tb2_training_owner IN SCHEMA strategy_training_test
REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE OR REPLACE FUNCTION core.reject_training_append_only_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; % is not allowed', TG_TABLE_NAME, TG_OP
        USING ERRCODE = '55000';
END
$$;

CREATE TABLE IF NOT EXISTS core.app_user_training_identities (
    user_id              uuid PRIMARY KEY REFERENCES core.app_users(user_id),
    natural_person_id    uuid NOT NULL,
    declared_by_user_id  uuid NOT NULL REFERENCES core.app_users(user_id),
    declaration_reason   text NOT NULL,
    request_id           uuid NOT NULL,
    declared_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(declaration_reason) <> '')
);

CREATE INDEX IF NOT EXISTS ix_training_identities_natural_person
ON core.app_user_training_identities (natural_person_id, user_id);

CREATE TABLE IF NOT EXISTS core.app_user_training_roles (
    grant_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              uuid NOT NULL REFERENCES core.app_user_training_identities(user_id),
    training_role        varchar(32) NOT NULL,
    granted_by_user_id   uuid NOT NULL REFERENCES core.app_users(user_id),
    grant_reason         text NOT NULL,
    request_id           uuid NOT NULL,
    valid_from           timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at           timestamptz NOT NULL,
    granted_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (training_role IN (
        'TRAINING_RESEARCHER', 'TRAINING_ADMIN', 'TRAINING_TEST_AUDITOR'
    )),
    CHECK (btrim(grant_reason) <> ''),
    CHECK (expires_at > valid_from)
);

CREATE INDEX IF NOT EXISTS ix_app_user_training_roles_active
ON core.app_user_training_roles (user_id, training_role, expires_at DESC);

CREATE TABLE IF NOT EXISTS core.app_user_training_role_revocations (
    revocation_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grant_id             uuid NOT NULL UNIQUE
                         REFERENCES core.app_user_training_roles(grant_id),
    revoked_by_user_id   uuid NOT NULL REFERENCES core.app_users(user_id),
    revocation_reason    text NOT NULL,
    request_id           uuid NOT NULL,
    revoked_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(revocation_reason) <> '')
);

CREATE TABLE IF NOT EXISTS core.training_role_audit_log (
    audit_event_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type           varchar(32) NOT NULL
                         CHECK (event_type IN ('IDENTITY_DECLARED', 'ROLE_GRANTED', 'ROLE_REVOKED')),
    user_id              uuid NOT NULL REFERENCES core.app_users(user_id),
    natural_person_id    uuid NOT NULL,
    training_role        varchar(32),
    grant_id             uuid,
    actor_user_id        uuid NOT NULL REFERENCES core.app_users(user_id),
    request_id           uuid NOT NULL,
    reason               text NOT NULL,
    occurred_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(reason) <> '')
);

CREATE INDEX IF NOT EXISTS ix_training_role_audit_user_time
ON core.training_role_audit_log (user_id, occurred_at DESC);

CREATE OR REPLACE FUNCTION core.audit_training_identity_declaration()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO core.training_role_audit_log (
        event_type, user_id, natural_person_id, actor_user_id, request_id, reason
    ) VALUES (
        'IDENTITY_DECLARED', NEW.user_id, NEW.natural_person_id,
        NEW.declared_by_user_id, NEW.request_id, NEW.declaration_reason
    );
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION core.validate_and_audit_training_role_grant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    grantee_natural_person_id uuid;
    conflicting_role text;
BEGIN
    SELECT natural_person_id
    INTO STRICT grantee_natural_person_id
    FROM core.app_user_training_identities
    WHERE user_id = NEW.user_id;

    IF NEW.training_role = 'TRAINING_ADMIN' THEN
        conflicting_role := 'TRAINING_TEST_AUDITOR';
    ELSIF NEW.training_role = 'TRAINING_TEST_AUDITOR' THEN
        conflicting_role := 'TRAINING_ADMIN';
    END IF;

    IF conflicting_role IS NOT NULL AND EXISTS (
        SELECT 1
        FROM core.app_user_training_roles existing_grant
        JOIN core.app_user_training_identities existing_identity
          ON existing_identity.user_id = existing_grant.user_id
        LEFT JOIN core.app_user_training_role_revocations revocation
          ON revocation.grant_id = existing_grant.grant_id
        WHERE existing_identity.natural_person_id = grantee_natural_person_id
          AND existing_grant.training_role = conflicting_role
          AND existing_grant.valid_from <= clock_timestamp()
          AND existing_grant.expires_at > clock_timestamp()
          AND revocation.grant_id IS NULL
    ) THEN
        RAISE EXCEPTION 'natural person cannot hold both TRAINING_ADMIN and TRAINING_TEST_AUDITOR'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO core.training_role_audit_log (
        event_type, user_id, natural_person_id, training_role, grant_id,
        actor_user_id, request_id, reason
    ) VALUES (
        'ROLE_GRANTED', NEW.user_id, grantee_natural_person_id, NEW.training_role,
        NEW.grant_id, NEW.granted_by_user_id, NEW.request_id, NEW.grant_reason
    );
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION core.audit_training_role_revocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    revoked_grant core.app_user_training_roles%ROWTYPE;
    grantee_natural_person_id uuid;
BEGIN
    SELECT * INTO STRICT revoked_grant
    FROM core.app_user_training_roles
    WHERE grant_id = NEW.grant_id;

    SELECT natural_person_id INTO STRICT grantee_natural_person_id
    FROM core.app_user_training_identities
    WHERE user_id = revoked_grant.user_id;

    INSERT INTO core.training_role_audit_log (
        event_type, user_id, natural_person_id, training_role, grant_id,
        actor_user_id, request_id, reason
    ) VALUES (
        'ROLE_REVOKED', revoked_grant.user_id, grantee_natural_person_id,
        revoked_grant.training_role, revoked_grant.grant_id,
        NEW.revoked_by_user_id, NEW.request_id, NEW.revocation_reason
    );
    RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION core.reject_training_append_only_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION core.audit_training_identity_declaration() FROM PUBLIC;
REVOKE ALL ON FUNCTION core.validate_and_audit_training_role_grant() FROM PUBLIC;
REVOKE ALL ON FUNCTION core.audit_training_role_revocation() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_training_identity_audit ON core.app_user_training_identities;
CREATE TRIGGER trg_training_identity_audit
AFTER INSERT ON core.app_user_training_identities
FOR EACH ROW EXECUTE FUNCTION core.audit_training_identity_declaration();

DROP TRIGGER IF EXISTS trg_training_role_grant_guard ON core.app_user_training_roles;
CREATE TRIGGER trg_training_role_grant_guard
BEFORE INSERT ON core.app_user_training_roles
FOR EACH ROW EXECUTE FUNCTION core.validate_and_audit_training_role_grant();

DROP TRIGGER IF EXISTS trg_training_role_revocation_audit
ON core.app_user_training_role_revocations;
CREATE TRIGGER trg_training_role_revocation_audit
AFTER INSERT ON core.app_user_training_role_revocations
FOR EACH ROW EXECUTE FUNCTION core.audit_training_role_revocation();

DO $$
DECLARE
    table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'app_user_training_identities',
        'app_user_training_roles',
        'app_user_training_role_revocations',
        'training_role_audit_log'
    ]
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_append_only ON core.%I', table_name, table_name);
        EXECUTE format(
            'CREATE TRIGGER trg_%s_append_only BEFORE UPDATE OR DELETE ON core.%I '
            'FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()',
            table_name,
            table_name
        );
    END LOOP;
END
$$;

REVOKE ALL ON core.app_user_training_identities,
    core.app_user_training_roles,
    core.app_user_training_role_revocations,
    core.training_role_audit_log
FROM PUBLIC, tb2_collector, tb2_trader, tb2_analysis_ro, tb2_analysis_rw, tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '019_training_schemas_roles_audit',
    encode(digest('auto_trade_v2_019_training_schemas_roles_audit_v1', 'sha256'), 'hex'),
    'Add isolated training schemas, NOLOGIN roles and append-only application training RBAC audit'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
