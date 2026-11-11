\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Candidate scans belong to an optimizer trial.  Cross-fit resolves the frozen
-- fold scope through this optimizer_run_id, so it must survive task enqueueing.
CREATE OR REPLACE FUNCTION strategy_training.advance_training_candidate_scans()
RETURNS TABLE (iteration_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; scan_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    FOR candidate IN
        SELECT iteration.iteration_id, iteration.experiment_id,
               run.optimizer_run_id, proposal.task_id AS parent_task_id
        FROM strategy_training.training_optimizer_runs run
        JOIN strategy_training.training_optimizer_trial_proposals proposal
          ON proposal.optimizer_run_id = run.optimizer_run_id
        JOIN strategy_training.training_optimizer_trial_iterations link
          ON link.optimizer_trial_proposal_id = proposal.optimizer_trial_proposal_id
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = link.iteration_id
        LEFT JOIN strategy_training.training_iteration_entry_batches batch
          ON batch.iteration_id = iteration.iteration_id
        WHERE run.state = 'RUNNING' AND iteration.state = 'RUNNING'
          AND batch.iteration_id IS NULL
        ORDER BY iteration.created_at, iteration.iteration_id
    LOOP
        iteration_id := candidate.iteration_id;
        SELECT * INTO scan_task FROM strategy_training.training_tasks task
        WHERE task.iteration_id = candidate.iteration_id
          AND task.task_type = 'MODEL_A_CANDIDATE_SCAN';
        IF NOT FOUND THEN
            PERFORM strategy_training.enqueue_training_task(
                candidate.experiment_id, candidate.iteration_id,
                candidate.optimizer_run_id, candidate.parent_task_id,
                'MODEL_A_CANDIDATE_SCAN', 'WORKER',
                encode(public.digest(concat_ws('|', candidate.iteration_id::text,
                    'MODEL_A_CANDIDATE_SCAN'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'MODEL_A_CANDIDATE_SCAN',
                    'payload_version', 1), 15
            );
            action := 'SCAN_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF scan_task.state IN ('FAILED', 'CANCELLED') THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                COALESCE(scan_task.failure_code, 'MODEL_A_CANDIDATE_SCAN_FAILED'),
                scan_task.result_hash, NULL, 'training-orchestrator',
                'candidate scan task failed', gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        IF scan_task.state = 'SUCCEEDED' THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                'MODEL_A_CANDIDATE_SCAN_MISSING_BATCH', scan_task.result_hash,
                NULL, 'training-orchestrator', 'scan succeeded without frozen batch',
                gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        action := 'WAITING_SCAN'; RETURN NEXT;
    END LOOP;
END
$$;

CREATE TABLE strategy_training.training_cross_fit_restarts (
    previous_cross_fit_execution_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_cross_fit_executions,
    previous_experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    replacement_experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    replacement_cross_fit_execution_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_cross_fit_executions,
    actor_user_id uuid NOT NULL REFERENCES core.app_users,
    reason_code varchar(64) NOT NULL
        CHECK (reason_code = 'CANDIDATE_SCAN_SCOPE_LINK_MISSING'),
    failed_scan_count integer NOT NULL CHECK (failed_scan_count > 0),
    config_manifest_hash char(64) NOT NULL
        CHECK (config_manifest_hash ~ '^[0-9a-f]{64}$'),
    restart_evidence_hash char(64) NOT NULL
        CHECK (restart_evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TRIGGER trg_training_cross_fit_restarts_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_cross_fit_restarts
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.restart_cross_fit_after_scan_scope_failure(
    p_previous_cross_fit_execution_id uuid, p_actor_user_id uuid
)
RETURNS TABLE (
    replacement_experiment_id uuid,
    replacement_cross_fit_execution_id uuid,
    restart_evidence_hash char(64)
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    existing_record strategy_training.training_cross_fit_restarts%ROWTYPE;
    task_record strategy_training.training_tasks%ROWTYPE;
    iteration_record strategy_training.training_iterations%ROWTYPE;
    optimizer_record strategy_training.training_optimizer_runs%ROWTYPE;
    new_experiment_id uuid;
    new_execution_id uuid;
    failed_scans integer;
    config_manifest char(64);
    evidence_hash char(64);
BEGIN
    PERFORM strategy_training.assert_active_training_role(
        p_actor_user_id, 'TRAINING_ADMIN'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_previous_cross_fit_execution_id::text, 100)
    );

    SELECT * INTO existing_record
    FROM strategy_training.training_cross_fit_restarts restart
    WHERE restart.previous_cross_fit_execution_id =
          p_previous_cross_fit_execution_id;
    IF FOUND THEN
        RETURN QUERY SELECT existing_record.replacement_experiment_id,
            existing_record.replacement_cross_fit_execution_id,
            existing_record.restart_evidence_hash;
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

    SELECT count(*) INTO failed_scans
    FROM strategy_training.training_tasks task
    WHERE task.experiment_id = execution_record.experiment_id
      AND task.task_type = 'MODEL_A_CANDIDATE_SCAN'
      AND task.optimizer_run_id IS NULL
      AND task.state = 'FAILED'
      AND task.failure_code = 'HANDLER_FAILED';
    IF execution_record.state <> 'RUNNING'
       OR experiment_record.state <> 'RUNNING'
       OR dataset_record.status <> 'READY'
       OR dataset_record.partition <> 'TRAIN'
       OR failed_scans = 0
       OR EXISTS (
           SELECT 1 FROM strategy_training.training_tasks task
           WHERE task.experiment_id = execution_record.experiment_id
             AND task.task_type = 'MODEL_A_CANDIDATE_SCAN'
             AND task.optimizer_run_id IS NOT NULL
       )
       OR NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_cross_fit_optimizer_scopes scope
           WHERE scope.cross_fit_execution_id =
                 execution_record.cross_fit_execution_id
       )
       OR EXISTS (
           SELECT 1 FROM strategy_training.training_tasks task
           WHERE task.experiment_id = execution_record.experiment_id
             AND task.state IN ('LEASED', 'RUNNING', 'PAUSED')
       ) THEN
        RAISE EXCEPTION 'execution is not an idle scan-scope-link failure'
            USING ERRCODE = '23514';
    END IF;

    FOR task_record IN
        SELECT * FROM strategy_training.training_tasks task
        WHERE task.experiment_id = execution_record.experiment_id
          AND task.state = 'QUEUED'
        ORDER BY task.created_at, task.task_id
        FOR UPDATE
    LOOP
        PERFORM strategy_training.request_training_task_cancellation(
            task_record.task_id,
            'superseded by audited Cross-fit scan-scope recovery'
        );
    END LOOP;
    FOR iteration_record IN
        SELECT * FROM strategy_training.training_iterations iteration
        WHERE iteration.experiment_id = execution_record.experiment_id
          AND iteration.state IN ('CREATED', 'VALIDATING', 'RUNNING')
        ORDER BY iteration.created_at, iteration.iteration_id
        FOR UPDATE
    LOOP
        PERFORM strategy_training.transition_training_iteration(
            iteration_record.iteration_id, iteration_record.state,
            'CANCELLED', 'CANDIDATE_SCAN_SCOPE_LINK_MISSING', NULL,
            p_actor_user_id, NULL,
            'cancel incomplete iteration after scan-scope infrastructure failure',
            gen_random_uuid()
        );
    END LOOP;
    FOR optimizer_record IN
        SELECT run.*
        FROM strategy_training.training_optimizer_runs run
        JOIN strategy_training.training_cross_fit_optimizer_scopes scope
          ON scope.optimizer_run_id = run.optimizer_run_id
        WHERE scope.cross_fit_execution_id =
              execution_record.cross_fit_execution_id
          AND run.state = 'RUNNING'
        ORDER BY run.optimizer_run_id
        FOR UPDATE OF run
    LOOP
        PERFORM strategy_training.transition_training_optimizer_run(
            optimizer_record.optimizer_run_id, 'RUNNING', 'FAILED',
            'CANDIDATE_SCAN_SCOPE_LINK_MISSING', p_actor_user_id, NULL,
            'stop optimizer after scan task lost its frozen scope link',
            gen_random_uuid()
        );
    END LOOP;
    UPDATE strategy_training.training_cross_fit_executions
    SET state = 'FAILED',
        failure_code = 'CANDIDATE_SCAN_SCOPE_LINK_MISSING',
        completed_at = clock_timestamp(),
        lease_token = NULL, leased_by = NULL, lease_expires_at = NULL
    WHERE cross_fit_execution_id = execution_record.cross_fit_execution_id;
    PERFORM strategy_training.transition_training_experiment(
        experiment_record.experiment_id, 'RUNNING', 'STOPPED',
        p_actor_user_id, NULL,
        'superseded after candidate scan lost Cross-fit optimizer scope link',
        gen_random_uuid()
    );

    new_experiment_id := strategy_training.create_training_experiment(
        'DISCOVERY', experiment_record.experiment_id,
        experiment_record.dataset_version_id,
        experiment_record.resource_limit_config_version_id,
        format('cross-fit-scope-retry-%s', execution_record.cross_fit_execution_id),
        encode(digest(concat_ws('|', experiment_record.exposure_identity_hash,
            execution_record.cross_fit_execution_id::text,
            'CANDIDATE_SCAN_SCOPE_LINK_FIXED'), 'sha256'), 'hex'),
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
      AND config.status = 'READY';
    IF (SELECT count(*)
        FROM strategy_training.training_experiment_config_bindings binding
        WHERE binding.experiment_id = new_experiment_id) < 20 THEN
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
        'start clean Cross-fit retry after scan-scope link fix', gen_random_uuid()
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
        'config_manifest_hash', config_manifest,
        'failed_scan_count', failed_scans,
        'previous_cross_fit_execution_id',
            execution_record.cross_fit_execution_id,
        'previous_experiment_id', experiment_record.experiment_id,
        'reason_code', 'CANDIDATE_SCAN_SCOPE_LINK_MISSING',
        'replacement_cross_fit_execution_id', new_execution_id,
        'replacement_experiment_id', new_experiment_id
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_cross_fit_restarts (
        previous_cross_fit_execution_id, previous_experiment_id,
        replacement_experiment_id, replacement_cross_fit_execution_id,
        actor_user_id, reason_code, failed_scan_count,
        config_manifest_hash, restart_evidence_hash
    ) VALUES (
        execution_record.cross_fit_execution_id,
        experiment_record.experiment_id, new_experiment_id, new_execution_id,
        p_actor_user_id, 'CANDIDATE_SCAN_SCOPE_LINK_MISSING', failed_scans,
        config_manifest, evidence_hash
    );
    RETURN QUERY SELECT new_experiment_id, new_execution_id, evidence_hash;
END
$$;

ALTER FUNCTION strategy_training.advance_training_candidate_scans()
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_restarts
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.restart_cross_fit_after_scan_scope_failure(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_restarts FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.restart_cross_fit_after_scan_scope_failure(uuid, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.restart_cross_fit_after_scan_scope_failure(uuid, uuid)
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '100_training_cross_fit_scan_scope_recovery',
    encode(digest('auto_trade_v2_100_training_cross_fit_scan_scope_recovery_v1',
                  'sha256'), 'hex'),
    'Preserve optimizer scope on candidate scans and audit clean Cross-fit retries'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
