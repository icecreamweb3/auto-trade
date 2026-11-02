\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_tasks (
    task_id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_task_id             uuid REFERENCES strategy_training.training_tasks,
    experiment_id              uuid NOT NULL REFERENCES strategy_training.training_experiments,
    iteration_id               uuid REFERENCES strategy_training.training_iterations,
    optimizer_run_id           uuid REFERENCES strategy_training.training_optimizer_runs,
    task_type                  varchar(32) NOT NULL CHECK (task_type IN (
                                   'DATASET_BUILD', 'MODEL_A_EVALUATION',
                                   'MODEL_B_REPLAY', 'PORTFOLIO_EVALUATION',
                                   'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY'
                               )),
    executor_kind              varchar(16) NOT NULL CHECK (executor_kind IN (
                                   'WORKER', 'OPTIMIZER', 'EVALUATOR', 'MODEL_B'
                               )),
    idempotency_key            char(64) NOT NULL UNIQUE,
    task_payload               jsonb NOT NULL,
    priority                   integer NOT NULL DEFAULT 100,
    state                      varchar(16) NOT NULL DEFAULT 'QUEUED' CHECK (state IN (
                                   'QUEUED', 'LEASED', 'RUNNING', 'PAUSED',
                                   'SUCCEEDED', 'FAILED', 'CANCELLED'
                               )),
    attempt_count              integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    checkpoint_sequence        integer NOT NULL DEFAULT 0 CHECK (checkpoint_sequence >= 0),
    lease_token               uuid,
    leased_by                 text,
    lease_expires_at          timestamptz,
    cancellation_requested_at timestamptz,
    cancellation_reason       text,
    result_hash               char(64),
    failure_code              varchar(64),
    created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at                timestamptz,
    completed_at              timestamptz,
    CHECK (parent_task_id IS NULL OR parent_task_id <> task_id),
    CHECK (idempotency_key ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(task_payload) = 'object' AND task_payload <> '{}'::jsonb),
    CHECK (leased_by IS NULL OR btrim(leased_by) <> ''),
    CHECK (result_hash IS NULL OR result_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (state = 'QUEUED' AND lease_token IS NULL AND leased_by IS NULL
                          AND lease_expires_at IS NULL AND completed_at IS NULL)
        OR (state IN ('LEASED', 'RUNNING') AND lease_token IS NOT NULL
                          AND leased_by IS NOT NULL AND lease_expires_at IS NOT NULL
                          AND completed_at IS NULL)
        OR (state = 'PAUSED' AND lease_token IS NULL AND leased_by IS NULL
                          AND lease_expires_at IS NULL AND completed_at IS NULL)
        OR (state IN ('SUCCEEDED', 'FAILED', 'CANCELLED')
                          AND lease_token IS NULL AND leased_by IS NULL
                          AND lease_expires_at IS NULL AND completed_at IS NOT NULL)
    ),
    CHECK ((state = 'SUCCEEDED') = (result_hash IS NOT NULL)),
    CHECK (
        (state IN ('FAILED', 'CANCELLED') AND failure_code IS NOT NULL
                                            AND btrim(failure_code) <> '')
        OR (state NOT IN ('FAILED', 'CANCELLED') AND failure_code IS NULL)
    ),
    CHECK (
        (cancellation_requested_at IS NULL AND cancellation_reason IS NULL)
        OR (cancellation_requested_at IS NOT NULL AND cancellation_reason IS NOT NULL
                                                  AND btrim(cancellation_reason) <> '')
    )
);

CREATE INDEX ix_training_tasks_claim
ON strategy_training.training_tasks (executor_kind, state, priority, created_at);

CREATE TABLE strategy_training.training_task_events (
    task_event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id            uuid NOT NULL REFERENCES strategy_training.training_tasks,
    attempt_number     integer NOT NULL CHECK (attempt_number >= 0),
    old_state          varchar(16),
    new_state          varchar(16) NOT NULL,
    worker_identity    text,
    reason_code        varchar(64) NOT NULL,
    event_payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (old_state IS NULL OR btrim(old_state) <> ''),
    CHECK (btrim(new_state) <> ''),
    CHECK (worker_identity IS NULL OR btrim(worker_identity) <> ''),
    CHECK (btrim(reason_code) <> ''),
    CHECK (jsonb_typeof(event_payload) = 'object')
);

CREATE TABLE strategy_training.training_task_checkpoints (
    task_checkpoint_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id            uuid NOT NULL REFERENCES strategy_training.training_tasks,
    attempt_number     integer NOT NULL CHECK (attempt_number > 0),
    sequence_no        integer NOT NULL CHECK (sequence_no > 0),
    checkpoint_hash    char(64) NOT NULL,
    checkpoint_uri_hash char(64) NOT NULL,
    fact_watermark     jsonb NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (checkpoint_hash ~ '^[0-9a-f]{64}$'),
    CHECK (checkpoint_uri_hash ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(fact_watermark) = 'object'),
    UNIQUE (task_id, sequence_no),
    UNIQUE (task_id, checkpoint_hash)
);

