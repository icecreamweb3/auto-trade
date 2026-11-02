\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training_test.test_promotion_evidence (
    promotion_evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_set_id uuid NOT NULL REFERENCES strategy_training_test.test_sets,
    consumption_chain_id uuid NOT NULL,
    evidence_hash char(64) NOT NULL UNIQUE CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    result_manifest_hash char(64) NOT NULL CHECK (result_manifest_hash ~ '^[0-9a-f]{64}$'),
    main_schema_reference_hash char(64) NOT NULL CHECK (main_schema_reference_hash ~ '^[0-9a-f]{64}$'),
    audited_by_user_id uuid NOT NULL REFERENCES core.app_users,
    approved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (main_schema_reference_hash <> evidence_hash)
);

CREATE TABLE strategy_training.training_shadow_export_requests (
    shadow_export_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    model_version_id uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    promotion_evidence_id uuid NOT NULL REFERENCES strategy_training_test.test_promotion_evidence,
    requested_by_user_id uuid NOT NULL REFERENCES core.app_users,
    approved_by_user_id uuid REFERENCES core.app_users,
    destination varchar(16) NOT NULL DEFAULT 'SHADOW' CHECK (destination = 'SHADOW'),
    state varchar(16) NOT NULL DEFAULT 'REQUESTED' CHECK (state IN ('REQUESTED', 'APPROVED', 'REJECTED')),
    decision_reason text,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    decided_at timestamptz,
    request_id uuid NOT NULL UNIQUE,
    CHECK ((state = 'REQUESTED' AND approved_by_user_id IS NULL AND decided_at IS NULL)
        OR (state IN ('APPROVED', 'REJECTED') AND approved_by_user_id IS NOT NULL
            AND decision_reason IS NOT NULL AND btrim(decision_reason) <> '' AND decided_at IS NOT NULL))
);

CREATE TABLE strategy_training.training_promotion_audit_log (
    audit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shadow_export_request_id uuid REFERENCES strategy_training.training_shadow_export_requests,
    promotion_evidence_id uuid REFERENCES strategy_training_test.test_promotion_evidence,
    event_kind varchar(24) NOT NULL CHECK (event_kind IN ('EVIDENCE', 'REQUEST', 'APPROVED', 'REJECTED')),
    allowed boolean NOT NULL,
    reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
    actor_user_id uuid REFERENCES core.app_users,
    actor_service text,
    request_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((actor_user_id IS NOT NULL AND actor_service IS NULL)
        OR (actor_user_id IS NULL AND actor_service IS NOT NULL AND btrim(actor_service) <> ''))
);

