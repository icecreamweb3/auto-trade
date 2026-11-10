\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_tasks
DROP CONSTRAINT training_tasks_task_type_check;
ALTER TABLE strategy_training.training_tasks
ADD CONSTRAINT training_tasks_task_type_check CHECK (task_type IN (
    'DATASET_BUILD', 'MODEL_A_CANDIDATE_SCAN', 'MODEL_A_EVALUATION',
    'MODEL_A_L0_AGGREGATION', 'MODEL_B_REPLAY', 'PORTFOLIO_EVALUATION',
    'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY', 'CROSS_FIT_COORDINATE'
));

CREATE OR REPLACE FUNCTION strategy_training.enforce_training_task_payload_contract()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE payload_version_text text; expected_executor text;
BEGIN
    IF jsonb_typeof(NEW.task_payload -> 'task_type') <> 'string'
       OR NEW.task_payload ->> 'task_type' IS DISTINCT FROM NEW.task_type THEN
        RAISE EXCEPTION 'task payload task_type must match the task row'
            USING ERRCODE = '23514';
    END IF;
    payload_version_text := NEW.task_payload ->> 'payload_version';
    IF jsonb_typeof(NEW.task_payload -> 'payload_version') <> 'number'
       OR payload_version_text !~ '^[1-9][0-9]*$' THEN
        RAISE EXCEPTION 'task payload_version must be a positive integer'
            USING ERRCODE = '23514';
    END IF;
    expected_executor := CASE NEW.task_type
        WHEN 'DATASET_BUILD' THEN 'WORKER'
        WHEN 'MODEL_A_CANDIDATE_SCAN' THEN 'WORKER'
        WHEN 'MODEL_A_EVALUATION' THEN 'EVALUATOR'
        WHEN 'MODEL_A_L0_AGGREGATION' THEN 'EVALUATOR'
        WHEN 'MODEL_B_REPLAY' THEN 'MODEL_B'
        WHEN 'PORTFOLIO_EVALUATION' THEN 'EVALUATOR'
        WHEN 'OPTIMIZER_TRIAL' THEN 'OPTIMIZER'
        WHEN 'ARCHIVE_VERIFY' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_COORDINATE' THEN 'EVALUATOR'
        ELSE NULL
    END;
    IF expected_executor IS NULL OR NEW.executor_kind <> expected_executor THEN
        RAISE EXCEPTION 'task type % requires executor %, received %',
            NEW.task_type, expected_executor, NEW.executor_kind
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.prepare_cross_fit_optimizer_pair(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (action text, result_hash char(64))
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    protocol_json jsonb;
    search_space_id uuid;
    requested_execution_id uuid;
    requested_fold integer;
    next_fold integer;
    existing_tpe uuid;
    existing_random uuid;
    tpe_id uuid;
    random_id uuid;
    base_seed bigint;
    fold_seed bigint;
    fold_budget integer;
    prediction_start timestamptz;
    prediction_end timestamptz;
    effective_start timestamptz;
    effective_end timestamptz;
    embargo_hours integer;
    prediction_days integer;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'CROSS_FIT_COORDINATE'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.task_payload ->> 'task_type' <> 'CROSS_FIT_COORDINATE'
       OR task_record.task_payload ->> 'payload_version' <> '1'
       OR task_record.task_payload ? 'execution_id' IS NOT TRUE
       OR task_record.task_payload ? 'fold_number' IS NOT TRUE
       OR (SELECT count(*) FROM jsonb_object_keys(task_record.task_payload)) <> 4 THEN
        RAISE EXCEPTION 'Cross-fit coordination requires its exact active v1 lease'
            USING ERRCODE = '40001';
    END IF;
    requested_execution_id := (task_record.task_payload ->> 'execution_id')::uuid;
    requested_fold := (task_record.task_payload ->> 'fold_number')::integer;
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions execution
    WHERE execution.cross_fit_execution_id = requested_execution_id
      AND execution.experiment_id = task_record.experiment_id
    FOR UPDATE;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = execution_record.dataset_version_id FOR SHARE;
    SELECT config.config_json INTO STRICT protocol_json
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = execution_record.protocol_config_version_id
      AND config.config_type = 'CROSS_FIT_PROTOCOL' AND config.status = 'READY';
    SELECT binding.config_version_id INTO STRICT search_space_id
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'SEARCH_SPACE' AND config.status = 'READY'
    WHERE binding.experiment_id = execution_record.experiment_id
      AND binding.config_type = 'SEARCH_SPACE';

    -- Reuse the task lease as the short-lived Cross-fit capability.  The pair
    -- creation and both scope facts commit atomically with this task.
    UPDATE strategy_training.training_cross_fit_executions
    SET lease_token = p_lease_token,
        leased_by = task_record.leased_by,
        lease_expires_at = task_record.lease_expires_at
    WHERE cross_fit_execution_id = requested_execution_id
      AND (
          lease_token IS NULL OR lease_expires_at <= clock_timestamp()
          OR lease_token = p_lease_token
      );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cross-fit execution is leased by another worker'
            USING ERRCODE = '40001';
    END IF;
    IF execution_record.state = 'PLANNED' THEN
        PERFORM strategy_training.start_cross_fit_execution(
            requested_execution_id, p_lease_token
        );
        execution_record.state := 'RUNNING';
    END IF;
    IF execution_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'Cross-fit optimizer pair requires a RUNNING execution'
            USING ERRCODE = '55000';
    END IF;

    SELECT COALESCE(max(scope.outer_fold_number), 0) + 1 INTO next_fold
    FROM strategy_training.training_cross_fit_optimizer_scopes scope
    WHERE scope.cross_fit_execution_id = requested_execution_id;
    IF requested_fold <> next_fold THEN
        -- A retry after the pair committed returns the immutable pair hash.
        SELECT
            max(scope.optimizer_run_id::text) FILTER (
                WHERE optimizer_role = 'TPE'
            )::uuid,
            max(scope.optimizer_run_id::text) FILTER (
                WHERE optimizer_role = 'RANDOM'
            )::uuid
        INTO existing_tpe, existing_random
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        WHERE scope.cross_fit_execution_id = requested_execution_id
          AND scope.outer_fold_number = requested_fold;
        IF existing_tpe IS NULL OR existing_random IS NULL THEN
            RAISE EXCEPTION 'requested Cross-fit fold is not the next fold'
                USING ERRCODE = '40001';
        END IF;
        action := 'PAIR_ALREADY_PREPARED';
        result_hash := encode(digest(concat_ws('|', requested_execution_id::text,
            requested_fold::text, existing_tpe::text, existing_random::text),
            'sha256'), 'hex');
        RETURN NEXT;
        RETURN;
    END IF;
    IF requested_fold > 1 AND NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_fold_executions fold_execution
        JOIN strategy_training.training_cross_fit_fold_searches control
          ON control.cross_fit_fold_id = fold_execution.cross_fit_fold_id
        WHERE fold_execution.cross_fit_execution_id = requested_execution_id
          AND control.inner_optimizer_run_id <> fold_execution.optimizer_run_id
          AND EXISTS (
              SELECT 1 FROM strategy_training.training_cross_fit_folds fold
              WHERE fold.cross_fit_fold_id = fold_execution.cross_fit_fold_id
                AND fold.outer_fold_number = requested_fold - 1
                AND fold.status = 'SUCCEEDED'
          )
    ) THEN
        RAISE EXCEPTION 'previous Cross-fit fold is not finalized'
            USING ERRCODE = '55000';
    END IF;

    embargo_hours := (
        protocol_json #>> '{q030_cross_fit,label_settlement_embargo_hours}'
    )::integer;
    prediction_days := (
        protocol_json #>> '{q030_cross_fit,prediction_signal_window_days}'
    )::integer;
    effective_start := dataset_record.eligible_start_at;
    IF requested_fold = 1 THEN
        effective_end := effective_start + make_interval(days => (
            protocol_json #>> '{q030_cross_fit,minimum_training_window_effective_days}'
        )::integer);
        prediction_start := effective_end + make_interval(hours => embargo_hours);
    ELSE
        -- The approved protocol fixes the forward step equal to the prediction
        -- window (two days). Anchoring at the preceding prediction end keeps
        -- that relationship explicit without mutating the immutable READY
        -- protocol with a new field.
        SELECT max(scope.prediction_end_at) INTO STRICT prediction_start
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        WHERE scope.cross_fit_execution_id = requested_execution_id
          AND scope.outer_fold_number = requested_fold - 1;
        effective_end := prediction_start - make_interval(hours => embargo_hours);
    END IF;
    prediction_end := prediction_start + make_interval(days => prediction_days);
    IF prediction_end > dataset_record.eligible_end_at THEN
        RAISE EXCEPTION 'TRAIN interval has no complete next Cross-fit prediction fold'
            USING ERRCODE = '22000';
    END IF;

    base_seed := (protocol_json #>> '{q030_cross_fit,random_seed}')::bigint;
    fold_seed := base_seed + requested_fold - 1;
    fold_budget := (protocol_json #>> '{q030_cross_fit,tpe_trials_per_fold}')::integer;
    IF fold_budget <> (
        protocol_json #>> '{q030_cross_fit,random_trials_per_fold}'
    )::integer THEN
        RAISE EXCEPTION 'TPE and RANDOM fold budgets are not equal'
            USING ERRCODE = '23514';
    END IF;
    tpe_id := strategy_training.create_training_optimizer_run(
        execution_record.experiment_id, 'TPE', search_space_id,
        fold_budget, fold_seed,
        format('cross-fit:%s:fold:%s:TPE', requested_execution_id, requested_fold)
    );
    random_id := strategy_training.create_training_optimizer_run(
        execution_record.experiment_id, 'RANDOM', search_space_id,
        fold_budget, fold_seed,
        format('cross-fit:%s:fold:%s:RANDOM', requested_execution_id, requested_fold)
    );
    PERFORM strategy_training.register_cross_fit_optimizer_scope(
        requested_execution_id, p_lease_token, requested_fold, tpe_id, 'TPE',
        effective_start, effective_end, prediction_start, prediction_end
    );
    PERFORM strategy_training.register_cross_fit_optimizer_scope(
        requested_execution_id, p_lease_token, requested_fold, random_id, 'RANDOM',
        effective_start, effective_end, prediction_start, prediction_end
    );
    PERFORM strategy_training.transition_training_optimizer_run(
        tpe_id, 'CREATED', 'RUNNING', NULL, NULL, 'training-cross-fit-coordinator',
        'start frozen outer-fold TPE search', gen_random_uuid()
    );
    PERFORM strategy_training.transition_training_optimizer_run(
        random_id, 'CREATED', 'RUNNING', NULL, NULL, 'training-cross-fit-coordinator',
        'start frozen outer-fold RANDOM control', gen_random_uuid()
    );
    action := 'PAIR_PREPARED';
    result_hash := encode(digest(concat_ws('|', requested_execution_id::text,
        requested_fold::text, tpe_id::text, random_id::text,
        effective_start::text, effective_end::text,
        prediction_start::text, prediction_end::text), 'sha256'), 'hex');
    RETURN NEXT;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_cross_fit_executions()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE timed_out_run strategy_training.training_optimizer_runs%ROWTYPE;
DECLARE latest_fold integer;
DECLARE next_fold integer;
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
DECLARE scope_count integer;
DECLARE terminal_count integer;
BEGIN
    FOR timed_out_run IN
        SELECT run.*
        FROM strategy_training.training_optimizer_runs run
        JOIN strategy_training.training_cross_fit_optimizer_scopes scope
          ON scope.optimizer_run_id = run.optimizer_run_id
        WHERE run.state = 'RUNNING'
          AND run.started_at
                + make_interval(secs => scope.wall_clock_budget_seconds)
              <= clock_timestamp()
        ORDER BY run.started_at, run.optimizer_run_id
        FOR UPDATE OF run SKIP LOCKED
    LOOP
        PERFORM strategy_training.transition_training_optimizer_run(
            timed_out_run.optimizer_run_id, 'RUNNING', 'FAILED',
            'CROSS_FIT_WALL_CLOCK_EXCEEDED', NULL,
            'training-cross-fit-orchestrator',
            'frozen per-fold optimizer wall-clock budget exceeded',
            gen_random_uuid()
        );
    END LOOP;

    FOR execution_record IN
        SELECT execution.*
        FROM strategy_training.training_cross_fit_executions execution
        WHERE execution.state IN ('PLANNED', 'RUNNING')
        ORDER BY execution.created_at, execution.cross_fit_execution_id
        FOR UPDATE SKIP LOCKED
    LOOP
        cross_fit_execution_id := execution_record.cross_fit_execution_id;
        IF EXISTS (
            SELECT 1
            FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run
              ON run.optimizer_run_id = scope.optimizer_run_id
            WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id
              AND run.state IN ('FAILED', 'CANCELLED')
        ) THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'FOLD_OPTIMIZER_FAILED',
                completed_at = clock_timestamp(), lease_token = NULL,
                leased_by = NULL, lease_expires_at = NULL
            WHERE training_cross_fit_executions.cross_fit_execution_id
                = execution_record.cross_fit_execution_id;
            action := 'EXECUTION_FAILED';
            RETURN NEXT;
            CONTINUE;
        END IF;

        SELECT COALESCE(max(scope.outer_fold_number), 0) INTO latest_fold
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id;
        next_fold := latest_fold + 1;
        IF latest_fold > 0 THEN
            SELECT count(*), count(*) FILTER (
                WHERE run.state = 'SUCCEEDED'
            ) INTO scope_count, terminal_count
            FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run
              ON run.optimizer_run_id = scope.optimizer_run_id
            WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id
              AND scope.outer_fold_number = latest_fold;
            IF scope_count <> 2 OR terminal_count <> 2 THEN
                action := 'WAITING_OPTIMIZER_PAIR';
                RETURN NEXT;
                CONTINUE;
            END IF;
            IF NOT EXISTS (
                SELECT 1
                FROM strategy_training.training_cross_fit_fold_executions fold_execution
                JOIN strategy_training.training_cross_fit_folds fold
                  ON fold.cross_fit_fold_id = fold_execution.cross_fit_fold_id
                WHERE fold_execution.cross_fit_execution_id
                    = execution_record.cross_fit_execution_id
                  AND fold.outer_fold_number = latest_fold
            ) THEN
                action := 'WAITING_FOLD_FINALIZATION';
                RETURN NEXT;
                CONTINUE;
            END IF;
        END IF;

        SELECT * INTO task_record
        FROM strategy_training.training_tasks task
        WHERE task.experiment_id = execution_record.experiment_id
          AND task.task_type = 'CROSS_FIT_COORDINATE'
          AND task.task_payload ->> 'execution_id'
                = execution_record.cross_fit_execution_id::text
          AND (task.task_payload ->> 'fold_number')::integer = next_fold;
        IF FOUND THEN
            action := CASE task_record.state
                WHEN 'SUCCEEDED' THEN 'COORDINATION_COMPLETED'
                WHEN 'FAILED' THEN 'COORDINATION_FAILED'
                ELSE 'WAITING_COORDINATION'
            END;
            RETURN NEXT;
            CONTINUE;
        END IF;

        PERFORM strategy_training.enqueue_training_task(
            execution_record.experiment_id, NULL, NULL, NULL,
            'CROSS_FIT_COORDINATE', 'EVALUATOR',
            encode(digest(concat_ws('|', execution_record.cross_fit_execution_id::text,
                next_fold::text, 'CROSS_FIT_COORDINATE_V1'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'CROSS_FIT_COORDINATE',
                'payload_version', 1,
                'execution_id', execution_record.cross_fit_execution_id::text,
                'fold_number', next_fold),
            20
        );
        action := 'COORDINATION_ENQUEUED';
        RETURN NEXT;
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.prepare_cross_fit_optimizer_pair(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_cross_fit_executions()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.prepare_cross_fit_optimizer_pair(uuid, uuid),
    strategy_training.advance_training_cross_fit_executions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.prepare_cross_fit_optimizer_pair(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.advance_training_cross_fit_executions()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '078_training_cross_fit_optimizer_orchestration',
    encode(digest(
        'auto_trade_v2_078_training_cross_fit_optimizer_orchestration_v1',
        'sha256'
    ), 'hex'),
    'Create lease-bound Cross-fit fold optimizer pairs and orchestrator progression'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
