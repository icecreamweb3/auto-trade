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
    'CROSS_FIT_PREDICT', 'CROSS_FIT_FINALIZE_FOLD',
    'CROSS_FIT_FINALIZE_CORPUS'
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
        WHEN 'CROSS_FIT_FINALIZE_CORPUS' THEN 'EVALUATOR'
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

CREATE FUNCTION strategy_training.finalize_cross_fit_candidate_corpus(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        protocol_json jsonb; requested_execution_id uuid; corpus_id uuid;
        minimum_events_per_fold integer; fold_count integer; day_count integer;
        event_count bigint; expected_event_count bigint; evidence_hash char(64);
        corpus_hash char(64); existing_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'CROSS_FIT_FINALIZE_CORPUS'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.task_payload ->> 'task_type' <> 'CROSS_FIT_FINALIZE_CORPUS'
       OR task_record.task_payload ->> 'payload_version' <> '1'
       OR (SELECT count(*) FROM jsonb_object_keys(task_record.task_payload)) <> 3 THEN
        RAISE EXCEPTION 'candidate corpus finalization requires its exact active lease'
            USING ERRCODE = '40001';
    END IF;
    requested_execution_id := (task_record.task_payload ->> 'execution_id')::uuid;
    SELECT corpus.corpus_hash INTO existing_hash
    FROM strategy_training.training_cross_fit_corpora corpus
    WHERE corpus.cross_fit_execution_id = requested_execution_id
      AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE';
    IF FOUND THEN RETURN existing_hash; END IF;
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = requested_execution_id
      AND experiment_id = task_record.experiment_id FOR UPDATE;
    IF execution_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'candidate corpus requires a RUNNING Cross-fit execution'
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
    SELECT config_json INTO STRICT protocol_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id
      AND config_type = 'CROSS_FIT_PROTOCOL' AND status = 'READY';
    minimum_events_per_fold := (
        protocol_json #>> '{q036_go_no_go,minimum_complete_events_per_fold}'
    )::integer;

    WITH eligible_folds AS MATERIALIZED (
        SELECT fold_execution.cross_fit_fold_id, tpe.cross_fit_prediction_id,
               tpe_report.evaluable_signal_count
        FROM strategy_training.training_cross_fit_fold_executions fold_execution
        JOIN strategy_training.training_cross_fit_folds fold USING (cross_fit_fold_id)
        JOIN strategy_training.training_cross_fit_predictions tpe
          ON tpe.cross_fit_execution_id = fold_execution.cross_fit_execution_id
         AND tpe.outer_fold_number = fold.outer_fold_number
         AND tpe.optimizer_role = 'TPE'
        JOIN strategy_training.training_cross_fit_predictions random_prediction
          ON random_prediction.cross_fit_execution_id =
             fold_execution.cross_fit_execution_id
         AND random_prediction.outer_fold_number = fold.outer_fold_number
         AND random_prediction.optimizer_role = 'RANDOM'
        JOIN strategy_training.training_cross_fit_prediction_coverage_reports tpe_report
          ON tpe_report.cross_fit_prediction_id = tpe.cross_fit_prediction_id
        JOIN strategy_training.training_cross_fit_prediction_coverage_reports random_report
          ON random_report.cross_fit_prediction_id =
             random_prediction.cross_fit_prediction_id
        WHERE fold_execution.cross_fit_execution_id = requested_execution_id
          AND fold.status = 'SUCCEEDED'
          AND (fold.qualification_report ->> 'fitting_sample_qualified')::boolean
          AND tpe_report.power_status = 'READY'
          AND random_report.power_status = 'READY'
          AND tpe_report.evaluable_signal_count >= minimum_events_per_fold
          AND random_report.evaluable_signal_count >= minimum_events_per_fold
    ), candidate_events AS MATERIALIZED (
        SELECT entry.entry_event_id, entry.signal_time
        FROM eligible_folds eligible
        JOIN strategy_training.training_cross_fit_predictions prediction
          ON prediction.cross_fit_prediction_id = eligible.cross_fit_prediction_id
        JOIN strategy_training.training_entry_events entry
          ON entry.generating_iteration_id = prediction.selected_iteration_id
         AND entry.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
         AND entry.entry_use = 'GO_NO_GO' AND entry.status = 'COMPLETE'
         AND entry.signal_time >= prediction.prediction_start_at
         AND entry.signal_time < prediction.prediction_end_at
        JOIN strategy_training.training_entry_outcomes outcome
          ON outcome.entry_event_id = entry.entry_event_id AND outcome.is_complete
        JOIN strategy_training.training_random_entry_baselines baseline
          ON baseline.matched_entry_event_id = entry.entry_event_id
    )
    SELECT (SELECT count(*) FROM eligible_folds),
           (SELECT count(DISTINCT signal_time::date) FROM candidate_events),
           (SELECT count(*) FROM candidate_events),
           (SELECT COALESCE(sum(evaluable_signal_count), 0) FROM eligible_folds),
           (SELECT encode(digest(COALESCE(string_agg(entry_event_id, ''
                    ORDER BY entry_event_id), ''), 'sha256'), 'hex')
              FROM candidate_events)
    INTO fold_count, day_count, event_count, expected_event_count, corpus_hash;
    IF event_count <> expected_event_count THEN
        RAISE EXCEPTION 'candidate corpus does not match frozen evaluable event facts'
            USING ERRCODE = '23514';
    END IF;
    evidence_hash := encode(digest(jsonb_build_object(
        'corpus_hash', corpus_hash, 'effective_day_count', day_count,
        'effective_fold_count', fold_count, 'event_count', event_count,
        'execution_id', requested_execution_id,
        'minimum_complete_event_count', execution_record.minimum_event_count,
        'minimum_effective_days', execution_record.minimum_effective_days,
        'minimum_effective_folds', execution_record.minimum_effective_folds
    )::text, 'sha256'), 'hex');
    IF fold_count < execution_record.minimum_effective_folds
       OR day_count < execution_record.minimum_effective_days
       OR event_count < execution_record.minimum_event_count THEN
        UPDATE strategy_training.training_cross_fit_executions
        SET state = 'INSUFFICIENT_POWER', failure_code = 'INSUFFICIENT_POWER',
            completed_at = clock_timestamp(), lease_token = NULL,
            leased_by = NULL, lease_expires_at = NULL
        WHERE cross_fit_execution_id = requested_execution_id;
        RETURN evidence_hash;
    END IF;
    corpus_id := gen_random_uuid();
    INSERT INTO strategy_training.training_cross_fit_corpora (
        cross_fit_corpus_id, cross_fit_execution_id, source, corpus_use,
        event_count, effective_fold_count, effective_day_count, corpus_hash
    ) VALUES (
        corpus_id, requested_execution_id, 'CROSS_FIT_MODEL_A_CANDIDATE',
        'GO_NO_GO', event_count, fold_count, day_count, corpus_hash
    );
    INSERT INTO strategy_training.training_cross_fit_corpus_events (
        cross_fit_corpus_id, entry_event_id, declared_source, declared_use
    )
    SELECT corpus_id, entry.entry_event_id,
           'CROSS_FIT_MODEL_A_CANDIDATE', 'GO_NO_GO'
    FROM strategy_training.training_cross_fit_fold_executions fold_execution
    JOIN strategy_training.training_cross_fit_folds fold USING (cross_fit_fold_id)
    JOIN strategy_training.training_cross_fit_predictions prediction
      ON prediction.cross_fit_execution_id = fold_execution.cross_fit_execution_id
     AND prediction.outer_fold_number = fold.outer_fold_number
     AND prediction.optimizer_role = 'TPE'
    JOIN strategy_training.training_cross_fit_prediction_coverage_reports tpe_report
      ON tpe_report.cross_fit_prediction_id = prediction.cross_fit_prediction_id
    JOIN strategy_training.training_cross_fit_predictions random_prediction
      ON random_prediction.cross_fit_execution_id = fold_execution.cross_fit_execution_id
     AND random_prediction.outer_fold_number = fold.outer_fold_number
     AND random_prediction.optimizer_role = 'RANDOM'
    JOIN strategy_training.training_cross_fit_prediction_coverage_reports random_report
      ON random_report.cross_fit_prediction_id = random_prediction.cross_fit_prediction_id
    JOIN strategy_training.training_entry_events entry
      ON entry.generating_iteration_id = prediction.selected_iteration_id
     AND entry.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
     AND entry.entry_use = 'GO_NO_GO' AND entry.status = 'COMPLETE'
     AND entry.signal_time >= prediction.prediction_start_at
     AND entry.signal_time < prediction.prediction_end_at
    JOIN strategy_training.training_entry_outcomes outcome
      ON outcome.entry_event_id = entry.entry_event_id AND outcome.is_complete
    JOIN strategy_training.training_random_entry_baselines baseline
      ON baseline.matched_entry_event_id = entry.entry_event_id
    WHERE fold_execution.cross_fit_execution_id = requested_execution_id
      AND fold.status = 'SUCCEEDED'
      AND (fold.qualification_report ->> 'fitting_sample_qualified')::boolean
      AND tpe_report.power_status = 'READY' AND random_report.power_status = 'READY'
      AND tpe_report.evaluable_signal_count >= minimum_events_per_fold
      AND random_report.evaluable_signal_count >= minimum_events_per_fold;
    UPDATE strategy_training.training_cross_fit_executions
    SET state = 'CANDIDATE_READY', lease_token = NULL,
        leased_by = NULL, lease_expires_at = NULL
    WHERE cross_fit_execution_id = requested_execution_id;
    RETURN evidence_hash;
END
$$;

CREATE FUNCTION strategy_training.prepare_cross_fit_candidate_corpus_task(
    p_cross_fit_execution_id uuid
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
    IF execution_record.state = 'CANDIDATE_READY' THEN RETURN 'CANDIDATE_READY'; END IF;
    IF execution_record.state = 'INSUFFICIENT_POWER' THEN
        RETURN 'INSUFFICIENT_POWER';
    END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks task
    WHERE task.experiment_id = execution_record.experiment_id
      AND task.task_type = 'CROSS_FIT_FINALIZE_CORPUS'
      AND task.task_payload ->> 'execution_id' = p_cross_fit_execution_id::text;
    IF FOUND THEN
        IF task_record.state IN ('FAILED', 'CANCELLED') THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'CORPUS_FINALIZATION_FAILED',
                completed_at = clock_timestamp(), lease_token = NULL,
                leased_by = NULL, lease_expires_at = NULL
            WHERE cross_fit_execution_id = p_cross_fit_execution_id;
            RETURN 'EXECUTION_FAILED';
        END IF;
        RETURN 'WAITING_CANDIDATE_CORPUS';
    END IF;
    PERFORM strategy_training.enqueue_training_task(
        execution_record.experiment_id, NULL, NULL, NULL,
        'CROSS_FIT_FINALIZE_CORPUS', 'EVALUATOR',
        encode(digest(concat_ws('|', p_cross_fit_execution_id::text,
            'CROSS_FIT_FINALIZE_CORPUS_V1'), 'sha256'), 'hex'),
        jsonb_build_object('task_type', 'CROSS_FIT_FINALIZE_CORPUS',
            'payload_version', 1,
            'execution_id', p_cross_fit_execution_id::text), 20
    );
    RETURN 'CANDIDATE_CORPUS_ENQUEUED';
END
$$;

-- The 081 progression is replaced so the end of the frozen TRAIN interval is
-- a normal transition, not a failed attempt to create a non-existent fold.
CREATE OR REPLACE FUNCTION strategy_training.advance_training_cross_fit_executions()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        timed_out_run strategy_training.training_optimizer_runs%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        latest_fold integer; next_fold integer; prediction_days integer;
        last_prediction_end timestamptz;
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
        SELECT COALESCE(max(scope.outer_fold_number), 0),
               max(scope.prediction_end_at)
        INTO latest_fold, last_prediction_end
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
            SELECT * INTO STRICT dataset_record
            FROM strategy_training.training_dataset_versions
            WHERE dataset_version_id = execution_record.dataset_version_id;
            SELECT (config.config_json #>>
                    '{q030_cross_fit,prediction_signal_window_days}')::integer
            INTO STRICT prediction_days
            FROM strategy_training.training_config_versions config
            WHERE config.config_version_id = execution_record.protocol_config_version_id;
            IF last_prediction_end + make_interval(days => prediction_days)
               > dataset_record.eligible_end_at THEN
                action := strategy_training.prepare_cross_fit_candidate_corpus_task(
                    execution_record.cross_fit_execution_id);
                RETURN NEXT; CONTINUE;
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

ALTER FUNCTION strategy_training.finalize_cross_fit_candidate_corpus(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.prepare_cross_fit_candidate_corpus_task(uuid)
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.finalize_cross_fit_candidate_corpus(uuid, uuid),
    strategy_training.prepare_cross_fit_candidate_corpus_task(uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_cross_fit_candidate_corpus(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.prepare_cross_fit_candidate_corpus_task(uuid)
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '082_training_cross_fit_candidate_corpus',
    encode(digest('auto_trade_v2_082_training_cross_fit_candidate_corpus_v1',
        'sha256'), 'hex'),
    'Finalize the fixed TPE candidate corpus at the natural end of Cross-fit folds'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