CREATE TABLE strategy_training.training_task_resource_admissions (
    resource_admission_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id                uuid NOT NULL UNIQUE REFERENCES strategy_training.training_tasks,
    resource_preflight_id  uuid NOT NULL
                           REFERENCES strategy_training.training_resource_preflight_reports,
    resource_limit_config_version_id uuid NOT NULL
                           REFERENCES strategy_training.training_config_versions,
    active_heavy_experiment_count integer NOT NULL CHECK (active_heavy_experiment_count >= 0),
    admitted               boolean NOT NULL,
    rejection_codes        jsonb NOT NULL,
    evidence_hash          char(64) NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(rejection_codes) = 'array'),
    CHECK ((admitted AND jsonb_array_length(rejection_codes) = 0)
           OR (NOT admitted AND jsonb_array_length(rejection_codes) > 0)),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_iteration_evidence_l0 (
    iteration_id             uuid PRIMARY KEY REFERENCES strategy_training.training_iterations,
    partition                varchar(16) NOT NULL CHECK (partition IN ('TRAIN', 'VALIDATION')),
    validation_evaluation_id uuid REFERENCES strategy_training.training_validation_evaluations,
    terminal_state           varchar(16) NOT NULL CHECK (terminal_state IN (
                                 'SUCCEEDED', 'FAILED', 'REJECTED', 'CANCELLED'
                             )),
    hard_gate_passed         boolean NOT NULL,
    rejection_codes          jsonb NOT NULL,
    objective_value          numeric,
    aggregate_metrics        jsonb NOT NULL,
    evidence_hash            char(64) NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(rejection_codes) = 'array'),
    CHECK (jsonb_typeof(aggregate_metrics) = 'object'),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((partition = 'TRAIN' AND validation_evaluation_id IS NULL)
           OR (partition = 'VALIDATION' AND validation_evaluation_id IS NOT NULL)),
    CHECK ((terminal_state = 'SUCCEEDED' AND hard_gate_passed AND objective_value IS NOT NULL
                                           AND jsonb_array_length(rejection_codes) = 0)
           OR (terminal_state <> 'SUCCEEDED' AND objective_value IS NULL
                                                AND jsonb_array_length(rejection_codes) > 0))
);

CREATE VIEW strategy_training.optimizer_train_objectives
WITH (security_barrier = true)
AS
SELECT evidence.iteration_id, iteration.experiment_id,
       iteration.candidate_version, iteration.candidate_content_hash,
       evidence.objective_value, evidence.evidence_hash
FROM strategy_training.training_iteration_evidence_l0 evidence
JOIN strategy_training.training_iterations iteration
  ON iteration.iteration_id = evidence.iteration_id
WHERE evidence.partition = 'TRAIN'
  AND evidence.terminal_state = 'SUCCEEDED'
  AND evidence.hard_gate_passed;

