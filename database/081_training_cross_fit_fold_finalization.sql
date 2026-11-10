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
    'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY', 'CROSS_FIT_COORDINATE',
    'CROSS_FIT_PREDICT', 'CROSS_FIT_FINALIZE_FOLD'
));

CREATE OR REPLACE FUNCTION strategy_training.enforce_training_task_payload_contract()
RETURNS trigger LANGUAGE plpgsql
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
        WHEN 'CROSS_FIT_PREDICT' THEN 'WORKER'
        WHEN 'CROSS_FIT_FINALIZE_FOLD' THEN 'EVALUATOR'
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

ALTER TABLE strategy_training.training_cross_fit_fold_executions
ADD COLUMN selected_iteration_id uuid REFERENCES strategy_training.training_iterations,
ADD COLUMN selected_trial_result_id uuid
    REFERENCES strategy_training.training_optimizer_trial_results,
ADD COLUMN random_optimizer_run_id uuid REFERENCES strategy_training.training_optimizer_runs,
ADD COLUMN tpe_prediction_id uuid REFERENCES strategy_training.training_cross_fit_predictions,
ADD COLUMN random_prediction_id uuid REFERENCES strategy_training.training_cross_fit_predictions,
ADD COLUMN tpe_coverage_report_hash char(64),
ADD COLUMN random_coverage_report_hash char(64),
ADD CONSTRAINT training_cross_fit_fold_runtime_evidence_check CHECK (
    (selected_iteration_id IS NULL AND selected_trial_result_id IS NULL
        AND random_optimizer_run_id IS NULL AND tpe_prediction_id IS NULL
        AND random_prediction_id IS NULL AND tpe_coverage_report_hash IS NULL
        AND random_coverage_report_hash IS NULL)
    OR
    (selected_iteration_id IS NOT NULL AND selected_trial_result_id IS NOT NULL
        AND random_optimizer_run_id IS NOT NULL AND tpe_prediction_id IS NOT NULL
        AND random_prediction_id IS NOT NULL
        AND tpe_coverage_report_hash ~ '^[0-9a-f]{64}$'
        AND random_coverage_report_hash ~ '^[0-9a-f]{64}$')
),
ADD CONSTRAINT training_cross_fit_fold_distinct_optimizers_check CHECK (
    random_optimizer_run_id IS NULL OR random_optimizer_run_id <> optimizer_run_id
),
ADD CONSTRAINT training_cross_fit_fold_distinct_predictions_check CHECK (
    random_prediction_id IS NULL OR random_prediction_id <> tpe_prediction_id
);

