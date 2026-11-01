\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

GRANT USAGE ON SCHEMA core TO tb2_training_owner;
GRANT SELECT ON core.app_users,
    core.app_user_training_roles,
    core.app_user_training_role_revocations
TO tb2_training_owner;

CREATE OR REPLACE FUNCTION strategy_training.assert_transition_actor(
    p_actor_user_id uuid,
    p_actor_service text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
BEGIN
    IF (p_actor_user_id IS NULL) = (p_actor_service IS NULL) THEN
        RAISE EXCEPTION 'exactly one actor_user_id or actor_service is required'
            USING ERRCODE = '22023';
    END IF;
    IF p_actor_service IS NOT NULL AND btrim(p_actor_service) = '' THEN
        RAISE EXCEPTION 'actor_service cannot be blank' USING ERRCODE = '22023';
    END IF;
    IF p_actor_user_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM core.app_users WHERE user_id = p_actor_user_id
    ) THEN
        RAISE EXCEPTION 'actor user does not exist' USING ERRCODE = '23503';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.write_state_transition(
    p_object_type text,
    p_object_id uuid,
    p_old_state text,
    p_new_state text,
    p_actor_user_id uuid,
    p_actor_service text,
    p_reason text,
    p_request_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, p_actor_service);
    IF p_request_id IS NULL OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'request_id and non-blank transition reason are required'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO strategy_training.training_state_transition_log (
        object_type, object_id, old_state, new_state,
        actor_user_id, actor_service, reason, request_id
    ) VALUES (
        p_object_type, p_object_id, p_old_state, p_new_state,
        p_actor_user_id, p_actor_service, p_reason, p_request_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.assert_active_training_role(
    p_user_id uuid,
    p_training_role text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM core.app_user_training_roles role_grant
        WHERE role_grant.user_id = p_user_id
          AND role_grant.training_role = p_training_role
          AND role_grant.valid_from <= clock_timestamp()
          AND role_grant.expires_at > clock_timestamp()
          AND NOT EXISTS (
              SELECT 1 FROM core.app_user_training_role_revocations revocation
              WHERE revocation.grant_id = role_grant.grant_id
          )
    ) THEN
        RAISE EXCEPTION 'user lacks active % role', p_training_role
            USING ERRCODE = '42501';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.transition_training_config(
    p_config_version_id uuid,
    p_expected_state text,
    p_new_state text,
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
    current_state text;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_ADMIN'
    );
    SELECT status INTO STRICT current_state
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_config_version_id
    FOR UPDATE;

    IF current_state <> p_expected_state THEN
        RAISE EXCEPTION 'config state conflict: expected %, found %',
            p_expected_state, current_state USING ERRCODE = '40001';
    END IF;
    IF NOT (
        (current_state = 'DRAFT' AND p_new_state = 'READY')
        OR (current_state = 'READY' AND p_new_state = 'RETIRED')
    ) THEN
        RAISE EXCEPTION 'invalid config transition % -> %', current_state, p_new_state
            USING ERRCODE = '23514';
    END IF;

    IF p_new_state = 'READY' THEN
        UPDATE strategy_training.training_config_versions
        SET status = 'READY', ready_by_user_id = p_actor_user_id,
            ready_at = clock_timestamp()
        WHERE config_version_id = p_config_version_id;
    ELSE
        UPDATE strategy_training.training_config_versions
        SET status = 'RETIRED', retired_by_user_id = p_actor_user_id,
            retired_at = clock_timestamp()
        WHERE config_version_id = p_config_version_id;
    END IF;

    PERFORM strategy_training.write_state_transition(
        'CONFIG', p_config_version_id, current_state, p_new_state,
        p_actor_user_id, NULL, p_reason, p_request_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.transition_training_dataset(
    p_dataset_version_id uuid,
    p_expected_state text,
    p_new_state text,
    p_actor_user_id uuid,
    p_actor_service text,
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
    current_state text;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, p_actor_service);
    SELECT status INTO STRICT current_state
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = p_dataset_version_id
    FOR UPDATE;

    IF current_state <> p_expected_state THEN
        RAISE EXCEPTION 'dataset state conflict: expected %, found %',
            p_expected_state, current_state USING ERRCODE = '40001';
    END IF;
    IF NOT (
        (current_state = 'BUILDING' AND p_new_state IN ('READY', 'INVALID'))
        OR (current_state = 'READY' AND p_new_state = 'STALE')
        OR (current_state = 'STALE' AND p_new_state IN ('SUPERSEDED', 'ARCHIVED'))
    ) THEN
        RAISE EXCEPTION 'invalid dataset transition % -> %', current_state, p_new_state
            USING ERRCODE = '23514';
    END IF;

    UPDATE strategy_training.training_dataset_versions
    SET status = p_new_state,
        ready_at = CASE WHEN p_new_state = 'READY' THEN clock_timestamp() ELSE ready_at END,
        invalid_at = CASE WHEN p_new_state = 'INVALID' THEN clock_timestamp() ELSE invalid_at END,
        stale_at = CASE WHEN p_new_state = 'STALE' THEN clock_timestamp() ELSE stale_at END,
        stale_reason = CASE WHEN p_new_state = 'STALE' THEN p_reason ELSE stale_reason END,
        superseded_at = CASE
            WHEN p_new_state = 'SUPERSEDED' THEN clock_timestamp() ELSE superseded_at END,
        archived_at = CASE WHEN p_new_state = 'ARCHIVED' THEN clock_timestamp() ELSE archived_at END
    WHERE dataset_version_id = p_dataset_version_id;

    PERFORM strategy_training.write_state_transition(
        'DATASET', p_dataset_version_id, current_state, p_new_state,
        p_actor_user_id, p_actor_service, p_reason, p_request_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_experiment(
    p_experiment_mode text,
    p_parent_experiment_id uuid,
    p_dataset_version_id uuid,
    p_resource_limit_config_version_id uuid,
    p_experiment_name text,
    p_exposure_identity_hash char(64),
    p_created_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_created_by_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_created_by_user_id, 'TRAINING_ADMIN'
    );
    INSERT INTO strategy_training.training_experiments (
        experiment_id, experiment_mode, parent_experiment_id, dataset_version_id,
        resource_limit_config_version_id, experiment_name,
        exposure_identity_hash, created_by_user_id
    ) VALUES (
        new_id, p_experiment_mode, p_parent_experiment_id, p_dataset_version_id,
        p_resource_limit_config_version_id, p_experiment_name,
        p_exposure_identity_hash, p_created_by_user_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.bind_training_experiment_config(
    p_experiment_id uuid,
    p_config_type text,
    p_config_version_id uuid
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    ) VALUES (p_experiment_id, p_config_type, p_config_version_id)
$$;

CREATE OR REPLACE FUNCTION strategy_training.transition_training_experiment(
    p_experiment_id uuid,
    p_expected_state text,
    p_new_state text,
    p_actor_user_id uuid,
    p_actor_service text,
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
    current_state text;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, p_actor_service);
    SELECT state INTO STRICT current_state
    FROM strategy_training.training_experiments
    WHERE experiment_id = p_experiment_id
    FOR UPDATE;

    IF current_state <> p_expected_state THEN
        RAISE EXCEPTION 'experiment state conflict: expected %, found %',
            p_expected_state, current_state USING ERRCODE = '40001';
    END IF;
    IF NOT (
        (current_state = 'DRAFT' AND p_new_state = 'RUNNING')
        OR (current_state = 'RUNNING' AND p_new_state IN ('PAUSED', 'STOPPED'))
        OR (current_state = 'PAUSED' AND p_new_state IN ('RUNNING', 'STOPPED'))
    ) THEN
        RAISE EXCEPTION 'invalid experiment transition % -> %', current_state, p_new_state
            USING ERRCODE = '23514';
    END IF;

    IF current_state = 'DRAFT' AND NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_experiment_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
        WHERE binding.experiment_id = p_experiment_id
          AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'experiment requires at least one READY bound config before RUNNING'
            USING ERRCODE = '23514';
    END IF;

    UPDATE strategy_training.training_experiments
    SET state = p_new_state,
        started_at = CASE
            WHEN p_new_state = 'RUNNING' AND started_at IS NULL
            THEN clock_timestamp() ELSE started_at END,
        paused_at = CASE WHEN p_new_state = 'PAUSED' THEN clock_timestamp() ELSE paused_at END,
        stopped_at = CASE WHEN p_new_state = 'STOPPED' THEN clock_timestamp() ELSE stopped_at END,
        stop_reason = CASE WHEN p_new_state = 'STOPPED' THEN p_reason ELSE NULL END
    WHERE experiment_id = p_experiment_id;

    PERFORM strategy_training.write_state_transition(
        'EXPERIMENT', p_experiment_id, current_state, p_new_state,
        p_actor_user_id, p_actor_service, p_reason, p_request_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_iteration(
    p_experiment_id uuid,
    p_candidate_version integer,
    p_parent_iteration_id uuid,
    p_candidate_source text,
    p_random_seed bigint,
    p_candidate_parameters jsonb,
    p_resource_budget jsonb,
    p_retry_of_iteration_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_iterations (
        iteration_id, experiment_id, candidate_version, parent_iteration_id,
        candidate_source, random_seed, candidate_parameters, candidate_content_hash,
        resource_budget, retry_of_iteration_id
    ) VALUES (
        new_id, p_experiment_id, p_candidate_version, p_parent_iteration_id,
        p_candidate_source, p_random_seed, p_candidate_parameters,
        encode(public.digest(p_candidate_parameters::text, 'sha256'), 'hex'),
        p_resource_budget, p_retry_of_iteration_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.transition_training_iteration(
    p_iteration_id uuid,
    p_expected_state text,
    p_new_state text,
    p_rejection_code text,
    p_failure_detail_hash char(64),
    p_actor_user_id uuid,
    p_actor_service text,
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
    current_state text;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, p_actor_service);
    SELECT state INTO STRICT current_state
    FROM strategy_training.training_iterations
    WHERE iteration_id = p_iteration_id
    FOR UPDATE;

    IF current_state <> p_expected_state THEN
        RAISE EXCEPTION 'iteration state conflict: expected %, found %',
            p_expected_state, current_state USING ERRCODE = '40001';
    END IF;
    IF NOT (
        (current_state = 'CREATED' AND p_new_state IN ('VALIDATING', 'CANCELLED'))
        OR (current_state = 'VALIDATING'
            AND p_new_state IN ('RUNNING', 'FAILED', 'REJECTED', 'CANCELLED'))
        OR (current_state = 'RUNNING'
            AND p_new_state IN ('SUCCEEDED', 'FAILED', 'CANCELLED'))
    ) THEN
        RAISE EXCEPTION 'invalid iteration transition % -> %', current_state, p_new_state
            USING ERRCODE = '23514';
    END IF;
    IF p_new_state IN ('FAILED', 'REJECTED', 'CANCELLED')
       AND (p_rejection_code IS NULL OR btrim(p_rejection_code) = '') THEN
        RAISE EXCEPTION 'terminal failure state requires rejection_code'
            USING ERRCODE = '22023';
    END IF;
    IF p_new_state IN ('VALIDATING', 'RUNNING', 'SUCCEEDED')
       AND p_rejection_code IS NOT NULL THEN
        RAISE EXCEPTION 'non-failure state cannot carry rejection_code'
            USING ERRCODE = '22023';
    END IF;

    UPDATE strategy_training.training_iterations
    SET state = p_new_state,
        validation_started_at = CASE
            WHEN p_new_state = 'VALIDATING' THEN clock_timestamp()
            ELSE validation_started_at END,
        run_started_at = CASE
            WHEN p_new_state = 'RUNNING' THEN clock_timestamp() ELSE run_started_at END,
        completed_at = CASE
            WHEN p_new_state IN ('SUCCEEDED', 'FAILED', 'REJECTED', 'CANCELLED')
            THEN clock_timestamp() ELSE completed_at END,
        rejection_code = p_rejection_code,
        failure_detail_hash = p_failure_detail_hash
    WHERE iteration_id = p_iteration_id;

    PERFORM strategy_training.write_state_transition(
        'ITERATION', p_iteration_id, current_state, p_new_state,
        p_actor_user_id, p_actor_service, p_reason, p_request_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_optimizer_run(
    p_experiment_id uuid,
    p_optimizer_kind text,
    p_search_space_config_version_id uuid,
    p_trial_budget integer,
    p_random_seed bigint,
    p_worker_identity text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_optimizer_runs (
        optimizer_run_id, experiment_id, optimizer_kind,
        search_space_config_version_id, trial_budget, random_seed, worker_identity
    ) VALUES (
        new_id, p_experiment_id, p_optimizer_kind,
        p_search_space_config_version_id, p_trial_budget, p_random_seed, p_worker_identity
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.transition_training_optimizer_run(
    p_optimizer_run_id uuid,
    p_expected_state text,
    p_new_state text,
    p_failure_code text,
    p_actor_user_id uuid,
    p_actor_service text,
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
    current_state text;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_actor_user_id, p_actor_service);
    SELECT state INTO STRICT current_state
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_optimizer_run_id
    FOR UPDATE;

    IF current_state <> p_expected_state THEN
        RAISE EXCEPTION 'optimizer run state conflict: expected %, found %',
            p_expected_state, current_state USING ERRCODE = '40001';
    END IF;
    IF NOT (
        (current_state = 'CREATED' AND p_new_state IN ('RUNNING', 'CANCELLED'))
        OR (current_state = 'RUNNING'
            AND p_new_state IN ('PAUSED', 'SUCCEEDED', 'FAILED', 'CANCELLED'))
        OR (current_state = 'PAUSED' AND p_new_state IN ('RUNNING', 'CANCELLED'))
    ) THEN
        RAISE EXCEPTION 'invalid optimizer transition % -> %', current_state, p_new_state
            USING ERRCODE = '23514';
    END IF;
    IF p_new_state IN ('FAILED', 'CANCELLED')
       AND (p_failure_code IS NULL OR btrim(p_failure_code) = '') THEN
        RAISE EXCEPTION 'failed optimizer state requires failure_code'
            USING ERRCODE = '22023';
    END IF;

    UPDATE strategy_training.training_optimizer_runs
    SET state = p_new_state,
        started_at = CASE
            WHEN p_new_state = 'RUNNING' AND started_at IS NULL
            THEN clock_timestamp() ELSE started_at END,
        ended_at = CASE
            WHEN p_new_state IN ('SUCCEEDED', 'FAILED', 'CANCELLED')
            THEN clock_timestamp() ELSE ended_at END,
        failure_code = CASE
            WHEN p_new_state IN ('FAILED', 'CANCELLED') THEN p_failure_code ELSE NULL END
    WHERE optimizer_run_id = p_optimizer_run_id;

    PERFORM strategy_training.write_state_transition(
        'OPTIMIZER_RUN', p_optimizer_run_id, current_state, p_new_state,
        p_actor_user_id, p_actor_service, p_reason, p_request_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_optimizer_checkpoint(
    p_optimizer_run_id uuid,
    p_trial_number integer,
    p_study_state_hash char(64),
    p_checkpoint_uri_hash char(64),
    p_completed_trial_count integer,
    p_failed_trial_count integer
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_optimizer_checkpoints (
        optimizer_checkpoint_id, optimizer_run_id, trial_number, study_state_hash,
        checkpoint_uri_hash, completed_trial_count, failed_trial_count
    ) VALUES (
        new_id, p_optimizer_run_id, p_trial_number, p_study_state_hash,
        p_checkpoint_uri_hash, p_completed_trial_count, p_failed_trial_count
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.freeze_training_final_candidate(
    p_experiment_id uuid,
    p_iteration_id uuid,
    p_freeze_manifest_hash char(64),
    p_frozen_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    candidate_hash char(64);
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_frozen_by_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_frozen_by_user_id, 'TRAINING_ADMIN'
    );
    SELECT candidate_content_hash INTO STRICT candidate_hash
    FROM strategy_training.training_iterations
    WHERE iteration_id = p_iteration_id AND experiment_id = p_experiment_id;

    INSERT INTO strategy_training.training_final_candidate_freezes (
        final_candidate_freeze_id, experiment_id, iteration_id,
        candidate_content_hash, freeze_manifest_hash, frozen_by_user_id
    ) VALUES (
        new_id, p_experiment_id, p_iteration_id,
        candidate_hash, p_freeze_manifest_hash, p_frozen_by_user_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_validation_scope(
    p_partition_start_at timestamptz,
    p_partition_end_at timestamptz,
    p_ticker_pool_rule_version_id uuid,
    p_validation_protocol_version_id uuid,
    p_max_evaluation_count integer,
    p_alpha_total numeric,
    p_model_a_max_evaluation_count integer,
    p_model_a_alpha_total numeric,
    p_model_b_max_evaluation_count integer,
    p_model_b_alpha_total numeric,
    p_created_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_created_by_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_created_by_user_id, 'TRAINING_ADMIN'
    );
    INSERT INTO strategy_training.training_validation_scopes (
        validation_scope_id, scope_hash, partition_start_at, partition_end_at,
        ticker_pool_rule_version_id, validation_protocol_version_id,
        max_evaluation_count, alpha_total,
        model_a_max_evaluation_count, model_a_alpha_total,
        model_b_max_evaluation_count, model_b_alpha_total, created_by_user_id
    ) VALUES (
        new_id,
        strategy_training.compute_validation_scope_hash(
            p_partition_start_at, p_partition_end_at, p_ticker_pool_rule_version_id
        ),
        p_partition_start_at, p_partition_end_at,
        p_ticker_pool_rule_version_id, p_validation_protocol_version_id,
        p_max_evaluation_count, p_alpha_total,
        p_model_a_max_evaluation_count, p_model_a_alpha_total,
        p_model_b_max_evaluation_count, p_model_b_alpha_total, p_created_by_user_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.reserve_training_validation_budget(
    p_validation_scope_id uuid,
    p_final_candidate_freeze_id uuid,
    p_model_family text,
    p_alpha_reserved numeric,
    p_reservation_request_id uuid,
    p_reserved_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    scope_record strategy_training.training_validation_scopes%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_transition_actor(p_reserved_by_user_id, NULL);
    PERFORM strategy_training.assert_active_training_role(
        p_reserved_by_user_id, 'TRAINING_ADMIN'
    );
    INSERT INTO strategy_training.training_validation_reservations (
        validation_reservation_id, validation_scope_id, final_candidate_freeze_id,
        model_family, evaluation_count, alpha_reserved,
        reservation_request_id, reserved_by_user_id
    ) VALUES (
        new_id, p_validation_scope_id, p_final_candidate_freeze_id,
        p_model_family, 1, p_alpha_reserved,
        p_reservation_request_id, p_reserved_by_user_id
    );

    SELECT * INTO STRICT scope_record
    FROM strategy_training.training_validation_scopes
    WHERE validation_scope_id = p_validation_scope_id;
    IF scope_record.reserved_evaluation_count = scope_record.max_evaluation_count
       OR scope_record.reserved_alpha = scope_record.alpha_total THEN
        UPDATE strategy_training.training_validation_scopes
        SET state = 'EXHAUSTED'
        WHERE validation_scope_id = p_validation_scope_id;
        PERFORM strategy_training.write_state_transition(
            'VALIDATION_SCOPE', p_validation_scope_id, 'OPEN', 'EXHAUSTED',
            p_reserved_by_user_id, NULL, 'validation budget exhausted',
            p_reservation_request_id
        );
    END IF;
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_validation_evaluation(
    p_validation_reservation_id uuid,
    p_alpha_used numeric,
    p_confidence_interval jsonb,
    p_correction_result jsonb,
    p_result_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    reservation_record strategy_training.training_validation_reservations%ROWTYPE;
    freeze_experiment_id uuid;
BEGIN
    SELECT * INTO STRICT reservation_record
    FROM strategy_training.training_validation_reservations
    WHERE validation_reservation_id = p_validation_reservation_id;
    SELECT experiment_id INTO STRICT freeze_experiment_id
    FROM strategy_training.training_final_candidate_freezes
    WHERE final_candidate_freeze_id = reservation_record.final_candidate_freeze_id;

    INSERT INTO strategy_training.training_validation_evaluations (
        validation_evaluation_id, validation_reservation_id, validation_scope_id,
        experiment_id, final_candidate_freeze_id, alpha_used,
        confidence_interval, correction_result, result_hash
    ) VALUES (
        new_id, p_validation_reservation_id, reservation_record.validation_scope_id,
        freeze_experiment_id, reservation_record.final_candidate_freeze_id, p_alpha_used,
        p_confidence_interval, p_correction_result, p_result_hash
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_iteration_metric(
    p_iteration_id uuid,
    p_partition text,
    p_validation_evaluation_id uuid,
    p_metric_name text,
    p_metric_value numeric,
    p_sample_count bigint,
    p_effective_independent_day_count numeric,
    p_calculation_version text,
    p_evidence_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
BEGIN
    INSERT INTO strategy_training.training_iteration_metrics (
        iteration_metric_id, iteration_id, partition, validation_evaluation_id,
        metric_name, metric_value, sample_count, effective_independent_day_count,
        calculation_version, evidence_hash
    ) VALUES (
        new_id, p_iteration_id, p_partition, p_validation_evaluation_id,
        p_metric_name, p_metric_value, p_sample_count,
        p_effective_independent_day_count, p_calculation_version, p_evidence_hash
    );
    RETURN new_id;
END
$$;

ALTER FUNCTION strategy_training.assert_transition_actor(uuid, text)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.write_state_transition(
    text, uuid, text, text, uuid, text, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.assert_active_training_role(uuid, text)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.transition_training_config(
    uuid, text, text, uuid, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.transition_training_dataset(
    uuid, text, text, uuid, text, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_experiment(
    text, uuid, uuid, uuid, text, char(64), uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.bind_training_experiment_config(uuid, text, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.transition_training_experiment(
    uuid, text, text, uuid, text, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_iteration(
    uuid, integer, uuid, text, bigint, jsonb, jsonb, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.transition_training_iteration(
    uuid, text, text, text, char(64), uuid, text, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_optimizer_run(
    uuid, text, uuid, integer, bigint, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.transition_training_optimizer_run(
    uuid, text, text, text, uuid, text, text, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_optimizer_checkpoint(
    uuid, integer, char(64), char(64), integer, integer
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.freeze_training_final_candidate(uuid, uuid, char(64), uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_validation_scope(
    timestamptz, timestamptz, uuid, uuid, integer, numeric,
    integer, numeric, integer, numeric, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.reserve_training_validation_budget(
    uuid, uuid, text, numeric, uuid, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_validation_evaluation(
    uuid, numeric, jsonb, jsonb, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_iteration_metric(
    uuid, text, uuid, text, numeric, bigint, numeric, text, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    strategy_training.transition_training_config(uuid, text, text, uuid, text, uuid),
    strategy_training.transition_training_dataset(uuid, text, text, uuid, text, text, uuid),
    strategy_training.create_training_experiment(text, uuid, uuid, uuid, text, char(64), uuid),
    strategy_training.bind_training_experiment_config(uuid, text, uuid),
    strategy_training.transition_training_experiment(uuid, text, text, uuid, text, text, uuid),
    strategy_training.create_training_iteration(uuid, integer, uuid, text, bigint, jsonb, jsonb, uuid),
    strategy_training.transition_training_iteration(
        uuid, text, text, text, char(64), uuid, text, text, uuid
    ),
    strategy_training.create_training_optimizer_run(uuid, text, uuid, integer, bigint, text),
    strategy_training.transition_training_optimizer_run(
        uuid, text, text, text, uuid, text, text, uuid
    ),
    strategy_training.record_optimizer_checkpoint(
        uuid, integer, char(64), char(64), integer, integer
    ),
    strategy_training.freeze_training_final_candidate(uuid, uuid, char(64), uuid),
    strategy_training.create_training_validation_scope(
        timestamptz, timestamptz, uuid, uuid, integer, numeric,
        integer, numeric, integer, numeric, uuid
    ),
    strategy_training.reserve_training_validation_budget(uuid, uuid, text, numeric, uuid, uuid)
TO tb2_training_orchestrator;

GRANT EXECUTE ON FUNCTION
    strategy_training.record_training_validation_evaluation(
        uuid, numeric, jsonb, jsonb, char(64)
    ),
    strategy_training.record_training_iteration_metric(
        uuid, text, uuid, text, numeric, bigint, numeric, text, char(64)
    )
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '022_training_controlled_procedures',
    encode(digest('auto_trade_v2_022_training_controlled_procedures_v1', 'sha256'), 'hex'),
    'Add audited training state transitions and least-privilege controlled write procedures'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
