\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_cross_fit_reference_remediations (
    previous_cross_fit_execution_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_cross_fit_executions,
    previous_experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    replacement_experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    replacement_cross_fit_execution_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_cross_fit_executions,
    previous_random_baseline_config_version_id uuid NOT NULL
        REFERENCES strategy_training.training_config_versions,
    replacement_random_baseline_config_version_id uuid NOT NULL
        REFERENCES strategy_training.training_config_versions,
    source_reference_set_id uuid NOT NULL
        REFERENCES strategy_training.training_random_baseline_reference_sets,
    replacement_reference_set_id uuid NOT NULL
        REFERENCES strategy_training.training_random_baseline_reference_sets,
    actor_user_id uuid NOT NULL REFERENCES core.app_users,
    reason_code varchar(64) NOT NULL CHECK (
        reason_code = 'RANDOM_BASELINE_REFERENCE_PATH_INCOMPLETE'
    ),
    cancelled_task_count integer NOT NULL CHECK (cancelled_task_count > 0),
    failed_evaluation_count integer NOT NULL CHECK (failed_evaluation_count > 0),
    config_manifest_hash char(64) NOT NULL
        CHECK (config_manifest_hash ~ '^[0-9a-f]{64}$'),
    remediation_evidence_hash char(64) NOT NULL
        CHECK (remediation_evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TRIGGER trg_training_cross_fit_reference_remediations_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_cross_fit_reference_remediations
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.restart_cross_fit_after_reference_remediation(
    p_previous_cross_fit_execution_id uuid,
    p_replacement_random_baseline_config_version_id uuid,
    p_actor_user_id uuid
)
RETURNS TABLE (
    replacement_experiment_id uuid,
    replacement_cross_fit_execution_id uuid,
    remediation_evidence_hash char(64)
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $function$
DECLARE
    execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    previous_config strategy_training.training_config_versions%ROWTYPE;
    replacement_config strategy_training.training_config_versions%ROWTYPE;
    source_reference strategy_training.training_random_baseline_reference_sets%ROWTYPE;
    replacement_reference strategy_training.training_random_baseline_reference_sets%ROWTYPE;
    existing_record strategy_training.training_cross_fit_reference_remediations%ROWTYPE;
    task_record strategy_training.training_tasks%ROWTYPE;
    iteration_record strategy_training.training_iterations%ROWTYPE;
    optimizer_record strategy_training.training_optimizer_runs%ROWTYPE;
    new_experiment_id uuid;
    new_execution_id uuid;
    failed_evaluations integer;
    cancelled_tasks integer := 0;
    bound_count integer;
    config_manifest char(64);
    evidence_hash char(64);
BEGIN
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_ADMIN'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_previous_cross_fit_execution_id::text, 103)
    );

    SELECT * INTO existing_record
    FROM strategy_training.training_cross_fit_reference_remediations remediation
    WHERE remediation.previous_cross_fit_execution_id =
          p_previous_cross_fit_execution_id;
    IF FOUND THEN
        RETURN QUERY SELECT existing_record.replacement_experiment_id,
            existing_record.replacement_cross_fit_execution_id,
            existing_record.remediation_evidence_hash;
        RETURN;
    END IF;

    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions execution
    WHERE execution.cross_fit_execution_id = p_previous_cross_fit_execution_id
    FOR UPDATE;
    SELECT * INTO STRICT experiment_record
    FROM strategy_training.training_experiments experiment
    WHERE experiment.experiment_id = execution_record.experiment_id
    FOR UPDATE;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = execution_record.dataset_version_id
    FOR SHARE;
    SELECT config.* INTO STRICT previous_config
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'RANDOM_BASELINE';
    SELECT * INTO STRICT replacement_config
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id =
          p_replacement_random_baseline_config_version_id
      AND config.config_type = 'RANDOM_BASELINE'
      AND config.status = 'READY';
    SELECT * INTO STRICT source_reference
    FROM strategy_training.training_random_baseline_reference_sets reference_set
    WHERE reference_set.reference_set_id =
          (previous_config.config_json ->> 'reference_set_id')::uuid;
    SELECT * INTO STRICT replacement_reference
    FROM strategy_training.training_random_baseline_reference_sets reference_set
    WHERE reference_set.reference_set_id =
          (replacement_config.config_json ->> 'reference_set_id')::uuid;

    SELECT count(*) INTO failed_evaluations
    FROM strategy_training.training_tasks task
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = task.iteration_id
    WHERE task.experiment_id = experiment_record.experiment_id
      AND task.task_type = 'MODEL_A_EVALUATION'
      AND task.state = 'FAILED'
      AND task.failure_code = 'MODEL_A_EVALUATION_REJECTED'
      AND iteration.state = 'FAILED'
      AND iteration.rejection_code = 'MODEL_A_EVALUATION_FAILED';

    IF execution_record.state <> 'RUNNING'
       OR experiment_record.state <> 'RUNNING'
       OR dataset_record.status <> 'READY'
       OR dataset_record.partition <> 'TRAIN'
       OR failed_evaluations = 0
       OR previous_config.status <> 'READY'
       OR replacement_config.parent_version_id IS DISTINCT FROM
          previous_config.config_version_id
       OR previous_config.config_json - 'reference_set_id'
          <> replacement_config.config_json - 'reference_set_id'
       OR source_reference.candidate_path_policy <> 'LEGACY_UNFILTERED'
       OR replacement_reference.candidate_path_policy <>
          'COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF'
       OR replacement_reference.source_reference_set_id IS DISTINCT FROM
          source_reference.reference_set_id
       OR EXISTS (
           SELECT 1
           FROM strategy_training.training_tasks task
           WHERE task.experiment_id = experiment_record.experiment_id
             AND task.state IN ('LEASED', 'RUNNING')
             AND task.lease_expires_at >= clock_timestamp()
       ) THEN
        RAISE EXCEPTION 'execution is not an idle verified reference-path failure'
            USING ERRCODE = '23514';
    END IF;

    FOR task_record IN
        SELECT *
        FROM strategy_training.training_tasks task
        WHERE task.experiment_id = experiment_record.experiment_id
          AND task.state IN ('QUEUED', 'LEASED', 'RUNNING', 'PAUSED')
        ORDER BY task.created_at, task.task_id
        FOR UPDATE
    LOOP
        UPDATE strategy_training.training_tasks
        SET state = 'CANCELLED',
            lease_token = NULL,
            leased_by = NULL,
            lease_expires_at = NULL,
            cancellation_requested_at = COALESCE(
                cancellation_requested_at, clock_timestamp()
            ),
            cancellation_reason = COALESCE(
                cancellation_reason,
                'superseded by audited random-baseline reference remediation'
            ),
            result_hash = NULL,
            failure_code = 'RANDOM_BASELINE_REFERENCE_REMEDIATED',
            completed_at = clock_timestamp()
        WHERE task_id = task_record.task_id;
        INSERT INTO strategy_training.training_task_events (
            task_id, attempt_number, old_state, new_state,
            worker_identity, reason_code, event_payload
        ) VALUES (
            task_record.task_id, task_record.attempt_count,
            task_record.state, 'CANCELLED', task_record.leased_by,
            'RANDOM_BASELINE_REFERENCE_REMEDIATED',
            jsonb_build_object(
                'previous_cross_fit_execution_id',
                    execution_record.cross_fit_execution_id,
                'replacement_random_baseline_config_version_id',
                    replacement_config.config_version_id
            )
        );
        cancelled_tasks := cancelled_tasks + 1;
    END LOOP;
    IF cancelled_tasks = 0 THEN
        RAISE EXCEPTION 'reference remediation requires unfinished tasks'
            USING ERRCODE = '23514';
    END IF;

    FOR iteration_record IN
        SELECT *
        FROM strategy_training.training_iterations iteration
        WHERE iteration.experiment_id = experiment_record.experiment_id
          AND iteration.state IN ('CREATED', 'VALIDATING', 'RUNNING')
        ORDER BY iteration.created_at, iteration.iteration_id
        FOR UPDATE
    LOOP
        PERFORM strategy_training.transition_training_iteration(
            iteration_record.iteration_id, iteration_record.state,
            'CANCELLED', 'RANDOM_BASELINE_REFERENCE_PATH_INCOMPLETE', NULL,
            p_actor_user_id, NULL,
            'cancel iteration after immutable reference path remediation',
            gen_random_uuid()
        );
    END LOOP;

    FOR optimizer_record IN
        SELECT run.*
        FROM strategy_training.training_optimizer_runs run
        WHERE run.experiment_id = experiment_record.experiment_id
          AND run.state IN ('CREATED', 'RUNNING', 'PAUSED')
        ORDER BY run.optimizer_run_id
        FOR UPDATE
    LOOP
        PERFORM strategy_training.transition_training_optimizer_run(
            optimizer_record.optimizer_run_id, optimizer_record.state,
            'CANCELLED', 'RANDOM_BASELINE_REFERENCE_PATH_INCOMPLETE',
            p_actor_user_id, NULL,
            'stop optimizer after immutable reference path remediation',
            gen_random_uuid()
        );
    END LOOP;

    UPDATE strategy_training.training_cross_fit_executions
    SET state = 'FAILED',
        failure_code = 'RANDOM_BASELINE_REFERENCE_PATH_INCOMPLETE',
        completed_at = clock_timestamp(),
        lease_token = NULL,
        leased_by = NULL,
        lease_expires_at = NULL
    WHERE cross_fit_execution_id = execution_record.cross_fit_execution_id;
    PERFORM strategy_training.transition_training_experiment(
        experiment_record.experiment_id, 'RUNNING', 'STOPPED',
        p_actor_user_id, NULL,
        'superseded after immutable random-baseline reference path remediation',
        gen_random_uuid()
    );

    new_experiment_id := strategy_training.create_training_experiment(
        'DISCOVERY', experiment_record.experiment_id,
        experiment_record.dataset_version_id,
        experiment_record.resource_limit_config_version_id,
        format('cross-fit-reference-retry-%s',
               execution_record.cross_fit_execution_id),
        encode(digest(concat_ws('|', experiment_record.exposure_identity_hash,
            execution_record.cross_fit_execution_id::text,
            replacement_config.content_hash,
            'RANDOM_BASELINE_REFERENCE_PATH_REMEDIATED'), 'sha256'), 'hex'),
        p_actor_user_id
    );
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    )
    SELECT new_experiment_id, binding.config_type, binding.config_version_id
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type <> 'RANDOM_BASELINE'
      AND config.status = 'READY';
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    ) VALUES (
        new_experiment_id, 'RANDOM_BASELINE',
        replacement_config.config_version_id
    );

    SELECT count(*) INTO bound_count
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.status = 'READY'
    WHERE binding.experiment_id = new_experiment_id;
    IF bound_count < 20 THEN
        RAISE EXCEPTION 'replacement Cross-fit experiment lost frozen configs'
            USING ERRCODE = '23514';
    END IF;

    SELECT encode(digest(string_agg(concat_ws('|', binding.config_type,
               config.content_hash), '' ORDER BY binding.config_type),
               'sha256'), 'hex')
    INTO STRICT config_manifest
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
    WHERE binding.experiment_id = new_experiment_id;
    PERFORM strategy_training.transition_training_experiment(
        new_experiment_id, 'DRAFT', 'RUNNING', p_actor_user_id, NULL,
        'start clean Cross-fit retry with complete-path random baseline',
        gen_random_uuid()
    );
    new_execution_id := strategy_training.create_cross_fit_execution(
        new_experiment_id, execution_record.protocol_config_version_id,
        execution_record.coverage_gate_status,
        execution_record.coverage_evidence_hash,
        execution_record.source_revision_watermark_hash,
        execution_record.question_readiness,
        execution_record.minimum_effective_folds,
        execution_record.minimum_effective_days,
        execution_record.minimum_event_count
    );
    evidence_hash := encode(digest(jsonb_build_object(
        'actor_user_id', p_actor_user_id,
        'cancelled_task_count', cancelled_tasks,
        'config_manifest_hash', config_manifest,
        'failed_evaluation_count', failed_evaluations,
        'previous_cross_fit_execution_id',
            execution_record.cross_fit_execution_id,
        'previous_experiment_id', experiment_record.experiment_id,
        'previous_random_baseline_config_version_id',
            previous_config.config_version_id,
        'reason_code', 'RANDOM_BASELINE_REFERENCE_PATH_INCOMPLETE',
        'replacement_cross_fit_execution_id', new_execution_id,
        'replacement_experiment_id', new_experiment_id,
        'replacement_random_baseline_config_version_id',
            replacement_config.config_version_id,
        'replacement_reference_set_id',
            replacement_reference.reference_set_id,
        'source_reference_set_id', source_reference.reference_set_id
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_cross_fit_reference_remediations (
        previous_cross_fit_execution_id, previous_experiment_id,
        replacement_experiment_id, replacement_cross_fit_execution_id,
        previous_random_baseline_config_version_id,
        replacement_random_baseline_config_version_id,
        source_reference_set_id, replacement_reference_set_id,
        actor_user_id, reason_code, cancelled_task_count,
        failed_evaluation_count, config_manifest_hash,
        remediation_evidence_hash
    ) VALUES (
        execution_record.cross_fit_execution_id,
        experiment_record.experiment_id, new_experiment_id, new_execution_id,
        previous_config.config_version_id, replacement_config.config_version_id,
        source_reference.reference_set_id, replacement_reference.reference_set_id,
        p_actor_user_id, 'RANDOM_BASELINE_REFERENCE_PATH_INCOMPLETE',
        cancelled_tasks, failed_evaluations, config_manifest, evidence_hash
    );
    RETURN QUERY SELECT new_experiment_id, new_execution_id, evidence_hash;
END
$function$;

ALTER TABLE strategy_training.training_cross_fit_reference_remediations
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.restart_cross_fit_after_reference_remediation(
    uuid, uuid, uuid
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_reference_remediations
FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.restart_cross_fit_after_reference_remediation(
        uuid, uuid, uuid
    )
FROM PUBLIC;
GRANT SELECT ON strategy_training.training_cross_fit_reference_remediations
TO tb2_training_rw, tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION
    strategy_training.restart_cross_fit_after_reference_remediation(
        uuid, uuid, uuid
    )
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '103_training_cross_fit_reference_remediation',
    encode(digest(
        'auto_trade_v2_103_training_cross_fit_reference_remediation_v1',
        'sha256'
    ), 'hex'),
    'Audit Cross-fit replacement after immutable random-baseline path remediation'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