CREATE OR REPLACE FUNCTION strategy_training.guard_cross_fit_fold_runtime_scope()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE tpe_scope strategy_training.training_cross_fit_optimizer_scopes%ROWTYPE;
        random_scope strategy_training.training_cross_fit_optimizer_scopes%ROWTYPE;
        fold_record strategy_training.training_cross_fit_folds%ROWTYPE;
        tpe_prediction strategy_training.training_cross_fit_predictions%ROWTYPE;
        random_prediction strategy_training.training_cross_fit_predictions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT tpe_scope
    FROM strategy_training.training_cross_fit_optimizer_scopes
    WHERE optimizer_run_id = NEW.optimizer_run_id;
    SELECT * INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_folds
    WHERE cross_fit_fold_id = NEW.cross_fit_fold_id;
    IF tpe_scope.cross_fit_execution_id <> NEW.cross_fit_execution_id
       OR tpe_scope.outer_fold_number <> fold_record.outer_fold_number
       OR tpe_scope.optimizer_role <> 'TPE'
       OR fold_record.effective_train_start_at <> tpe_scope.effective_train_start_at
       OR fold_record.effective_train_end_at <> tpe_scope.effective_train_end_at
       OR fold_record.prediction_start_at <> tpe_scope.prediction_start_at
       OR fold_record.prediction_end_at <> tpe_scope.prediction_end_at
       OR NEW.trial_budget <> tpe_scope.trial_budget
       OR NEW.wall_clock_budget_seconds <> tpe_scope.wall_clock_budget_seconds
       OR NEW.repeat_count <> tpe_scope.repeat_count
       OR NEW.random_seed <> tpe_scope.random_seed THEN
        RAISE EXCEPTION 'completed fold does not match its frozen TPE scope'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.selected_iteration_id IS NULL THEN RETURN NEW; END IF;
    SELECT * INTO STRICT random_scope
    FROM strategy_training.training_cross_fit_optimizer_scopes
    WHERE optimizer_run_id = NEW.random_optimizer_run_id;
    SELECT * INTO STRICT tpe_prediction
    FROM strategy_training.training_cross_fit_predictions
    WHERE cross_fit_prediction_id = NEW.tpe_prediction_id;
    SELECT * INTO STRICT random_prediction
    FROM strategy_training.training_cross_fit_predictions
    WHERE cross_fit_prediction_id = NEW.random_prediction_id;
    IF random_scope.cross_fit_execution_id <> NEW.cross_fit_execution_id
       OR random_scope.outer_fold_number <> fold_record.outer_fold_number
       OR random_scope.optimizer_role <> 'RANDOM'
       OR random_scope.effective_train_start_at <> tpe_scope.effective_train_start_at
       OR random_scope.effective_train_end_at <> tpe_scope.effective_train_end_at
       OR random_scope.prediction_start_at <> tpe_scope.prediction_start_at
       OR random_scope.prediction_end_at <> tpe_scope.prediction_end_at
       OR random_scope.trial_budget <> tpe_scope.trial_budget
       OR tpe_prediction.optimizer_run_id <> NEW.optimizer_run_id
       OR tpe_prediction.optimizer_role <> 'TPE'
       OR tpe_prediction.selected_iteration_id <> NEW.selected_iteration_id
       OR tpe_prediction.selected_trial_result_id <> NEW.selected_trial_result_id
       OR random_prediction.optimizer_run_id <> NEW.random_optimizer_run_id
       OR random_prediction.optimizer_role <> 'RANDOM' THEN
        RAISE EXCEPTION 'completed fold does not match its paired prediction evidence'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_cross_fit_fold(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        tpe_scope strategy_training.training_cross_fit_optimizer_scopes%ROWTYPE;
        random_scope strategy_training.training_cross_fit_optimizer_scopes%ROWTYPE;
        tpe_prediction strategy_training.training_cross_fit_predictions%ROWTYPE;
        random_prediction strategy_training.training_cross_fit_predictions%ROWTYPE;
        tpe_report strategy_training.training_cross_fit_prediction_coverage_reports%ROWTYPE;
        random_report strategy_training.training_cross_fit_prediction_coverage_reports%ROWTYPE;
        requested_execution_id uuid; requested_fold integer; fold_id uuid;
        raw_count bigint; effective_count bigint; embargo_count bigint;
        minimum_fitting_count bigint; fitting_qualified boolean;
        fold_hash char(64); protocol_hash char(64); existing_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'CROSS_FIT_FINALIZE_FOLD'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.task_payload ->> 'task_type' <> 'CROSS_FIT_FINALIZE_FOLD'
       OR task_record.task_payload ->> 'payload_version' <> '1'
       OR (SELECT count(*) FROM jsonb_object_keys(task_record.task_payload)) <> 4 THEN
        RAISE EXCEPTION 'fold finalization requires its exact active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    requested_execution_id := (task_record.task_payload ->> 'execution_id')::uuid;
    requested_fold := (task_record.task_payload ->> 'fold_number')::integer;
    SELECT fold_execution.fold_protocol_hash INTO existing_hash
    FROM strategy_training.training_cross_fit_fold_executions fold_execution
    JOIN strategy_training.training_cross_fit_folds fold USING (cross_fit_fold_id)
    WHERE fold_execution.cross_fit_execution_id = requested_execution_id
      AND fold.outer_fold_number = requested_fold;
    IF FOUND THEN RETURN existing_hash; END IF;
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = requested_execution_id
      AND experiment_id = task_record.experiment_id FOR UPDATE;
    IF execution_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'fold finalization requires a RUNNING execution'
            USING ERRCODE = '55000';
    END IF;
    UPDATE strategy_training.training_cross_fit_executions
    SET lease_token = p_lease_token, leased_by = task_record.leased_by,
        lease_expires_at = task_record.lease_expires_at
    WHERE cross_fit_execution_id = requested_execution_id
      AND (lease_token IS NULL OR lease_expires_at <= clock_timestamp()
           OR lease_token = p_lease_token);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cross-fit execution is leased by another worker'
            USING ERRCODE = '40001';
    END IF;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = execution_record.dataset_version_id;
    SELECT * INTO STRICT tpe_scope
    FROM strategy_training.training_cross_fit_optimizer_scopes
    WHERE cross_fit_execution_id = requested_execution_id
      AND outer_fold_number = requested_fold AND optimizer_role = 'TPE';
    SELECT * INTO STRICT random_scope
    FROM strategy_training.training_cross_fit_optimizer_scopes
    WHERE cross_fit_execution_id = requested_execution_id
      AND outer_fold_number = requested_fold AND optimizer_role = 'RANDOM';
    SELECT * INTO STRICT tpe_prediction
    FROM strategy_training.training_cross_fit_predictions
    WHERE optimizer_run_id = tpe_scope.optimizer_run_id AND completed_at IS NOT NULL;
    SELECT * INTO STRICT random_prediction
    FROM strategy_training.training_cross_fit_predictions
    WHERE optimizer_run_id = random_scope.optimizer_run_id AND completed_at IS NOT NULL;
    SELECT * INTO STRICT tpe_report
    FROM strategy_training.training_cross_fit_prediction_coverage_reports
    WHERE cross_fit_prediction_id = tpe_prediction.cross_fit_prediction_id;
    SELECT * INTO STRICT random_report
    FROM strategy_training.training_cross_fit_prediction_coverage_reports
    WHERE cross_fit_prediction_id = random_prediction.cross_fit_prediction_id;
    IF NOT EXISTS (SELECT 1 FROM strategy_training.training_tasks
                   WHERE task_id = tpe_prediction.evaluation_task_id AND state = 'SUCCEEDED')
       OR NOT EXISTS (SELECT 1 FROM strategy_training.training_tasks
                      WHERE task_id = random_prediction.evaluation_task_id AND state = 'SUCCEEDED')
       OR tpe_scope.effective_train_start_at <> random_scope.effective_train_start_at
       OR tpe_scope.effective_train_end_at <> random_scope.effective_train_end_at
       OR tpe_scope.prediction_start_at <> random_scope.prediction_start_at
       OR tpe_scope.prediction_end_at <> random_scope.prediction_end_at THEN
        RAISE EXCEPTION 'fold finalization requires a complete paired evaluation'
            USING ERRCODE = '55000';
    END IF;
    SELECT count(DISTINCT (bar.instrument_id, bar.open_time)) INTO raw_count
    FROM market.klines bar
    WHERE bar.price_type = 'TRADE' AND bar.interval_seconds = 300
      AND bar.is_closed AND bar.quality_status = 'VALID'
      AND bar.open_time >= dataset_record.warmup_start_at
      AND bar.open_time < tpe_scope.effective_train_end_at
      AND bar.effective_at <= dataset_record.source_as_of_at
      AND EXISTS (SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
                  WHERE pool.dataset_version_id = dataset_record.dataset_version_id
                    AND pool.instrument_id = bar.instrument_id AND pool.is_eligible
                    AND pool.evaluation_at < tpe_scope.effective_train_end_at);
    SELECT count(DISTINCT (bar.instrument_id, bar.open_time)) INTO effective_count
    FROM market.klines bar
    WHERE bar.price_type = 'TRADE' AND bar.interval_seconds = 300
      AND bar.is_closed AND bar.quality_status = 'VALID'
      AND bar.open_time >= tpe_scope.effective_train_start_at
      AND bar.open_time < tpe_scope.effective_train_end_at
      AND bar.effective_at <= dataset_record.source_as_of_at
      AND EXISTS (SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
                  WHERE pool.dataset_version_id = dataset_record.dataset_version_id
                    AND pool.instrument_id = bar.instrument_id AND pool.is_eligible
                    AND pool.evaluation_at < tpe_scope.effective_train_end_at);
    SELECT count(DISTINCT (bar.instrument_id, bar.open_time)) INTO embargo_count
    FROM market.klines bar
    WHERE bar.price_type = 'TRADE' AND bar.interval_seconds = 300
      AND bar.is_closed AND bar.quality_status = 'VALID'
      AND bar.open_time >= tpe_scope.effective_train_end_at
      AND bar.open_time < tpe_scope.prediction_start_at
      AND bar.effective_at <= dataset_record.source_as_of_at
      AND EXISTS (SELECT 1 FROM strategy_training.training_historical_pool_evaluations pool
                  WHERE pool.dataset_version_id = dataset_record.dataset_version_id
                    AND pool.instrument_id = bar.instrument_id AND pool.is_eligible
                    AND pool.evaluation_at < tpe_scope.prediction_start_at);
    SELECT (config.config_json #>>
            '{q030_cross_fit,minimum_fitting_samples_per_fold}')::bigint,
           config.content_hash
    INTO STRICT minimum_fitting_count, protocol_hash
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = execution_record.protocol_config_version_id
      AND config.status = 'READY' AND config.config_type = 'CROSS_FIT_PROTOCOL';
    fitting_qualified := effective_count >= minimum_fitting_count;
    fold_hash := encode(digest(jsonb_build_object(
        'cross_fit_execution_id', requested_execution_id,
        'effective_training_sample_count', effective_count,
        'fold_number', requested_fold,
        'protocol_hash', protocol_hash,
        'random_coverage_report_hash', random_report.report_hash,
        'random_prediction_hash', random_prediction.event_set_hash,
        'selected_iteration_id', tpe_prediction.selected_iteration_id,
        'selected_trial_result_id', tpe_prediction.selected_trial_result_id,
        'tpe_coverage_report_hash', tpe_report.report_hash,
        'tpe_prediction_hash', tpe_prediction.event_set_hash
    )::text, 'sha256'), 'hex');
    fold_id := gen_random_uuid();
    INSERT INTO strategy_training.training_cross_fit_folds (
        cross_fit_fold_id, experiment_id, outer_fold_number,
        raw_train_start_at, raw_train_end_at, effective_train_start_at,
        effective_train_end_at, prediction_start_at, prediction_end_at,
        warmup_start_at, purge_start_at, purge_end_at,
        embargo_start_at, embargo_end_at, excluded_count,
        fold_model_version_id, fold_random_seed, inner_validation_count,
        status, qualification_report
    ) VALUES (
        fold_id, execution_record.experiment_id, requested_fold,
        dataset_record.warmup_start_at, tpe_scope.effective_train_end_at,
        tpe_scope.effective_train_start_at, tpe_scope.effective_train_end_at,
        tpe_scope.prediction_start_at, tpe_scope.prediction_end_at,
        dataset_record.warmup_start_at, tpe_scope.effective_train_end_at,
        tpe_scope.effective_train_end_at, tpe_scope.effective_train_end_at,
        tpe_scope.prediction_start_at, (raw_count - effective_count) + embargo_count,
        NULL, tpe_scope.random_seed, 0, 'SUCCEEDED',
        jsonb_build_object(
            'effective_training_sample_count', effective_count,
            'fitting_sample_qualified', fitting_qualified,
            'minimum_fitting_samples_per_fold', minimum_fitting_count,
            'random_coverage_power_status', random_report.power_status,
            'random_coverage_ratio', random_report.coverage_ratio,
            'raw_training_sample_count', raw_count,
            'selected_iteration_id', tpe_prediction.selected_iteration_id,
            'selected_trial_result_id', tpe_prediction.selected_trial_result_id,
            'tpe_coverage_power_status', tpe_report.power_status,
            'tpe_coverage_ratio', tpe_report.coverage_ratio
        )
    );
    INSERT INTO strategy_training.training_cross_fit_fold_searches (
        cross_fit_fold_id, inner_optimizer_run_id, training_entry_source,
        inner_validation_count, search_budget, random_seed
    ) VALUES
      (fold_id, tpe_scope.optimizer_run_id, 'CROSS_FIT_MODEL_A_CANDIDATE',
       0, tpe_scope.trial_budget, tpe_scope.random_seed),
      (fold_id, random_scope.optimizer_run_id, 'CROSS_FIT_MODEL_A_CANDIDATE',
       0, random_scope.trial_budget, random_scope.random_seed);
    INSERT INTO strategy_training.training_cross_fit_fold_executions (
        cross_fit_fold_id, cross_fit_execution_id, optimizer_run_id,
        raw_training_sample_count, effective_training_sample_count,
        prediction_sample_count, warmup_excluded_count, purge_excluded_count,
        embargo_excluded_count, trial_budget, wall_clock_budget_seconds,
        repeat_count, random_seed, from_scratch, inner_validation_count,
        fold_protocol_hash, selected_iteration_id, selected_trial_result_id,
        random_optimizer_run_id, tpe_prediction_id, random_prediction_id,
        tpe_coverage_report_hash, random_coverage_report_hash
    ) VALUES (
        fold_id, requested_execution_id, tpe_scope.optimizer_run_id,
        raw_count, effective_count, tpe_prediction.event_count,
        raw_count - effective_count, 0, embargo_count,
        tpe_scope.trial_budget, tpe_scope.wall_clock_budget_seconds,
        tpe_scope.repeat_count, tpe_scope.random_seed, true, 0, fold_hash,
        tpe_prediction.selected_iteration_id, tpe_prediction.selected_trial_result_id,
        random_scope.optimizer_run_id, tpe_prediction.cross_fit_prediction_id,
        random_prediction.cross_fit_prediction_id, tpe_report.report_hash,
        random_report.report_hash
    );
    UPDATE strategy_training.training_cross_fit_executions
    SET lease_token = NULL, leased_by = NULL, lease_expires_at = NULL
    WHERE cross_fit_execution_id = requested_execution_id;
    RETURN fold_hash;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.prepare_cross_fit_fold_finalization_task(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_fold_executions fold_execution
        JOIN strategy_training.training_cross_fit_folds fold USING (cross_fit_fold_id)
        WHERE fold_execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND fold.outer_fold_number = p_outer_fold_number
    ) THEN RETURN 'FOLD_FINALIZED'; END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks task
    WHERE task.experiment_id = execution_record.experiment_id
      AND task.task_type = 'CROSS_FIT_FINALIZE_FOLD'
      AND task.task_payload ->> 'execution_id' = p_cross_fit_execution_id::text
      AND (task.task_payload ->> 'fold_number')::integer = p_outer_fold_number;
    IF FOUND THEN
        IF task_record.state IN ('FAILED', 'CANCELLED') THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'FOLD_FINALIZATION_FAILED',
                completed_at = clock_timestamp(), lease_token = NULL,
                leased_by = NULL, lease_expires_at = NULL
            WHERE cross_fit_execution_id = p_cross_fit_execution_id;
            RETURN 'EXECUTION_FAILED';
        END IF;
        RETURN CASE task_record.state WHEN 'SUCCEEDED' THEN 'FOLD_FINALIZED'
                    ELSE 'WAITING_FOLD_FINALIZATION' END;
    END IF;
    PERFORM strategy_training.enqueue_training_task(
        execution_record.experiment_id, NULL, NULL, NULL,
        'CROSS_FIT_FINALIZE_FOLD', 'EVALUATOR',
        encode(digest(concat_ws('|', p_cross_fit_execution_id::text,
            p_outer_fold_number::text, 'CROSS_FIT_FINALIZE_FOLD_V1'), 'sha256'), 'hex'),
        jsonb_build_object('task_type', 'CROSS_FIT_FINALIZE_FOLD',
            'payload_version', 1, 'execution_id', p_cross_fit_execution_id::text,
            'fold_number', p_outer_fold_number), 20
    );
    RETURN 'FOLD_FINALIZATION_ENQUEUED';
END
$$;

-- Extend 080 orchestration with a lease-bound fold-finalization task.
CREATE OR REPLACE FUNCTION strategy_training.advance_training_cross_fit_executions()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        timed_out_run strategy_training.training_optimizer_runs%ROWTYPE;
        latest_fold integer; next_fold integer;
        task_record strategy_training.training_tasks%ROWTYPE;
        scope_count integer; terminal_count integer;
        prediction_action text; evaluation_action text; finalization_action text;
BEGIN
    FOR timed_out_run IN
        SELECT run.* FROM strategy_training.training_optimizer_runs run
        JOIN strategy_training.training_cross_fit_optimizer_scopes scope
          ON scope.optimizer_run_id = run.optimizer_run_id
        WHERE run.state = 'RUNNING'
          AND run.started_at + make_interval(secs => scope.wall_clock_budget_seconds)
              <= clock_timestamp()
        ORDER BY run.started_at, run.optimizer_run_id FOR UPDATE OF run SKIP LOCKED
    LOOP
        PERFORM strategy_training.transition_training_optimizer_run(
            timed_out_run.optimizer_run_id, 'RUNNING', 'FAILED',
            'CROSS_FIT_WALL_CLOCK_EXCEEDED', NULL,
            'training-cross-fit-orchestrator',
            'frozen per-fold optimizer wall-clock budget exceeded', gen_random_uuid());
    END LOOP;
    FOR execution_record IN
        SELECT execution.* FROM strategy_training.training_cross_fit_executions execution
        WHERE execution.state IN ('PLANNED', 'RUNNING')
        ORDER BY execution.created_at, execution.cross_fit_execution_id
        FOR UPDATE SKIP LOCKED
    LOOP
        cross_fit_execution_id := execution_record.cross_fit_execution_id;
        IF EXISTS (
            SELECT 1 FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run USING (optimizer_run_id)
            WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id
              AND run.state IN ('FAILED', 'CANCELLED')
        ) THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'FOLD_OPTIMIZER_FAILED',
                completed_at = clock_timestamp(), lease_token = NULL,
                leased_by = NULL, lease_expires_at = NULL
            WHERE training_cross_fit_executions.cross_fit_execution_id =
                  execution_record.cross_fit_execution_id;
            action := 'EXECUTION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT COALESCE(max(scope.outer_fold_number), 0) INTO latest_fold
        FROM strategy_training.training_cross_fit_optimizer_scopes scope
        WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id;
        next_fold := latest_fold + 1;
        IF latest_fold > 0 THEN
            SELECT count(*), count(*) FILTER (WHERE run.state = 'SUCCEEDED')
            INTO scope_count, terminal_count
            FROM strategy_training.training_cross_fit_optimizer_scopes scope
            JOIN strategy_training.training_optimizer_runs run USING (optimizer_run_id)
            WHERE scope.cross_fit_execution_id = execution_record.cross_fit_execution_id
              AND scope.outer_fold_number = latest_fold;
            IF scope_count <> 2 OR terminal_count <> 2 THEN
                action := 'WAITING_OPTIMIZER_PAIR'; RETURN NEXT; CONTINUE;
            END IF;
            prediction_action := strategy_training.prepare_cross_fit_prediction_tasks(
                execution_record.cross_fit_execution_id, latest_fold);
            IF prediction_action <> 'PREDICTION_PAIR_COMPLETED' THEN
                action := prediction_action; RETURN NEXT; CONTINUE;
            END IF;
            evaluation_action := strategy_training.prepare_cross_fit_evaluation_tasks(
                execution_record.cross_fit_execution_id, latest_fold);
            IF evaluation_action <> 'EVALUATION_PAIR_COMPLETED' THEN
                action := evaluation_action; RETURN NEXT; CONTINUE;
            END IF;
            finalization_action :=
                strategy_training.prepare_cross_fit_fold_finalization_task(
                    execution_record.cross_fit_execution_id, latest_fold);
            IF finalization_action <> 'FOLD_FINALIZED' THEN
                action := finalization_action; RETURN NEXT; CONTINUE;
            END IF;
        END IF;
        SELECT * INTO task_record FROM strategy_training.training_tasks task
        WHERE task.experiment_id = execution_record.experiment_id
          AND task.task_type = 'CROSS_FIT_COORDINATE'
          AND task.task_payload ->> 'execution_id' =
              execution_record.cross_fit_execution_id::text
          AND (task.task_payload ->> 'fold_number')::integer = next_fold;
        IF FOUND THEN
            action := CASE task_record.state
                WHEN 'SUCCEEDED' THEN 'COORDINATION_COMPLETED'
                WHEN 'FAILED' THEN 'COORDINATION_FAILED'
                ELSE 'WAITING_COORDINATION' END;
            RETURN NEXT; CONTINUE;
        END IF;
        PERFORM strategy_training.enqueue_training_task(
            execution_record.experiment_id, NULL, NULL, NULL,
            'CROSS_FIT_COORDINATE', 'EVALUATOR',
            encode(digest(concat_ws('|', execution_record.cross_fit_execution_id::text,
                next_fold::text, 'CROSS_FIT_COORDINATE_V1'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'CROSS_FIT_COORDINATE',
                'payload_version', 1,
                'execution_id', execution_record.cross_fit_execution_id::text,
                'fold_number', next_fold), 20);
        action := 'COORDINATION_ENQUEUED'; RETURN NEXT;
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.finalize_cross_fit_fold(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.prepare_cross_fit_fold_finalization_task(uuid, integer)
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.finalize_cross_fit_fold(uuid, uuid),
    strategy_training.prepare_cross_fit_fold_finalization_task(uuid, integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.finalize_cross_fit_fold(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.prepare_cross_fit_fold_finalization_task(uuid, integer)
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '081_training_cross_fit_fold_finalization',
    encode(digest('auto_trade_v2_081_training_cross_fit_fold_finalization_v1',
        'sha256'), 'hex'),
    'Finalize paired Cross-fit folds without registering temporary model versions'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