CREATE TABLE strategy_training.training_iteration_summaries_l1 (
    iteration_summary_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    iteration_id         uuid NOT NULL REFERENCES strategy_training.training_iterations,
    summary_kind         varchar(24) NOT NULL CHECK (summary_kind IN (
                             'FACTOR', 'EVENT', 'PARTITION', 'PORTFOLIO'
                         )),
    row_count            bigint NOT NULL CHECK (row_count >= 0),
    input_fingerprint    char(64) NOT NULL,
    output_fingerprint   char(64) NOT NULL,
    l0_aggregate_hash    char(64) NOT NULL,
    consistency_status   varchar(16) NOT NULL CHECK (consistency_status IN ('MATCH', 'MISMATCH')),
    mismatch_reason      text,
    created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (input_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (output_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (l0_aggregate_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((consistency_status = 'MATCH' AND mismatch_reason IS NULL)
           OR (consistency_status = 'MISMATCH' AND mismatch_reason IS NOT NULL
                                                AND btrim(mismatch_reason) <> '')),
    UNIQUE (iteration_id, summary_kind)
);

CREATE TABLE strategy_training.training_l2_retention_plans (
    retention_plan_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id            uuid NOT NULL UNIQUE REFERENCES strategy_training.training_experiments,
    retention_policy_version_id uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    selection_rule           jsonb NOT NULL,
    maximum_detail_rows      bigint NOT NULL CHECK (maximum_detail_rows > 0),
    plan_hash                char(64) NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(selection_rule) = 'object' AND selection_rule <> '{}'::jsonb),
    CHECK (plan_hash ~ '^[0-9a-f]{64}$')
);

CREATE TABLE strategy_training.training_archive_manifests (
    archive_manifest_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    retention_plan_id    uuid NOT NULL REFERENCES strategy_training.training_l2_retention_plans,
    iteration_id         uuid NOT NULL REFERENCES strategy_training.training_iterations,
    artifact_kind        varchar(32) NOT NULL CHECK (artifact_kind IN (
                             'SIGNALS', 'DECISIONS', 'FILLS', 'EQUITY_POINTS'
                         )),
    storage_uri_hash     char(64) NOT NULL,
    archive_format       varchar(16) NOT NULL CHECK (archive_format = 'PARQUET'),
    compression          varchar(16) NOT NULL CHECK (compression = 'ZSTD'),
    row_count            bigint NOT NULL CHECK (row_count > 0),
    minimum_observed_at  timestamptz NOT NULL,
    maximum_observed_at  timestamptz NOT NULL,
    object_size_bytes    bigint NOT NULL CHECK (object_size_bytes > 0),
    content_sha256       char(64) NOT NULL,
    state                varchar(16) NOT NULL DEFAULT 'STORED'
                         CHECK (state IN ('STORED', 'VERIFIED', 'FAILED')),
    restored_sha256      char(64),
    restore_failure_code varchar(64),
    created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    verified_at          timestamptz,
    CHECK (storage_uri_hash ~ '^[0-9a-f]{64}$'),
    CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    CHECK (restored_sha256 IS NULL OR restored_sha256 ~ '^[0-9a-f]{64}$'),
    CHECK (minimum_observed_at <= maximum_observed_at),
    CHECK ((state = 'STORED' AND restored_sha256 IS NULL
                             AND restore_failure_code IS NULL AND verified_at IS NULL)
           OR (state = 'VERIFIED' AND restored_sha256 = content_sha256
                               AND restore_failure_code IS NULL AND verified_at IS NOT NULL)
           OR (state = 'FAILED' AND restored_sha256 IS NULL
                             AND restore_failure_code IS NOT NULL
                             AND btrim(restore_failure_code) <> '' AND verified_at IS NOT NULL)),
    UNIQUE (retention_plan_id, iteration_id, artifact_kind)
);

CREATE TABLE strategy_training.training_archive_restore_log (
    restore_log_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    archive_manifest_id  uuid NOT NULL REFERENCES strategy_training.training_archive_manifests,
    restored_row_count   bigint NOT NULL CHECK (restored_row_count >= 0),
    restored_minimum_at  timestamptz,
    restored_maximum_at  timestamptz,
    restored_size_bytes  bigint NOT NULL CHECK (restored_size_bytes >= 0),
    restored_sha256      char(64) NOT NULL,
    result               varchar(16) NOT NULL CHECK (result IN ('MATCH', 'MISMATCH')),
    checked_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (restored_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE OR REPLACE FUNCTION strategy_training.enqueue_training_task(
    p_experiment_id uuid, p_iteration_id uuid, p_optimizer_run_id uuid,
    p_parent_task_id uuid, p_task_type text, p_executor_kind text,
    p_idempotency_key char(64), p_task_payload jsonb, p_priority integer
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    existing_task strategy_training.training_tasks%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    preflight_record strategy_training.training_resource_preflight_reports%ROWTYPE;
    resource_config jsonb;
    active_count integer;
    rejection_codes jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO existing_task FROM strategy_training.training_tasks
    WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        IF existing_task.experiment_id <> p_experiment_id
           OR existing_task.iteration_id IS DISTINCT FROM p_iteration_id
           OR existing_task.optimizer_run_id IS DISTINCT FROM p_optimizer_run_id
           OR existing_task.parent_task_id IS DISTINCT FROM p_parent_task_id
           OR existing_task.task_type <> p_task_type
           OR existing_task.executor_kind <> p_executor_kind
           OR existing_task.task_payload <> p_task_payload THEN
            RAISE EXCEPTION 'idempotency key is already bound to a different task'
                USING ERRCODE = '23505';
        END IF;
        RETURN existing_task.task_id;
    END IF;
    SELECT * INTO STRICT experiment_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = p_experiment_id FOR UPDATE;
    IF experiment_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'tasks require a RUNNING experiment' USING ERRCODE = '55000';
    END IF;
    IF p_iteration_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations
        WHERE iteration_id = p_iteration_id AND experiment_id = p_experiment_id
    ) THEN
        RAISE EXCEPTION 'task iteration does not belong to experiment' USING ERRCODE = '23514';
    END IF;
    IF p_optimizer_run_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM strategy_training.training_optimizer_runs
        WHERE optimizer_run_id = p_optimizer_run_id AND experiment_id = p_experiment_id
    ) THEN
        RAISE EXCEPTION 'task optimizer run does not belong to experiment' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT preflight_record
    FROM strategy_training.training_resource_preflight_reports
    WHERE dataset_version_id = experiment_record.dataset_version_id
      AND resource_limit_config_version_id = experiment_record.resource_limit_config_version_id;
    IF preflight_record.status <> 'PASS' THEN
        rejection_codes := rejection_codes || '"RESOURCE_PREFLIGHT_BLOCKED"'::jsonb;
    END IF;
    SELECT config_json INTO STRICT resource_config
    FROM strategy_training.training_config_versions
    WHERE config_version_id = experiment_record.resource_limit_config_version_id
      AND status = 'READY' AND config_type = 'RESOURCE_LIMITS';
    SELECT count(DISTINCT task.experiment_id) INTO active_count
    FROM strategy_training.training_tasks task
    WHERE task.state IN ('QUEUED', 'LEASED', 'RUNNING', 'PAUSED')
      AND task.experiment_id <> p_experiment_id;
    IF active_count >= (resource_config ->> 'max_heavy_experiments')::integer THEN
        rejection_codes := rejection_codes || '"HEAVY_EXPERIMENT_LIMIT"'::jsonb;
    END IF;
    INSERT INTO strategy_training.training_tasks (
        task_id, parent_task_id, experiment_id, iteration_id, optimizer_run_id,
        task_type, executor_kind, idempotency_key, task_payload, priority,
        state, failure_code, completed_at
    ) VALUES (
        new_id, p_parent_task_id, p_experiment_id, p_iteration_id, p_optimizer_run_id,
        p_task_type, p_executor_kind, p_idempotency_key, p_task_payload, p_priority,
        CASE WHEN jsonb_array_length(rejection_codes) = 0 THEN 'QUEUED' ELSE 'FAILED' END,
        CASE WHEN jsonb_array_length(rejection_codes) = 0
             THEN NULL ELSE 'RESOURCE_ADMISSION_BLOCKED' END,
        CASE WHEN jsonb_array_length(rejection_codes) = 0
             THEN NULL ELSE clock_timestamp() END
    );
    INSERT INTO strategy_training.training_task_resource_admissions (
        task_id, resource_preflight_id, resource_limit_config_version_id,
        active_heavy_experiment_count, admitted, rejection_codes, evidence_hash
    ) VALUES (
        new_id, preflight_record.resource_preflight_id,
        experiment_record.resource_limit_config_version_id,
        active_count, jsonb_array_length(rejection_codes) = 0, rejection_codes,
        encode(public.digest(concat_ws('|', new_id::text,
            preflight_record.evidence_hash::text, active_count::text,
            rejection_codes::text), 'sha256'), 'hex')
    );
    INSERT INTO strategy_training.training_task_events (
        task_id, attempt_number, old_state, new_state, reason_code
    ) VALUES (
        new_id, 0, NULL,
        CASE WHEN jsonb_array_length(rejection_codes) = 0 THEN 'QUEUED' ELSE 'FAILED' END,
        CASE WHEN jsonb_array_length(rejection_codes) = 0
             THEN 'ADMITTED' ELSE 'RESOURCE_ADMISSION_BLOCKED' END
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.claim_training_task_internal(
    p_executor_kind text, p_worker_identity text, p_lease_seconds integer
)
RETURNS TABLE (
    claimed_task_id uuid, claimed_lease_token uuid, claimed_attempt_number integer,
    claimed_checkpoint_sequence integer, claimed_payload jsonb,
    claimed_lease_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    selected_task strategy_training.training_tasks%ROWTYPE;
    new_token uuid := gen_random_uuid();
BEGIN
    IF p_worker_identity IS NULL OR btrim(p_worker_identity) = ''
       OR p_lease_seconds <= 0 OR p_lease_seconds > 3600 THEN
        RAISE EXCEPTION 'worker identity and lease seconds are invalid' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO selected_task
    FROM strategy_training.training_tasks task
    WHERE task.executor_kind = p_executor_kind
      AND task.cancellation_requested_at IS NULL
      AND (task.state = 'QUEUED'
           OR (task.state IN ('LEASED', 'RUNNING')
               AND task.lease_expires_at < clock_timestamp()))
    ORDER BY task.priority, task.created_at
    FOR UPDATE SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    UPDATE strategy_training.training_tasks
    SET state = 'LEASED', attempt_count = attempt_count + 1,
        lease_token = new_token, leased_by = p_worker_identity,
        lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds)
    WHERE task_id = selected_task.task_id;
    INSERT INTO strategy_training.training_task_events (
        task_id, attempt_number, old_state, new_state, worker_identity,
        reason_code, event_payload
    ) VALUES (
        selected_task.task_id, selected_task.attempt_count + 1,
        selected_task.state, 'LEASED', p_worker_identity,
        CASE WHEN selected_task.state = 'QUEUED' THEN 'CLAIMED' ELSE 'LEASE_RECOVERED' END,
        jsonb_build_object('checkpoint_sequence', selected_task.checkpoint_sequence)
    );
    RETURN QUERY SELECT selected_task.task_id, new_token,
        selected_task.attempt_count + 1, selected_task.checkpoint_sequence,
        selected_task.task_payload,
        clock_timestamp() + make_interval(secs => p_lease_seconds);
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.claim_training_worker_task(
    p_worker_identity text, p_lease_seconds integer
)
RETURNS TABLE (claimed_task_id uuid, claimed_lease_token uuid,
    claimed_attempt_number integer, claimed_checkpoint_sequence integer,
    claimed_payload jsonb, claimed_lease_expires_at timestamptz)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$ SELECT * FROM strategy_training.claim_training_task_internal(
    'WORKER', p_worker_identity, p_lease_seconds) $$;

CREATE OR REPLACE FUNCTION strategy_training.claim_training_optimizer_task(
    p_worker_identity text, p_lease_seconds integer
)
RETURNS TABLE (claimed_task_id uuid, claimed_lease_token uuid,
    claimed_attempt_number integer, claimed_checkpoint_sequence integer,
    claimed_payload jsonb, claimed_lease_expires_at timestamptz)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$ SELECT * FROM strategy_training.claim_training_task_internal(
    'OPTIMIZER', p_worker_identity, p_lease_seconds) $$;

CREATE OR REPLACE FUNCTION strategy_training.claim_training_evaluator_task(
    p_worker_identity text, p_lease_seconds integer
)
RETURNS TABLE (claimed_task_id uuid, claimed_lease_token uuid,
    claimed_attempt_number integer, claimed_checkpoint_sequence integer,
    claimed_payload jsonb, claimed_lease_expires_at timestamptz)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$ SELECT * FROM strategy_training.claim_training_task_internal(
    'EVALUATOR', p_worker_identity, p_lease_seconds) $$;

CREATE OR REPLACE FUNCTION strategy_training.claim_training_model_b_task(
    p_worker_identity text, p_lease_seconds integer
)
RETURNS TABLE (claimed_task_id uuid, claimed_lease_token uuid,
    claimed_attempt_number integer, claimed_checkpoint_sequence integer,
    claimed_payload jsonb, claimed_lease_expires_at timestamptz)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$ SELECT * FROM strategy_training.claim_training_task_internal(
    'MODEL_B', p_worker_identity, p_lease_seconds) $$;

CREATE OR REPLACE FUNCTION strategy_training.start_training_task(
    p_task_id uuid, p_lease_token uuid, p_worker_identity text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE current_attempt integer;
BEGIN
    UPDATE strategy_training.training_tasks
    SET state = 'RUNNING', started_at = COALESCE(started_at, clock_timestamp())
    WHERE task_id = p_task_id AND state = 'LEASED'
      AND lease_token = p_lease_token AND leased_by = p_worker_identity
      AND lease_expires_at >= clock_timestamp()
    RETURNING attempt_count INTO current_attempt;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'task lease is invalid or expired' USING ERRCODE = '40001';
    END IF;
    INSERT INTO strategy_training.training_task_events (
        task_id, attempt_number, old_state, new_state, worker_identity, reason_code
    ) VALUES (p_task_id, current_attempt, 'LEASED', 'RUNNING', p_worker_identity, 'STARTED');
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.heartbeat_training_task(
    p_task_id uuid, p_lease_token uuid, p_worker_identity text, p_lease_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE cancellation_requested boolean;
BEGIN
    IF p_lease_seconds <= 0 OR p_lease_seconds > 3600 THEN
        RAISE EXCEPTION 'lease seconds are invalid' USING ERRCODE = '22023';
    END IF;
    UPDATE strategy_training.training_tasks
    SET lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds)
    WHERE task_id = p_task_id AND state = 'RUNNING'
      AND lease_token = p_lease_token AND leased_by = p_worker_identity
      AND lease_expires_at >= clock_timestamp()
    RETURNING cancellation_requested_at IS NOT NULL INTO cancellation_requested;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'task heartbeat does not match active lease' USING ERRCODE = '40001';
    END IF;
    RETURN cancellation_requested;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.pause_training_task(
    p_task_id uuid, p_lease_token uuid, p_worker_identity text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE current_attempt integer;
BEGIN
    UPDATE strategy_training.training_tasks
    SET state = 'PAUSED', lease_token = NULL, leased_by = NULL, lease_expires_at = NULL
    WHERE task_id = p_task_id AND state = 'RUNNING'
      AND lease_token = p_lease_token AND leased_by = p_worker_identity
      AND lease_expires_at >= clock_timestamp()
      AND cancellation_requested_at IS NULL
    RETURNING attempt_count INTO current_attempt;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'task pause does not match active lease' USING ERRCODE = '40001';
    END IF;
    INSERT INTO strategy_training.training_task_events (
        task_id, attempt_number, old_state, new_state, worker_identity, reason_code
    ) VALUES (p_task_id, current_attempt, 'RUNNING', 'PAUSED', p_worker_identity, 'PAUSED');
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.resume_training_task(p_task_id uuid)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE current_attempt integer;
BEGIN
    UPDATE strategy_training.training_tasks
    SET state = 'QUEUED'
    WHERE task_id = p_task_id AND state = 'PAUSED'
      AND cancellation_requested_at IS NULL
    RETURNING attempt_count INTO current_attempt;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'only an uncancelled PAUSED task can resume' USING ERRCODE = '55000';
    END IF;
    INSERT INTO strategy_training.training_task_events (
        task_id, attempt_number, old_state, new_state, reason_code
    ) VALUES (p_task_id, current_attempt, 'PAUSED', 'QUEUED', 'RESUMED');
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_task_checkpoint(
    p_task_id uuid, p_lease_token uuid, p_worker_identity text,
    p_sequence_no integer, p_checkpoint_hash char(64),
    p_checkpoint_uri_hash char(64), p_fact_watermark jsonb
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE current_task strategy_training.training_tasks%ROWTYPE; new_id uuid := gen_random_uuid();
BEGIN
    SELECT * INTO STRICT current_task FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF current_task.state <> 'RUNNING' OR current_task.lease_token <> p_lease_token
       OR current_task.leased_by <> p_worker_identity
       OR current_task.lease_expires_at < clock_timestamp()
       OR p_sequence_no <> current_task.checkpoint_sequence + 1 THEN
        RAISE EXCEPTION 'checkpoint does not match active task lease/sequence'
            USING ERRCODE = '40001';
    END IF;
    INSERT INTO strategy_training.training_task_checkpoints (
        task_checkpoint_id, task_id, attempt_number, sequence_no,
        checkpoint_hash, checkpoint_uri_hash, fact_watermark
    ) VALUES (new_id, p_task_id, current_task.attempt_count, p_sequence_no,
              p_checkpoint_hash, p_checkpoint_uri_hash, p_fact_watermark);
    UPDATE strategy_training.training_tasks
    SET checkpoint_sequence = p_sequence_no WHERE task_id = p_task_id;
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.request_training_task_cancellation(
    p_task_id uuid, p_reason text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE old_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT old_task FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF old_task.state IN ('SUCCEEDED', 'FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION 'terminal task cannot be cancelled' USING ERRCODE = '55000';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'cancellation reason is required' USING ERRCODE = '22023';
    END IF;
    IF old_task.state = 'QUEUED' THEN
        UPDATE strategy_training.training_tasks
        SET state = 'CANCELLED', cancellation_requested_at = clock_timestamp(),
            cancellation_reason = p_reason, failure_code = 'CANCELLED_BEFORE_START',
            completed_at = clock_timestamp()
        WHERE task_id = p_task_id;
        INSERT INTO strategy_training.training_task_events (
            task_id, attempt_number, old_state, new_state, reason_code
        ) VALUES (p_task_id, old_task.attempt_count, 'QUEUED', 'CANCELLED',
                  'CANCELLED_BEFORE_START');
    ELSE
        UPDATE strategy_training.training_tasks
        SET cancellation_requested_at = clock_timestamp(), cancellation_reason = p_reason
        WHERE task_id = p_task_id;
        INSERT INTO strategy_training.training_task_events (
            task_id, attempt_number, old_state, new_state, reason_code
        ) VALUES (p_task_id, old_task.attempt_count, old_task.state, old_task.state,
                  'CANCELLATION_REQUESTED');
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.complete_training_task(
    p_task_id uuid, p_lease_token uuid, p_worker_identity text,
    p_terminal_state text, p_result_hash char(64), p_failure_code text
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE current_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT current_task FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF current_task.state <> 'RUNNING' OR current_task.lease_token <> p_lease_token
       OR current_task.leased_by <> p_worker_identity
       OR current_task.lease_expires_at < clock_timestamp()
       OR p_terminal_state NOT IN ('SUCCEEDED', 'FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION 'terminal update does not match active task lease'
            USING ERRCODE = '40001';
    END IF;
    IF current_task.cancellation_requested_at IS NOT NULL
       AND p_terminal_state <> 'CANCELLED' THEN
        RAISE EXCEPTION 'task with cancellation request must terminate CANCELLED'
            USING ERRCODE = '23514';
    END IF;
    IF (p_terminal_state = 'SUCCEEDED' AND p_result_hash IS NULL)
       OR (p_terminal_state <> 'SUCCEEDED' AND
           (p_failure_code IS NULL OR btrim(p_failure_code) = '')) THEN
        RAISE EXCEPTION 'terminal task evidence is incomplete' USING ERRCODE = '22023';
    END IF;
    UPDATE strategy_training.training_tasks
    SET state = p_terminal_state, lease_token = NULL, leased_by = NULL,
        lease_expires_at = NULL, result_hash = p_result_hash,
        failure_code = CASE WHEN p_terminal_state = 'SUCCEEDED' THEN NULL ELSE p_failure_code END,
        completed_at = clock_timestamp()
    WHERE task_id = p_task_id;
    INSERT INTO strategy_training.training_task_events (
        task_id, attempt_number, old_state, new_state, worker_identity, reason_code
    ) VALUES (p_task_id, current_task.attempt_count, 'RUNNING', p_terminal_state,
              p_worker_identity, COALESCE(p_failure_code, 'COMPLETED'));
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_iteration_l0(
    p_iteration_id uuid, p_partition text, p_validation_evaluation_id uuid,
    p_terminal_state text, p_hard_gate_passed boolean, p_rejection_codes jsonb,
    p_objective_value numeric, p_aggregate_metrics jsonb, p_evidence_hash char(64)
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE iteration_state text;
BEGIN
    SELECT state INTO STRICT iteration_state FROM strategy_training.training_iterations
    WHERE iteration_id = p_iteration_id;
    IF iteration_state <> p_terminal_state THEN
        RAISE EXCEPTION 'L0 terminal state does not match iteration' USING ERRCODE = '23514';
    END IF;
    IF p_partition = 'VALIDATION' AND NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_validation_evaluations evaluation
        JOIN strategy_training.training_final_candidate_freezes freeze_record
          ON freeze_record.final_candidate_freeze_id = evaluation.final_candidate_freeze_id
        WHERE evaluation.validation_evaluation_id = p_validation_evaluation_id
          AND freeze_record.iteration_id = p_iteration_id
    ) THEN
        RAISE EXCEPTION 'VALIDATION L0 must reference its frozen candidate evaluation'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_iteration_evidence_l0 (
        iteration_id, partition, validation_evaluation_id, terminal_state,
        hard_gate_passed, rejection_codes, objective_value,
        aggregate_metrics, evidence_hash
    ) VALUES (p_iteration_id, p_partition, p_validation_evaluation_id, p_terminal_state,
              p_hard_gate_passed, p_rejection_codes, p_objective_value,
              p_aggregate_metrics, p_evidence_hash);
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_iteration_l1(
    p_iteration_id uuid, p_summary_kind text, p_row_count bigint,
    p_input_fingerprint char(64), p_output_fingerprint char(64),
    p_l0_aggregate_hash char(64), p_consistency_status text, p_mismatch_reason text
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM strategy_training.training_iteration_evidence_l0
                   WHERE iteration_id = p_iteration_id) THEN
        RAISE EXCEPTION 'L1 requires existing L0 evidence' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_iteration_summaries_l1 (
        iteration_summary_id, iteration_id, summary_kind, row_count,
        input_fingerprint, output_fingerprint, l0_aggregate_hash,
        consistency_status, mismatch_reason
    ) VALUES (new_id, p_iteration_id, p_summary_kind, p_row_count,
              p_input_fingerprint, p_output_fingerprint, p_l0_aggregate_hash,
              p_consistency_status, p_mismatch_reason);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_l2_retention_plan(
    p_experiment_id uuid, p_retention_policy_version_id uuid,
    p_selection_rule jsonb, p_maximum_detail_rows bigint
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE new_id uuid := gen_random_uuid(); experiment_state text;
BEGIN
    SELECT state INTO STRICT experiment_state FROM strategy_training.training_experiments
    WHERE experiment_id = p_experiment_id FOR UPDATE;
    IF experiment_state <> 'DRAFT' OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
        WHERE binding.experiment_id = p_experiment_id
          AND binding.config_type = 'RETENTION_POLICY'
          AND binding.config_version_id = p_retention_policy_version_id
          AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'L2 retention plan requires a DRAFT experiment and bound READY policy'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_l2_retention_plans (
        retention_plan_id, experiment_id, retention_policy_version_id,
        selection_rule, maximum_detail_rows, plan_hash
    ) VALUES (new_id, p_experiment_id, p_retention_policy_version_id,
              p_selection_rule, p_maximum_detail_rows,
              encode(public.digest(concat_ws('|', p_retention_policy_version_id::text,
                  p_selection_rule::text, p_maximum_detail_rows::text), 'sha256'), 'hex'));
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_archive_manifest(
    p_retention_plan_id uuid, p_iteration_id uuid, p_artifact_kind text,
    p_storage_uri_hash char(64), p_row_count bigint,
    p_minimum_observed_at timestamptz, p_maximum_observed_at timestamptz,
    p_object_size_bytes bigint, p_content_sha256 char(64)
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE new_id uuid := gen_random_uuid(); plan_experiment_id uuid; iteration_experiment_id uuid;
BEGIN
    SELECT experiment_id INTO STRICT plan_experiment_id
    FROM strategy_training.training_l2_retention_plans
    WHERE retention_plan_id = p_retention_plan_id;
    SELECT experiment_id INTO STRICT iteration_experiment_id
    FROM strategy_training.training_iterations WHERE iteration_id = p_iteration_id;
    IF plan_experiment_id <> iteration_experiment_id OR EXISTS (
        SELECT 1 FROM strategy_training.training_iteration_summaries_l1
        WHERE iteration_id = p_iteration_id AND consistency_status = 'MISMATCH'
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iteration_summaries_l1
        WHERE iteration_id = p_iteration_id AND consistency_status = 'MATCH'
    ) THEN
        RAISE EXCEPTION 'archive requires matching experiment and consistent L1 evidence'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_archive_manifests (
        archive_manifest_id, retention_plan_id, iteration_id, artifact_kind,
        storage_uri_hash, archive_format, compression, row_count,
        minimum_observed_at, maximum_observed_at, object_size_bytes, content_sha256
    ) VALUES (new_id, p_retention_plan_id, p_iteration_id, p_artifact_kind,
              p_storage_uri_hash, 'PARQUET', 'ZSTD', p_row_count,
              p_minimum_observed_at, p_maximum_observed_at,
              p_object_size_bytes, p_content_sha256);
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.verify_training_archive_restore(
    p_archive_manifest_id uuid, p_restored_row_count bigint,
    p_restored_minimum_at timestamptz, p_restored_maximum_at timestamptz,
    p_restored_size_bytes bigint, p_restored_sha256 char(64)
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE manifest strategy_training.training_archive_manifests%ROWTYPE; matches boolean;
BEGIN
    SELECT * INTO STRICT manifest FROM strategy_training.training_archive_manifests
    WHERE archive_manifest_id = p_archive_manifest_id FOR UPDATE;
    IF manifest.state <> 'STORED' THEN
        RAISE EXCEPTION 'archive restore can only be checked once' USING ERRCODE = '55000';
    END IF;
    matches := p_restored_row_count = manifest.row_count
        AND p_restored_minimum_at = manifest.minimum_observed_at
        AND p_restored_maximum_at = manifest.maximum_observed_at
        AND p_restored_size_bytes = manifest.object_size_bytes
        AND p_restored_sha256 = manifest.content_sha256;
    INSERT INTO strategy_training.training_archive_restore_log (
        archive_manifest_id, restored_row_count, restored_minimum_at,
        restored_maximum_at, restored_size_bytes, restored_sha256, result
    ) VALUES (p_archive_manifest_id, p_restored_row_count, p_restored_minimum_at,
              p_restored_maximum_at, p_restored_size_bytes, p_restored_sha256,
              CASE WHEN matches THEN 'MATCH' ELSE 'MISMATCH' END);
    UPDATE strategy_training.training_archive_manifests
    SET state = CASE WHEN matches THEN 'VERIFIED' ELSE 'FAILED' END,
        restored_sha256 = CASE WHEN matches THEN p_restored_sha256 ELSE NULL END,
        restore_failure_code = CASE WHEN matches THEN NULL ELSE 'RESTORE_MISMATCH' END,
        verified_at = clock_timestamp()
    WHERE archive_manifest_id = p_archive_manifest_id;
    RETURN matches;
END
$$;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'training_task_events', 'training_task_checkpoints',
        'training_task_resource_admissions', 'training_iteration_evidence_l0',
        'training_iteration_summaries_l1', 'training_l2_retention_plans',
        'training_archive_restore_log'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%I_append_only BEFORE UPDATE OR DELETE ON strategy_training.%I '
            'FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation()',
            table_name, table_name
        );
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_tasks OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_task_events OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_task_checkpoints OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_task_resource_admissions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_iteration_evidence_l0 OWNER TO tb2_training_owner;
ALTER VIEW strategy_training.optimizer_train_objectives OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_iteration_summaries_l1 OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_l2_retention_plans OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_archive_manifests OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_archive_restore_log OWNER TO tb2_training_owner;

ALTER FUNCTION strategy_training.enqueue_training_task(uuid, uuid, uuid, uuid, text, text, char(64), jsonb, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.claim_training_task_internal(text, text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.claim_training_worker_task(text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.claim_training_optimizer_task(text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.claim_training_evaluator_task(text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.claim_training_model_b_task(text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.start_training_task(uuid, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.heartbeat_training_task(uuid, uuid, text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.pause_training_task(uuid, uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.resume_training_task(uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_task_checkpoint(uuid, uuid, text, integer, char(64), char(64), jsonb) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.request_training_task_cancellation(uuid, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.complete_training_task(uuid, uuid, text, text, char(64), text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_iteration_l0(uuid, text, uuid, text, boolean, jsonb, numeric, jsonb, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_iteration_l1(uuid, text, bigint, char(64), char(64), char(64), text, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_l2_retention_plan(uuid, uuid, jsonb, bigint) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_archive_manifest(uuid, uuid, text, char(64), bigint, timestamptz, timestamptz, bigint, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.verify_training_archive_restore(uuid, bigint, timestamptz, timestamptz, bigint, char(64)) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    strategy_training.enqueue_training_task(uuid, uuid, uuid, uuid, text, text, char(64), jsonb, integer),
    strategy_training.request_training_task_cancellation(uuid, text),
    strategy_training.resume_training_task(uuid),
    strategy_training.create_training_l2_retention_plan(uuid, uuid, jsonb, bigint)
TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION strategy_training.claim_training_worker_task(text, integer)
TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.claim_training_optimizer_task(text, integer)
TO tb2_training_optimizer;
GRANT EXECUTE ON FUNCTION strategy_training.claim_training_evaluator_task(text, integer)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.claim_training_model_b_task(text, integer)
TO tb2_training_model_b;

GRANT EXECUTE ON FUNCTION
    strategy_training.start_training_task(uuid, uuid, text),
    strategy_training.heartbeat_training_task(uuid, uuid, text, integer),
    strategy_training.pause_training_task(uuid, uuid, text),
    strategy_training.record_training_task_checkpoint(uuid, uuid, text, integer, char(64), char(64), jsonb),
    strategy_training.complete_training_task(uuid, uuid, text, text, char(64), text)
TO tb2_training_rw, tb2_training_optimizer, tb2_training_evaluator, tb2_training_model_b;

GRANT SELECT ON strategy_training.optimizer_train_objectives TO tb2_training_optimizer;
GRANT EXECUTE ON FUNCTION
    strategy_training.record_training_iteration_l0(uuid, text, uuid, text, boolean, jsonb, numeric, jsonb, char(64)),
    strategy_training.record_training_iteration_l1(uuid, text, bigint, char(64), char(64), char(64), text, text),
    strategy_training.record_training_archive_manifest(uuid, uuid, text, char(64), bigint, timestamptz, timestamptz, bigint, char(64)),
    strategy_training.verify_training_archive_restore(uuid, bigint, timestamptz, timestamptz, bigint, char(64))
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '031_training_orchestration_governance',
    encode(digest('auto_trade_v2_031_training_orchestration_governance_v1', 'sha256'), 'hex'),
    'Add leased orchestration, resource admission, TRAIN-only objectives and L0/L1/L2 archive governance'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