CREATE OR REPLACE FUNCTION strategy_training_test.record_test_promotion_evidence(
    p_test_set_id uuid, p_consumption_chain_id uuid, p_evidence_hash char(64),
    p_result_manifest_hash char(64), p_main_schema_reference_hash char(64),
    p_audited_by_user_id uuid, p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_audited_by_user_id, 'TRAINING_TEST_AUDITOR');
    IF NOT EXISTS (SELECT 1 FROM strategy_training_test.test_sets
                   WHERE test_set_id = p_test_set_id AND state = 'CONSUMED'
                     AND consumption_chain_id = p_consumption_chain_id) THEN
        RAISE EXCEPTION 'promotion evidence requires a consumed TEST chain' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training_test.test_promotion_evidence (
        promotion_evidence_id, test_set_id, consumption_chain_id, evidence_hash,
        result_manifest_hash, main_schema_reference_hash, audited_by_user_id
    ) VALUES (new_id, p_test_set_id, p_consumption_chain_id, p_evidence_hash,
              p_result_manifest_hash, p_main_schema_reference_hash, p_audited_by_user_id);
    INSERT INTO strategy_training.training_promotion_audit_log (
        promotion_evidence_id, event_kind, allowed, reason_code,
        actor_user_id, request_id
    ) VALUES (new_id, 'EVIDENCE', true, 'RECORDED', p_audited_by_user_id, p_request_id);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.request_shadow_export(
    p_model_version_id uuid, p_promotion_evidence_id uuid,
    p_requested_by_user_id uuid, p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, strategy_training_test, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_requested_by_user_id, 'TRAINING_ADMIN');
    IF NOT EXISTS (SELECT 1 FROM strategy_training.training_model_versions
                   WHERE model_version_id = p_model_version_id AND state = 'LOCKED')
       OR NOT EXISTS (SELECT 1 FROM strategy_training_test.test_promotion_evidence
                      WHERE promotion_evidence_id = p_promotion_evidence_id) THEN
        RAISE EXCEPTION 'shadow export requires locked model and TEST evidence' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_shadow_export_requests (
        shadow_export_request_id, model_version_id, promotion_evidence_id,
        requested_by_user_id, request_id
    ) VALUES (new_id, p_model_version_id, p_promotion_evidence_id,
              p_requested_by_user_id, p_request_id);
    INSERT INTO strategy_training.training_promotion_audit_log (
        shadow_export_request_id, event_kind, allowed, reason_code,
        actor_user_id, request_id
    ) VALUES (new_id, 'REQUEST', true, 'SHADOW_ONLY', p_requested_by_user_id, p_request_id);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.decide_shadow_export(
    p_shadow_export_request_id uuid, p_approved_by_user_id uuid,
    p_approve boolean, p_reason text, p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE request_record strategy_training.training_shadow_export_requests%ROWTYPE;
    requester_person uuid; approver_person uuid;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_approved_by_user_id, 'TRAINING_ADMIN');
    SELECT * INTO STRICT request_record FROM strategy_training.training_shadow_export_requests
    WHERE shadow_export_request_id = p_shadow_export_request_id FOR UPDATE;
    SELECT natural_person_id INTO STRICT requester_person FROM core.app_user_training_identities
    WHERE user_id = request_record.requested_by_user_id;
    SELECT natural_person_id INTO STRICT approver_person FROM core.app_user_training_identities
    WHERE user_id = p_approved_by_user_id;
    IF request_record.state <> 'REQUESTED' OR requester_person = approver_person
       OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'shadow export requires pending request and independent approver' USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_shadow_export_requests
    SET state = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
        approved_by_user_id = p_approved_by_user_id, decision_reason = p_reason,
        decided_at = clock_timestamp()
    WHERE shadow_export_request_id = p_shadow_export_request_id;
    IF p_approve THEN
        UPDATE strategy_training.training_model_versions
        SET state = 'SHADOW', shadowed_at = clock_timestamp()
        WHERE model_version_id = request_record.model_version_id AND state = 'LOCKED';
    END IF;
    INSERT INTO strategy_training.training_promotion_audit_log (
        shadow_export_request_id, event_kind, allowed, reason_code,
        actor_user_id, request_id
    ) VALUES (p_shadow_export_request_id,
              CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
              p_approve, CASE WHEN p_approve THEN 'SHADOW_EXPORTED' ELSE 'REJECTED' END,
              p_approved_by_user_id, p_request_id);
END
$$;

DO $$
BEGIN
    CREATE TRIGGER trg_test_promotion_evidence_append_only
    BEFORE UPDATE OR DELETE ON strategy_training_test.test_promotion_evidence
    FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

ALTER TABLE strategy_training_test.test_promotion_evidence OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_shadow_export_requests OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_promotion_audit_log OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.record_test_promotion_evidence(uuid, uuid, char(64), char(64), char(64), uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.request_shadow_export(uuid, uuid, uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.decide_shadow_export(uuid, uuid, boolean, text, uuid) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training_test FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training_test FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training_test.record_test_promotion_evidence(uuid, uuid, char(64), char(64), char(64), uuid, uuid)
    TO tb2_training_test_auditor;
GRANT EXECUTE ON FUNCTION strategy_training.request_shadow_export(uuid, uuid, uuid, uuid),
    strategy_training.decide_shadow_export(uuid, uuid, boolean, text, uuid)
    TO tb2_training_orchestrator;
GRANT SELECT ON strategy_training_test.test_promotion_evidence
    TO tb2_training_test_auditor;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '036_training_test_evidence_shadow',
    encode(digest('auto_trade_v2_036_training_test_evidence_shadow_v1', 'sha256'), 'hex'),
    'Add TEST promotion evidence and human-approved SHADOW export'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
