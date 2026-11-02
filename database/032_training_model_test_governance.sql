\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_model_versions (
    model_version_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    model_type             varchar(16) NOT NULL CHECK (model_type IN ('MODEL_A', 'MODEL_B', 'PORTFOLIO')),
    source_iteration_id    uuid NOT NULL UNIQUE REFERENCES strategy_training.training_iterations,
    dataset_version_id     uuid NOT NULL REFERENCES strategy_training.training_dataset_versions,
    content_hash           char(64) NOT NULL,
    state                  varchar(16) NOT NULL DEFAULT 'DRAFT'
                           CHECK (state IN ('DRAFT', 'LOCKED', 'SHADOW', 'RETIRED')),
    created_by_user_id     uuid NOT NULL REFERENCES core.app_users,
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    locked_at              timestamptz,
    shadowed_at            timestamptz,
    retired_at             timestamptz,
    CHECK (content_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((state = 'DRAFT' AND locked_at IS NULL AND shadowed_at IS NULL AND retired_at IS NULL)
           OR (state = 'LOCKED' AND locked_at IS NOT NULL AND shadowed_at IS NULL AND retired_at IS NULL)
           OR (state = 'SHADOW' AND locked_at IS NOT NULL AND shadowed_at IS NOT NULL AND retired_at IS NULL)
           OR (state = 'RETIRED' AND retired_at IS NOT NULL)),
    UNIQUE (model_type, content_hash)
);

CREATE TABLE strategy_training.training_model_lineage_edges (
    child_model_version_id  uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    parent_model_version_id uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    relationship            varchar(24) NOT NULL CHECK (relationship IN (
                                'DERIVED_FROM', 'USES_MODEL_A', 'USES_MODEL_B', 'USES_PORTFOLIO'
                            )),
    edge_hash               char(64) NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (child_model_version_id, parent_model_version_id, relationship),
    CHECK (child_model_version_id <> parent_model_version_id),
    CHECK (edge_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_model_lock_approvals (
    model_lock_approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    model_version_id       uuid NOT NULL UNIQUE REFERENCES strategy_training.training_model_versions,
    requested_by_user_id   uuid NOT NULL REFERENCES core.app_users,
    approved_by_user_id    uuid REFERENCES core.app_users,
    evidence_hash          char(64) NOT NULL,
    state                  varchar(16) NOT NULL DEFAULT 'REQUESTED'
                           CHECK (state IN ('REQUESTED', 'APPROVED', 'REJECTED')),
    decision_reason        text,
    requested_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    decided_at             timestamptz,
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((state = 'REQUESTED' AND approved_by_user_id IS NULL
                                  AND decision_reason IS NULL AND decided_at IS NULL)
           OR (state IN ('APPROVED', 'REJECTED') AND approved_by_user_id IS NOT NULL
                                AND decision_reason IS NOT NULL
                                AND btrim(decision_reason) <> '' AND decided_at IS NOT NULL))
);

CREATE OR REPLACE FUNCTION strategy_training.create_training_model_version(
    p_model_type text, p_source_iteration_id uuid, p_content_hash char(64),
    p_created_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid(); source_record strategy_training.training_iterations%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_created_by_user_id, 'TRAINING_ADMIN');
    SELECT * INTO STRICT source_record FROM strategy_training.training_iterations
    WHERE iteration_id = p_source_iteration_id;
    IF source_record.state <> 'SUCCEEDED' OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iteration_evidence_l0 evidence
        WHERE evidence.iteration_id = p_source_iteration_id
          AND evidence.partition = 'TRAIN' AND evidence.terminal_state = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'model draft requires SUCCEEDED TRAIN L0 evidence'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_model_versions (
        model_version_id, model_type, source_iteration_id, dataset_version_id,
        content_hash, created_by_user_id
    )
    SELECT new_id, p_model_type, p_source_iteration_id, experiment.dataset_version_id,
           p_content_hash, p_created_by_user_id
    FROM strategy_training.training_experiments experiment
    WHERE experiment.experiment_id = source_record.experiment_id;
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.add_training_model_lineage(
    p_child_model_version_id uuid, p_parent_model_version_id uuid, p_relationship text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
BEGIN
    IF EXISTS (
        WITH RECURSIVE ancestors(model_version_id) AS (
            SELECT p_parent_model_version_id
            UNION ALL
            SELECT edge.parent_model_version_id
            FROM strategy_training.training_model_lineage_edges edge
            JOIN ancestors ON edge.child_model_version_id = ancestors.model_version_id
        ) SELECT 1 FROM ancestors WHERE model_version_id = p_child_model_version_id
    ) THEN
        RAISE EXCEPTION 'model lineage cycle is not allowed' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_model_lineage_edges (
        child_model_version_id, parent_model_version_id, relationship, edge_hash
    ) VALUES (
        p_child_model_version_id, p_parent_model_version_id, p_relationship,
        encode(public.digest(concat_ws('|', p_child_model_version_id::text,
            p_parent_model_version_id::text, p_relationship), 'sha256'), 'hex')
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.request_training_model_lock(
    p_model_version_id uuid, p_requested_by_user_id uuid, p_evidence_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid(); model_record strategy_training.training_model_versions%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_requested_by_user_id, 'TRAINING_ADMIN');
    SELECT * INTO STRICT model_record FROM strategy_training.training_model_versions
    WHERE model_version_id = p_model_version_id FOR UPDATE;
    IF model_record.state <> 'DRAFT'
       OR EXISTS (SELECT 1 FROM strategy_training.training_iteration_summaries_l1
                  WHERE iteration_id = model_record.source_iteration_id
                    AND consistency_status = 'MISMATCH')
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_iteration_summaries_l1
                      WHERE iteration_id = model_record.source_iteration_id
                        AND consistency_status = 'MATCH')
       OR EXISTS (SELECT 1 FROM strategy_training.training_archive_manifests
                  WHERE iteration_id = model_record.source_iteration_id AND state <> 'VERIFIED') THEN
        RAISE EXCEPTION 'model lock evidence is incomplete or inconsistent'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_model_lock_approvals (
        model_lock_approval_id, model_version_id, requested_by_user_id, evidence_hash
    ) VALUES (new_id, p_model_version_id, p_requested_by_user_id, p_evidence_hash);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.decide_training_model_lock(
    p_model_lock_approval_id uuid, p_approved_by_user_id uuid,
    p_approve boolean, p_reason text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE approval strategy_training.training_model_lock_approvals%ROWTYPE;
    requester_person uuid; approver_person uuid;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_approved_by_user_id, 'TRAINING_ADMIN');
    SELECT * INTO STRICT approval FROM strategy_training.training_model_lock_approvals
    WHERE model_lock_approval_id = p_model_lock_approval_id FOR UPDATE;
    IF approval.state <> 'REQUESTED' OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'model lock approval is not decidable' USING ERRCODE = '23514';
    END IF;
    SELECT natural_person_id INTO STRICT requester_person
    FROM core.app_user_training_identities WHERE user_id = approval.requested_by_user_id;
    SELECT natural_person_id INTO STRICT approver_person
    FROM core.app_user_training_identities WHERE user_id = p_approved_by_user_id;
    IF requester_person = approver_person THEN
        RAISE EXCEPTION 'model lock requester and approver must be different people'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_model_lock_approvals
    SET state = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
        approved_by_user_id = p_approved_by_user_id,
        decision_reason = p_reason, decided_at = clock_timestamp()
    WHERE model_lock_approval_id = p_model_lock_approval_id;
    IF p_approve THEN
        UPDATE strategy_training.training_model_versions
        SET state = 'LOCKED', locked_at = clock_timestamp()
        WHERE model_version_id = approval.model_version_id AND state = 'DRAFT';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.compute_test_scope_hash(
    p_partition_start_at timestamptz, p_partition_end_at timestamptz,
    p_ticker_pool_rule_version_id uuid, p_controlled_purpose text
)
RETURNS char(64)
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT encode(public.digest(concat_ws('|',
        to_char(p_partition_start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
        to_char(p_partition_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
        p_ticker_pool_rule_version_id::text, p_controlled_purpose), 'sha256'), 'hex')::char(64)
$$;

CREATE TABLE strategy_training_test.test_logical_scopes (
    test_logical_scope_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    partition_start_at timestamptz NOT NULL,
    partition_end_at timestamptz NOT NULL,
    ticker_pool_rule_version_id uuid NOT NULL,
    controlled_purpose varchar(32) NOT NULL CHECK (controlled_purpose IN ('FORMAL_MODEL_TEST')),
    scope_hash char(64) NOT NULL UNIQUE,
    created_by_user_id uuid NOT NULL REFERENCES core.app_users,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (partition_start_at < partition_end_at),
    CHECK (scope_hash = strategy_training_test.compute_test_scope_hash(
        partition_start_at, partition_end_at, ticker_pool_rule_version_id, controlled_purpose))
);

CREATE TABLE strategy_training_test.test_dataset_versions (
    test_dataset_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_logical_scope_id uuid NOT NULL REFERENCES strategy_training_test.test_logical_scopes,
    content_fingerprint char(64) NOT NULL,
    source_revision_watermark jsonb NOT NULL,
    supersedes_test_dataset_version_id uuid UNIQUE
        REFERENCES strategy_training_test.test_dataset_versions,
    state varchar(16) NOT NULL DEFAULT 'DRAFT' CHECK (state IN ('DRAFT', 'FROZEN', 'SUPERSEDED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    frozen_at timestamptz,
    CHECK (content_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(source_revision_watermark) = 'object'),
    CHECK ((state = 'DRAFT' AND frozen_at IS NULL) OR (state <> 'DRAFT' AND frozen_at IS NOT NULL)),
    UNIQUE (test_logical_scope_id, content_fingerprint)
);

CREATE TABLE strategy_training_test.test_sets (
    test_set_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_logical_scope_id uuid NOT NULL REFERENCES strategy_training_test.test_logical_scopes,
    test_dataset_version_id uuid NOT NULL UNIQUE REFERENCES strategy_training_test.test_dataset_versions,
    model_a_version_id uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    model_b_version_id uuid REFERENCES strategy_training.training_model_versions,
    visibility_cutoff_at timestamptz NOT NULL,
    pre_seal_exposure_status varchar(16) NOT NULL CHECK (pre_seal_exposure_status IN ('NONE', 'DECLARED', 'UNKNOWN')),
    state varchar(16) NOT NULL DEFAULT 'DRAFT' CHECK (state IN ('DRAFT', 'SEALED', 'CONSUMED', 'COMPROMISED')),
    consumption_chain_id uuid,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    sealed_at timestamptz,
    consumed_at timestamptz,
    compromised_at timestamptz,
    CHECK ((state = 'DRAFT' AND sealed_at IS NULL AND consumed_at IS NULL AND compromised_at IS NULL)
           OR (state = 'SEALED' AND sealed_at IS NOT NULL AND consumed_at IS NULL AND compromised_at IS NULL)
           OR (state = 'CONSUMED' AND sealed_at IS NOT NULL AND consumed_at IS NOT NULL
                                  AND consumption_chain_id IS NOT NULL AND compromised_at IS NULL)
           OR (state = 'COMPROMISED' AND compromised_at IS NOT NULL))
);

CREATE TABLE strategy_training_test.test_readiness_approvals (
    readiness_approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_set_id uuid NOT NULL UNIQUE REFERENCES strategy_training_test.test_sets,
    requested_by_user_id uuid NOT NULL REFERENCES core.app_users,
    approved_by_user_id uuid REFERENCES core.app_users,
    readiness_evidence_hash char(64) NOT NULL,
    state varchar(16) NOT NULL DEFAULT 'REQUESTED' CHECK (state IN ('REQUESTED', 'APPROVED', 'REJECTED')),
    decision_reason text,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    decided_at timestamptz,
    CHECK (readiness_evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((state = 'REQUESTED' AND approved_by_user_id IS NULL AND decision_reason IS NULL AND decided_at IS NULL)
           OR (state IN ('APPROVED', 'REJECTED') AND approved_by_user_id IS NOT NULL
                         AND decision_reason IS NOT NULL AND btrim(decision_reason) <> '' AND decided_at IS NOT NULL))
);

CREATE TABLE strategy_training_test.test_retry_approval_requests (
    retry_approval_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_set_id uuid NOT NULL REFERENCES strategy_training_test.test_sets,
    consumption_chain_id uuid NOT NULL,
    requested_by_user_id uuid NOT NULL REFERENCES core.app_users,
    approved_by_user_id uuid REFERENCES core.app_users,
    same_version_proof_hash char(64) NOT NULL,
    no_exposure_proof_hash char(64) NOT NULL,
    state varchar(16) NOT NULL DEFAULT 'REQUESTED' CHECK (state IN ('REQUESTED', 'APPROVED', 'REJECTED', 'USED')),
    reason text NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    decided_at timestamptz,
    used_at timestamptz,
    CHECK (same_version_proof_hash ~ '^[0-9a-f]{64}$'),
    CHECK (no_exposure_proof_hash ~ '^[0-9a-f]{64}$'),
    CHECK (btrim(reason) <> ''),
    CHECK ((state = 'REQUESTED' AND approved_by_user_id IS NULL
                                 AND decided_at IS NULL AND used_at IS NULL)
           OR (state IN ('APPROVED', 'REJECTED') AND approved_by_user_id IS NOT NULL
                         AND decided_at IS NOT NULL AND used_at IS NULL)
           OR (state = 'USED' AND approved_by_user_id IS NOT NULL
                              AND decided_at IS NOT NULL AND used_at IS NOT NULL)),
    UNIQUE (test_set_id, same_version_proof_hash, no_exposure_proof_hash)
);

CREATE TABLE strategy_training_test.test_set_access_log (
    test_access_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_set_id uuid NOT NULL REFERENCES strategy_training_test.test_sets,
    access_kind varchar(16) NOT NULL CHECK (access_kind IN ('INITIAL', 'RETRY')),
    request_id uuid NOT NULL UNIQUE,
    requester_service text NOT NULL,
    allowed boolean NOT NULL,
    reason_code varchar(64) NOT NULL,
    consumption_chain_id uuid,
    retry_approval_request_id uuid REFERENCES strategy_training_test.test_retry_approval_requests,
    accessed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(requester_service) <> ''),
    CHECK (btrim(reason_code) <> '')
);

CREATE TABLE strategy_training_test.test_state_transition_log (
    transition_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_set_id uuid NOT NULL REFERENCES strategy_training_test.test_sets,
    old_state varchar(16),
    new_state varchar(16) NOT NULL,
    actor_user_id uuid REFERENCES core.app_users,
    actor_service text,
    reason text NOT NULL,
    request_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((actor_user_id IS NOT NULL AND actor_service IS NULL)
           OR (actor_user_id IS NULL AND actor_service IS NOT NULL AND btrim(actor_service) <> '')),
    CHECK (btrim(reason) <> '')
);

CREATE TABLE strategy_training_test.test_model_exposures (
    test_model_exposure_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    test_logical_scope_id uuid NOT NULL REFERENCES strategy_training_test.test_logical_scopes,
    model_version_id uuid NOT NULL REFERENCES strategy_training.training_model_versions,
    test_set_id uuid NOT NULL REFERENCES strategy_training_test.test_sets,
    exposure_state varchar(16) NOT NULL CHECK (exposure_state IN ('CONSUMED', 'COMPROMISED')),
    evidence_hash char(64) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    UNIQUE (test_logical_scope_id, model_version_id)
);

CREATE OR REPLACE FUNCTION strategy_training_test.create_test_logical_scope(
    p_partition_start_at timestamptz, p_partition_end_at timestamptz,
    p_ticker_pool_rule_version_id uuid, p_created_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_created_by_user_id, 'TRAINING_ADMIN');
    IF NOT EXISTS (SELECT 1 FROM strategy_training.training_config_versions
                   WHERE config_version_id = p_ticker_pool_rule_version_id
                     AND config_type = 'TICKER_POOL_RULES' AND status = 'READY') THEN
        RAISE EXCEPTION 'TEST scope requires READY ticker pool rules' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training_test.test_logical_scopes (
        test_logical_scope_id, partition_start_at, partition_end_at,
        ticker_pool_rule_version_id, controlled_purpose, scope_hash, created_by_user_id
    ) VALUES (new_id, p_partition_start_at, p_partition_end_at,
        p_ticker_pool_rule_version_id, 'FORMAL_MODEL_TEST',
        strategy_training_test.compute_test_scope_hash(p_partition_start_at,
            p_partition_end_at, p_ticker_pool_rule_version_id, 'FORMAL_MODEL_TEST'),
        p_created_by_user_id);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.create_test_dataset_version(
    p_test_logical_scope_id uuid, p_content_fingerprint char(64),
    p_source_revision_watermark jsonb, p_supersedes_test_dataset_version_id uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    IF p_supersedes_test_dataset_version_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM strategy_training_test.test_dataset_versions
        WHERE test_dataset_version_id = p_supersedes_test_dataset_version_id
          AND test_logical_scope_id = p_test_logical_scope_id
    ) THEN
        RAISE EXCEPTION 'TEST replacement must retain logical identity' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training_test.test_dataset_versions (
        test_dataset_version_id, test_logical_scope_id, content_fingerprint,
        source_revision_watermark, supersedes_test_dataset_version_id
    ) VALUES (new_id, p_test_logical_scope_id, p_content_fingerprint,
              p_source_revision_watermark, p_supersedes_test_dataset_version_id);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.freeze_test_dataset_version(
    p_test_dataset_version_id uuid
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
BEGIN
    UPDATE strategy_training_test.test_dataset_versions
    SET state = 'FROZEN', frozen_at = clock_timestamp()
    WHERE test_dataset_version_id = p_test_dataset_version_id AND state = 'DRAFT';
    IF NOT FOUND THEN RAISE EXCEPTION 'TEST dataset is not DRAFT' USING ERRCODE = '55000'; END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.create_test_set(
    p_test_dataset_version_id uuid, p_model_a_version_id uuid,
    p_model_b_version_id uuid, p_visibility_cutoff_at timestamptz,
    p_pre_seal_exposure_status text
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid(); scope_id uuid; partition_start timestamptz;
BEGIN
    SELECT dataset.test_logical_scope_id, scope.partition_start_at
    INTO STRICT scope_id, partition_start
    FROM strategy_training_test.test_dataset_versions dataset
    JOIN strategy_training_test.test_logical_scopes scope
      ON scope.test_logical_scope_id = dataset.test_logical_scope_id
    WHERE dataset.test_dataset_version_id = p_test_dataset_version_id
      AND dataset.state = 'FROZEN';
    IF p_visibility_cutoff_at > partition_start
       OR p_pre_seal_exposure_status <> 'NONE'
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_model_versions
                      WHERE model_version_id = p_model_a_version_id
                        AND model_type = 'MODEL_A' AND state = 'LOCKED')
       OR (p_model_b_version_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM strategy_training.training_model_versions
            WHERE model_version_id = p_model_b_version_id
              AND model_type = 'MODEL_B' AND state = 'LOCKED')) THEN
        RAISE EXCEPTION 'TEST set readiness prerequisites are not met' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        WITH RECURSIVE lineage(model_version_id) AS (
            SELECT model_id
            FROM unnest(ARRAY[p_model_a_version_id, p_model_b_version_id]) model_id
            WHERE model_id IS NOT NULL
            UNION
            SELECT edge.parent_model_version_id
            FROM strategy_training.training_model_lineage_edges edge
            JOIN lineage ON edge.child_model_version_id = lineage.model_version_id
        ) SELECT 1 FROM lineage
        JOIN strategy_training_test.test_model_exposures exposure USING (model_version_id)
        WHERE exposure.test_logical_scope_id = scope_id
    ) THEN
        RAISE EXCEPTION 'model lineage already consumed this TEST logical scope'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training_test.test_sets (
        test_set_id, test_logical_scope_id, test_dataset_version_id,
        model_a_version_id, model_b_version_id, visibility_cutoff_at,
        pre_seal_exposure_status
    ) VALUES (new_id, scope_id, p_test_dataset_version_id,
              p_model_a_version_id, p_model_b_version_id,
              p_visibility_cutoff_at, p_pre_seal_exposure_status);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.request_test_readiness(
    p_test_set_id uuid, p_requested_by_user_id uuid, p_readiness_evidence_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_requested_by_user_id, 'TRAINING_ADMIN');
    IF NOT EXISTS (SELECT 1 FROM strategy_training_test.test_sets
                   WHERE test_set_id = p_test_set_id AND state = 'DRAFT'
                     AND pre_seal_exposure_status = 'NONE') THEN
        RAISE EXCEPTION 'TEST set is not ready for readiness review' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training_test.test_readiness_approvals (
        readiness_approval_id, test_set_id, requested_by_user_id, readiness_evidence_hash
    ) VALUES (new_id, p_test_set_id, p_requested_by_user_id, p_readiness_evidence_hash);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.decide_and_seal_test_readiness(
    p_readiness_approval_id uuid, p_approved_by_user_id uuid,
    p_approve boolean, p_reason text, p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE approval strategy_training_test.test_readiness_approvals%ROWTYPE;
    requester_person uuid; approver_person uuid;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_approved_by_user_id, 'TRAINING_TEST_AUDITOR');
    SELECT * INTO STRICT approval FROM strategy_training_test.test_readiness_approvals
    WHERE readiness_approval_id = p_readiness_approval_id FOR UPDATE;
    IF approval.state <> 'REQUESTED' OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TEST readiness request is not decidable' USING ERRCODE = '23514';
    END IF;
    SELECT natural_person_id INTO STRICT requester_person
    FROM core.app_user_training_identities WHERE user_id = approval.requested_by_user_id;
    SELECT natural_person_id INTO STRICT approver_person
    FROM core.app_user_training_identities WHERE user_id = p_approved_by_user_id;
    IF requester_person = approver_person THEN
        RAISE EXCEPTION 'TEST readiness requires two different natural persons'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training_test.test_readiness_approvals
    SET state = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
        approved_by_user_id = p_approved_by_user_id,
        decision_reason = p_reason, decided_at = clock_timestamp()
    WHERE readiness_approval_id = p_readiness_approval_id;
    IF p_approve THEN
        UPDATE strategy_training_test.test_sets
        SET state = 'SEALED', sealed_at = clock_timestamp()
        WHERE test_set_id = approval.test_set_id AND state = 'DRAFT';
        IF NOT FOUND THEN RAISE EXCEPTION 'TEST set is not DRAFT' USING ERRCODE = '55000'; END IF;
        INSERT INTO strategy_training_test.test_state_transition_log (
            test_set_id, old_state, new_state, actor_user_id, reason, request_id
        ) VALUES (approval.test_set_id, 'DRAFT', 'SEALED', p_approved_by_user_id,
                  p_reason, p_request_id);
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.consume_test_set(
    p_test_set_id uuid, p_request_id uuid, p_requester_service text
)
RETURNS TABLE (allowed boolean, reason_code text, consumption_chain_id uuid,
               test_dataset_version_id uuid, model_a_version_id uuid, model_b_version_id uuid)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core, public
AS $$
DECLARE test_record strategy_training_test.test_sets%ROWTYPE; chain_id uuid := gen_random_uuid();
BEGIN
    SELECT * INTO STRICT test_record FROM strategy_training_test.test_sets
    WHERE test_set_id = p_test_set_id FOR UPDATE;
    IF test_record.state <> 'SEALED' THEN
        INSERT INTO strategy_training_test.test_set_access_log (
            test_set_id, access_kind, request_id, requester_service,
            allowed, reason_code, consumption_chain_id
        ) VALUES (p_test_set_id, 'INITIAL', p_request_id, p_requester_service,
                  false, 'TEST_NOT_SEALED', test_record.consumption_chain_id);
        RETURN QUERY SELECT false, 'TEST_NOT_SEALED'::text,
            test_record.consumption_chain_id, NULL::uuid, NULL::uuid, NULL::uuid;
        RETURN;
    END IF;
    UPDATE strategy_training_test.test_sets
    SET state = 'CONSUMED', consumed_at = clock_timestamp(), consumption_chain_id = chain_id
    WHERE test_set_id = p_test_set_id;
    INSERT INTO strategy_training_test.test_set_access_log (
        test_set_id, access_kind, request_id, requester_service,
        allowed, reason_code, consumption_chain_id
    ) VALUES (p_test_set_id, 'INITIAL', p_request_id, p_requester_service,
              true, 'CONSUMED', chain_id);
    INSERT INTO strategy_training_test.test_state_transition_log (
        test_set_id, old_state, new_state, actor_service, reason, request_id
    ) VALUES (p_test_set_id, 'SEALED', 'CONSUMED', p_requester_service,
              'atomic first TEST consumption', p_request_id);
    INSERT INTO strategy_training_test.test_model_exposures (
        test_logical_scope_id, model_version_id, test_set_id, exposure_state, evidence_hash
    ) SELECT test_record.test_logical_scope_id, model_id, p_test_set_id, 'CONSUMED',
             encode(public.digest(concat_ws('|', p_test_set_id::text,
                 model_id::text, chain_id::text), 'sha256'), 'hex')
      FROM unnest(ARRAY[test_record.model_a_version_id, test_record.model_b_version_id]) model_id
      WHERE model_id IS NOT NULL;
    RETURN QUERY SELECT true, 'CONSUMED'::text, chain_id,
        test_record.test_dataset_version_id, test_record.model_a_version_id,
        test_record.model_b_version_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.request_test_retry(
    p_test_set_id uuid, p_requested_by_user_id uuid,
    p_same_version_proof_hash char(64), p_no_exposure_proof_hash char(64), p_reason text
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid(); chain_id uuid;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_requested_by_user_id, 'TRAINING_ADMIN');
    SELECT consumption_chain_id INTO STRICT chain_id FROM strategy_training_test.test_sets
    WHERE test_set_id = p_test_set_id AND state = 'CONSUMED';
    INSERT INTO strategy_training_test.test_retry_approval_requests (
        retry_approval_request_id, test_set_id, consumption_chain_id,
        requested_by_user_id, same_version_proof_hash, no_exposure_proof_hash, reason
    ) VALUES (new_id, p_test_set_id, chain_id, p_requested_by_user_id,
              p_same_version_proof_hash, p_no_exposure_proof_hash, p_reason);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.decide_test_retry(
    p_retry_approval_request_id uuid, p_approved_by_user_id uuid,
    p_approve boolean
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE retry strategy_training_test.test_retry_approval_requests%ROWTYPE;
    requester_person uuid; approver_person uuid;
BEGIN
    PERFORM strategy_training.assert_active_training_role(p_approved_by_user_id, 'TRAINING_TEST_AUDITOR');
    SELECT * INTO STRICT retry FROM strategy_training_test.test_retry_approval_requests
    WHERE retry_approval_request_id = p_retry_approval_request_id FOR UPDATE;
    SELECT natural_person_id INTO STRICT requester_person FROM core.app_user_training_identities
    WHERE user_id = retry.requested_by_user_id;
    SELECT natural_person_id INTO STRICT approver_person FROM core.app_user_training_identities
    WHERE user_id = p_approved_by_user_id;
    IF retry.state <> 'REQUESTED' OR requester_person = approver_person THEN
        RAISE EXCEPTION 'retry approval requires a pending request and different people'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training_test.test_retry_approval_requests
    SET state = CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END,
        approved_by_user_id = p_approved_by_user_id, decided_at = clock_timestamp()
    WHERE retry_approval_request_id = p_retry_approval_request_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.consume_test_retry(
    p_retry_approval_request_id uuid, p_request_id uuid, p_requester_service text
)
RETURNS TABLE (allowed boolean, reason_code text, consumption_chain_id uuid,
               test_dataset_version_id uuid, model_a_version_id uuid, model_b_version_id uuid)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE retry strategy_training_test.test_retry_approval_requests%ROWTYPE;
    test_record strategy_training_test.test_sets%ROWTYPE;
BEGIN
    SELECT * INTO STRICT retry FROM strategy_training_test.test_retry_approval_requests
    WHERE retry_approval_request_id = p_retry_approval_request_id FOR UPDATE;
    SELECT * INTO STRICT test_record FROM strategy_training_test.test_sets
    WHERE test_set_id = retry.test_set_id FOR UPDATE;
    IF retry.state <> 'APPROVED' OR test_record.state <> 'CONSUMED'
       OR retry.consumption_chain_id <> test_record.consumption_chain_id THEN
        INSERT INTO strategy_training_test.test_set_access_log (
            test_set_id, access_kind, request_id, requester_service, allowed,
            reason_code, consumption_chain_id, retry_approval_request_id
        ) VALUES (retry.test_set_id, 'RETRY', p_request_id, p_requester_service,
                  false, 'RETRY_NOT_APPROVED', test_record.consumption_chain_id,
                  p_retry_approval_request_id);
        RETURN QUERY SELECT false, 'RETRY_NOT_APPROVED'::text,
            test_record.consumption_chain_id, NULL::uuid, NULL::uuid, NULL::uuid;
        RETURN;
    END IF;
    UPDATE strategy_training_test.test_retry_approval_requests
    SET state = 'USED', used_at = clock_timestamp()
    WHERE retry_approval_request_id = p_retry_approval_request_id;
    INSERT INTO strategy_training_test.test_set_access_log (
        test_set_id, access_kind, request_id, requester_service, allowed,
        reason_code, consumption_chain_id, retry_approval_request_id
    ) VALUES (retry.test_set_id, 'RETRY', p_request_id, p_requester_service,
              true, 'APPROVED_RETRY', test_record.consumption_chain_id,
              p_retry_approval_request_id);
    RETURN QUERY SELECT true, 'APPROVED_RETRY'::text,
        test_record.consumption_chain_id, test_record.test_dataset_version_id,
        test_record.model_a_version_id, test_record.model_b_version_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training_test.compromise_test_set(
    p_test_set_id uuid, p_actor_user_id uuid, p_reason text, p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training_test, strategy_training, core
AS $$
DECLARE old_state text;
BEGIN
    IF NOT (
        EXISTS (
            SELECT 1 FROM core.app_user_training_roles role_grant
            WHERE role_grant.user_id = p_actor_user_id
              AND role_grant.training_role IN ('TRAINING_ADMIN', 'TRAINING_TEST_AUDITOR')
              AND role_grant.valid_from <= clock_timestamp()
              AND role_grant.expires_at > clock_timestamp()
              AND NOT EXISTS (
                  SELECT 1 FROM core.app_user_training_role_revocations revocation
                  WHERE revocation.grant_id = role_grant.grant_id
              )
        )
    ) THEN
        RAISE EXCEPTION 'actor cannot compromise TEST state' USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'compromise reason is required' USING ERRCODE = '22023';
    END IF;
    SELECT state INTO STRICT old_state FROM strategy_training_test.test_sets
    WHERE test_set_id = p_test_set_id FOR UPDATE;
    IF old_state = 'COMPROMISED' THEN
        RAISE EXCEPTION 'TEST set is already COMPROMISED' USING ERRCODE = '55000';
    END IF;
    UPDATE strategy_training_test.test_sets
    SET state = 'COMPROMISED', compromised_at = clock_timestamp()
    WHERE test_set_id = p_test_set_id;
    INSERT INTO strategy_training_test.test_state_transition_log (
        test_set_id, old_state, new_state, actor_user_id, reason, request_id
    ) VALUES (p_test_set_id, old_state, 'COMPROMISED', p_actor_user_id,
              p_reason, p_request_id);
    INSERT INTO strategy_training_test.test_model_exposures (
        test_logical_scope_id, model_version_id, test_set_id, exposure_state, evidence_hash
    ) SELECT test_record.test_logical_scope_id, model_id, p_test_set_id, 'COMPROMISED',
             encode(public.digest(concat_ws('|', p_test_set_id::text,
                 model_id::text, p_request_id::text, 'COMPROMISED'), 'sha256'), 'hex')
      FROM strategy_training_test.test_sets test_record,
           unnest(ARRAY[test_record.model_a_version_id, test_record.model_b_version_id]) model_id
      WHERE test_record.test_set_id = p_test_set_id AND model_id IS NOT NULL
    ON CONFLICT (test_logical_scope_id, model_version_id) DO NOTHING;
END
$$;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['training_model_lineage_edges'] LOOP
        EXECUTE format('CREATE TRIGGER trg_%I_append_only BEFORE UPDATE OR DELETE ON strategy_training.%I FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()', table_name, table_name);
    END LOOP;
    FOREACH table_name IN ARRAY ARRAY[
        'test_logical_scopes', 'test_set_access_log', 'test_state_transition_log',
        'test_model_exposures'
    ] LOOP
        EXECUTE format('CREATE TRIGGER trg_%I_append_only BEFORE UPDATE OR DELETE ON strategy_training_test.%I FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()', table_name, table_name);
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_model_versions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_lineage_edges OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_lock_approvals OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_logical_scopes OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_dataset_versions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_sets OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_readiness_approvals OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_retry_approval_requests OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_set_access_log OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_state_transition_log OWNER TO tb2_training_owner;
ALTER TABLE strategy_training_test.test_model_exposures OWNER TO tb2_training_owner;

ALTER FUNCTION strategy_training.create_training_model_version(text, uuid, char(64), uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.add_training_model_lineage(uuid, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.request_training_model_lock(uuid, uuid, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.decide_training_model_lock(uuid, uuid, boolean, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.compute_test_scope_hash(timestamptz, timestamptz, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.create_test_logical_scope(timestamptz, timestamptz, uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.create_test_dataset_version(uuid, char(64), jsonb, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.freeze_test_dataset_version(uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.create_test_set(uuid, uuid, uuid, timestamptz, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.request_test_readiness(uuid, uuid, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.decide_and_seal_test_readiness(uuid, uuid, boolean, text, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.consume_test_set(uuid, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.request_test_retry(uuid, uuid, char(64), char(64), text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.decide_test_retry(uuid, uuid, boolean) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.consume_test_retry(uuid, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training_test.compromise_test_set(uuid, uuid, text, uuid) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training_test FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training_test FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

-- SECURITY DEFINER governance functions must resolve the requesting and
-- approving natural-person identities without granting application roles
-- direct access to the core identity table.
GRANT SELECT ON core.app_user_training_identities TO tb2_training_owner;

GRANT USAGE ON SCHEMA strategy_training_test TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION
    strategy_training.create_training_model_version(text, uuid, char(64), uuid),
    strategy_training.add_training_model_lineage(uuid, uuid, text),
    strategy_training.request_training_model_lock(uuid, uuid, char(64)),
    strategy_training.decide_training_model_lock(uuid, uuid, boolean, text)
TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION
    strategy_training_test.create_test_logical_scope(timestamptz, timestamptz, uuid, uuid),
    strategy_training_test.create_test_dataset_version(uuid, char(64), jsonb, uuid),
    strategy_training_test.freeze_test_dataset_version(uuid),
    strategy_training_test.create_test_set(uuid, uuid, uuid, timestamptz, text),
    strategy_training_test.request_test_readiness(uuid, uuid, char(64)),
    strategy_training_test.request_test_retry(uuid, uuid, char(64), char(64), text),
    strategy_training_test.compromise_test_set(uuid, uuid, text, uuid)
TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION
    strategy_training_test.decide_and_seal_test_readiness(uuid, uuid, boolean, text, uuid),
    strategy_training_test.decide_test_retry(uuid, uuid, boolean),
    strategy_training_test.compromise_test_set(uuid, uuid, text, uuid)
TO tb2_training_test_auditor;

GRANT EXECUTE ON FUNCTION
    strategy_training_test.consume_test_set(uuid, uuid, text),
    strategy_training_test.consume_test_retry(uuid, uuid, text)
TO tb2_training_test_executor;

GRANT SELECT ON strategy_training_test.test_readiness_approvals,
    strategy_training_test.test_retry_approval_requests,
    strategy_training_test.test_set_access_log,
    strategy_training_test.test_state_transition_log,
    strategy_training_test.test_model_exposures
TO tb2_training_test_auditor;

GRANT SELECT ON ALL TABLES IN SCHEMA strategy_training_test TO tb2_training_test_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '032_training_model_test_governance',
    encode(digest('auto_trade_v2_032_training_model_test_governance_v1', 'sha256'), 'hex'),
    'Add model locking, lineage, dual-person TEST readiness, atomic consumption and governed retry skeleton'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
