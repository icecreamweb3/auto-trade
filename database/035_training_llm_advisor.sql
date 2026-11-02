\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_training_llm_gateway') THEN
        CREATE ROLE tb2_training_llm_gateway NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
END
$$;

CREATE TABLE strategy_training.training_model_advice_batches (
    advice_batch_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    train_summary_hash char(64) NOT NULL CHECK (train_summary_hash ~ '^[0-9a-f]{64}$'),
    provider text NOT NULL CHECK (btrim(provider) <> ''),
    provider_request_id text,
    request_payload jsonb NOT NULL CHECK (request_payload->>'partition' = 'TRAIN'),
    response_payload jsonb,
    validation_status varchar(16) NOT NULL CHECK (validation_status IN ('PENDING', 'VALID', 'REJECTED', 'UNAVAILABLE')),
    rejection_codes jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(rejection_codes) = 'array'),
    created_by_service text NOT NULL CHECK (btrim(created_by_service) <> ''),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE strategy_training.training_model_advice_batch_iterations (
    advice_batch_id uuid NOT NULL REFERENCES strategy_training.training_model_advice_batches,
    iteration_id uuid NOT NULL REFERENCES strategy_training.training_iterations,
    input_summary_hash char(64) NOT NULL CHECK (input_summary_hash ~ '^[0-9a-f]{64}$'),
    output_validation_status varchar(16) NOT NULL CHECK (output_validation_status IN ('PENDING', 'VALID', 'REJECTED', 'UNAVAILABLE')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (advice_batch_id, iteration_id)
);

CREATE TABLE strategy_training.training_search_space_requests (
    search_space_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source varchar(16) NOT NULL CHECK (source IN ('LLM', 'HUMAN', 'OPTIMIZER')),
    requested_by_user_id uuid REFERENCES core.app_users,
    requested_by_service text,
    base_search_space_version text NOT NULL CHECK (btrim(base_search_space_version) <> ''),
    proposed_changes jsonb NOT NULL CHECK (jsonb_typeof(proposed_changes) = 'object'),
    state varchar(16) NOT NULL DEFAULT 'REQUESTED' CHECK (state IN ('REQUESTED', 'APPROVED', 'REJECTED')),
    approved_by_user_id uuid REFERENCES core.app_users,
    decision_reason text,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    decided_at timestamptz,
    request_id uuid NOT NULL UNIQUE,
    CHECK ((requested_by_user_id IS NOT NULL AND requested_by_service IS NULL)
        OR (requested_by_user_id IS NULL AND requested_by_service IS NOT NULL)),
    CHECK ((state = 'REQUESTED' AND approved_by_user_id IS NULL AND decided_at IS NULL)
        OR (state IN ('APPROVED', 'REJECTED') AND approved_by_user_id IS NOT NULL
            AND decision_reason IS NOT NULL AND btrim(decision_reason) <> '' AND decided_at IS NOT NULL))
);

CREATE TABLE strategy_training.training_llm_audit_log (
    audit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    advice_batch_id uuid REFERENCES strategy_training.training_model_advice_batches,
    search_space_request_id uuid REFERENCES strategy_training.training_search_space_requests,
    event_kind varchar(24) NOT NULL CHECK (event_kind IN ('REQUEST', 'RESPONSE', 'REJECTED', 'APPROVED')),
    endpoint text,
    allowed boolean NOT NULL,
    reason_code text NOT NULL CHECK (btrim(reason_code) <> ''),
    request_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION strategy_training.record_model_advice_batch(
    p_train_summary_hash char(64), p_provider text, p_provider_request_id text,
    p_request_payload jsonb, p_response_payload jsonb, p_validation_status text,
    p_rejection_codes jsonb, p_created_by_service text, p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    IF p_request_payload->>'partition' <> 'TRAIN' THEN
        RAISE EXCEPTION 'LLM advice payload must be TRAIN-only' USING ERRCODE = '23514';
    END IF;
    IF p_validation_status NOT IN ('PENDING', 'VALID', 'REJECTED', 'UNAVAILABLE') THEN
        RAISE EXCEPTION 'invalid LLM validation status' USING ERRCODE = '22023';
    END IF;
    INSERT INTO strategy_training.training_model_advice_batches (
        advice_batch_id, train_summary_hash, provider, provider_request_id,
        request_payload, response_payload, validation_status, rejection_codes,
        created_by_service
    ) VALUES (new_id, p_train_summary_hash, p_provider, p_provider_request_id,
              p_request_payload, p_response_payload, p_validation_status,
              p_rejection_codes, p_created_by_service);
    INSERT INTO strategy_training.training_llm_audit_log (
        advice_batch_id, event_kind, endpoint, allowed, reason_code, request_id
    ) VALUES (new_id, 'RESPONSE', NULL, true, p_validation_status, p_request_id);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.decide_search_space_request(
    p_request_id uuid, p_approved_by_user_id uuid, p_approve boolean, p_reason text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE request_record strategy_training.training_search_space_requests%ROWTYPE;
    requester_person uuid; approver_person uuid;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_approved_by_user_id, 'TRAINING_ADMIN');
    SELECT * INTO STRICT request_record
    FROM strategy_training.training_search_space_requests
    WHERE search_space_request_id = p_request_id FOR UPDATE;
    IF request_record.state <> 'REQUESTED' OR p_reason IS NULL OR btrim(p_reason) = ''
       OR request_record.requested_by_user_id IS NULL THEN
        RAISE EXCEPTION 'search-space request is not human-decidable' USING ERRCODE = '23514';
    END IF;
    SELECT natural_person_id INTO STRICT requester_person
    FROM core.app_user_training_identities WHERE user_id = request_record.requested_by_user_id;
    SELECT natural_person_id INTO STRICT approver_person
    FROM core.app_user_training_identities WHERE user_id = p_approved_by_user_id;
    IF requester_person = approver_person THEN
        RAISE EXCEPTION 'search-space approval requires a different natural person' USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_search_space_requests
    SET state = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
        approved_by_user_id = p_approved_by_user_id,
        decision_reason = p_reason, decided_at = clock_timestamp()
    WHERE search_space_request_id = p_request_id;
    INSERT INTO strategy_training.training_llm_audit_log (
        search_space_request_id, event_kind, allowed, reason_code, request_id
    ) VALUES (p_request_id, 'APPROVED', p_approve, CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END, p_request_id);
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_search_space_request(
    p_source text, p_requested_by_user_id uuid, p_requested_by_service text,
    p_base_search_space_version text, p_proposed_changes jsonb, p_request_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    IF p_source NOT IN ('LLM', 'HUMAN', 'OPTIMIZER')
       OR (p_source = 'LLM' AND (p_requested_by_service IS NULL OR p_requested_by_user_id IS NOT NULL))
       OR (p_source <> 'LLM' AND (p_requested_by_user_id IS NULL OR p_requested_by_service IS NOT NULL)) THEN
        RAISE EXCEPTION 'search-space requester identity is invalid' USING ERRCODE = '22023';
    END IF;
    IF p_source <> 'LLM' THEN
        PERFORM strategy_training.assert_active_training_role(p_requested_by_user_id, 'TRAINING_ADMIN');
    END IF;
    INSERT INTO strategy_training.training_search_space_requests (
        search_space_request_id, source, requested_by_user_id, requested_by_service,
        base_search_space_version, proposed_changes, request_id
    ) VALUES (new_id, p_source, p_requested_by_user_id, p_requested_by_service,
              p_base_search_space_version, p_proposed_changes, p_request_id);
    INSERT INTO strategy_training.training_llm_audit_log (
        search_space_request_id, event_kind, allowed, reason_code, request_id
    ) VALUES (new_id, 'REQUEST', true, 'REQUESTED', p_request_id);
    RETURN new_id;
END
$$;

DO $$
DECLARE object_name text;
BEGIN
    FOREACH object_name IN ARRAY ARRAY[
        'training_model_advice_batches', 'training_model_advice_batch_iterations',
        'training_search_space_requests', 'training_llm_audit_log'
    ] LOOP
        EXECUTE format(
            'ALTER TABLE strategy_training.%I OWNER TO tb2_training_owner', object_name
        );
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.record_model_advice_batch(char(64), text, text, jsonb, jsonb, text, jsonb, text, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.decide_search_space_request(uuid, uuid, boolean, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_search_space_request(text, uuid, text, text, jsonb, uuid) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.record_model_advice_batch(char(64), text, text, jsonb, jsonb, text, jsonb, text, uuid)
    TO tb2_training_llm_gateway;
GRANT EXECUTE ON FUNCTION strategy_training.decide_search_space_request(uuid, uuid, boolean, text)
    TO tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION strategy_training.create_search_space_request(text, uuid, text, text, jsonb, uuid)
    TO tb2_training_orchestrator, tb2_training_llm_gateway;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '035_training_llm_advisor',
    encode(digest('auto_trade_v2_035_training_llm_advisor_v1', 'sha256'), 'hex'),
    'Add TRAIN-only LLM advice audit and human-approved search-space requests'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
