\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_tasks
DROP CONSTRAINT training_tasks_task_type_check;
ALTER TABLE strategy_training.training_tasks
ADD CONSTRAINT training_tasks_task_type_check CHECK (task_type IN (
    'DATASET_BUILD', 'MODEL_A_CANDIDATE_SCAN', 'MODEL_A_EVALUATION',
    'MODEL_A_L0_AGGREGATION', 'MODEL_B_PREPARE_CANDIDATE',
    'MODEL_B_REPLAY', 'PORTFOLIO_EVALUATION', 'OPTIMIZER_TRIAL',
    'ARCHIVE_VERIFY', 'CROSS_FIT_COORDINATE', 'CROSS_FIT_PREDICT',
    'CROSS_FIT_FINALIZE_FOLD', 'CROSS_FIT_FINALIZE_CORPUS',
    'CROSS_FIT_EVALUATE_GATE', 'CROSS_FIT_MODEL_B_FINALIZE_FOLD'
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
        WHEN 'MODEL_B_PREPARE_CANDIDATE' THEN 'EVALUATOR'
        WHEN 'MODEL_B_REPLAY' THEN 'MODEL_B'
        WHEN 'PORTFOLIO_EVALUATION' THEN 'EVALUATOR'
        WHEN 'OPTIMIZER_TRIAL' THEN 'OPTIMIZER'
        WHEN 'ARCHIVE_VERIFY' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_COORDINATE' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_PREDICT' THEN 'WORKER'
        WHEN 'CROSS_FIT_FINALIZE_FOLD' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_FINALIZE_CORPUS' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_EVALUATE_GATE' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_MODEL_B_FINALIZE_FOLD' THEN 'EVALUATOR'
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

CREATE FUNCTION strategy_training.finalize_cross_fit_model_b_fold_task(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        fold_record strategy_training.training_cross_fit_model_b_fold_runs%ROWTYPE;
        result_hash char(64); payload_execution_id uuid; payload_fold_number integer;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'CROSS_FIT_MODEL_B_FINALIZE_FOLD'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL
       OR task_record.task_payload <> jsonb_build_object(
            'task_type', 'CROSS_FIT_MODEL_B_FINALIZE_FOLD',
            'payload_version', 1,
            'execution_id', task_record.task_payload ->> 'execution_id',
            'fold_number', (task_record.task_payload ->> 'fold_number')::integer
       ) THEN
        RAISE EXCEPTION 'Model-B fold finalization requires its exact evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    BEGIN
        payload_execution_id := (task_record.task_payload ->> 'execution_id')::uuid;
        payload_fold_number := (task_record.task_payload ->> 'fold_number')::integer;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'invalid Model-B fold finalization payload'
            USING ERRCODE = '22023';
    END;
    SELECT * INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_model_b_fold_runs
    WHERE cross_fit_execution_id = payload_execution_id
      AND outer_fold_number = payload_fold_number FOR UPDATE;
    IF fold_record.state <> 'EVALUATING'
       OR fold_record.evaluation_experiment_id <> task_record.experiment_id
       OR fold_record.evaluation_iteration_id <> task_record.iteration_id THEN
        RAISE EXCEPTION 'finalization task is outside its Model-B fold boundary'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_tasks replay
        WHERE replay.experiment_id = fold_record.evaluation_experiment_id
          AND replay.iteration_id = fold_record.evaluation_iteration_id
          AND replay.task_type = 'MODEL_B_REPLAY'
    ) OR EXISTS (
        SELECT 1 FROM strategy_training.training_tasks replay
        WHERE replay.experiment_id = fold_record.evaluation_experiment_id
          AND replay.iteration_id = fold_record.evaluation_iteration_id
          AND replay.task_type = 'MODEL_B_REPLAY'
          AND replay.state <> 'SUCCEEDED'
    ) OR EXISTS (
        SELECT 1 FROM strategy_training.training_exit_episode_inputs episode
        WHERE episode.model_b_iteration_id = fold_record.evaluation_iteration_id
          AND episode.status <> 'DECIDED'
    ) THEN
        RAISE EXCEPTION 'Model-B fold replay evidence is not complete'
            USING ERRCODE = '55000';
    END IF;
    result_hash := strategy_training.finalize_cross_fit_model_b_fold_evidence(
        payload_execution_id, payload_fold_number);
    PERFORM strategy_training.transition_training_iteration(
        fold_record.evaluation_iteration_id, 'RUNNING', 'SUCCEEDED', NULL,
        result_hash, NULL, 'training-model-b-evaluator',
        'independent fold-out evidence complete', gen_random_uuid());
    PERFORM strategy_training.transition_training_experiment(
        fold_record.evaluation_experiment_id, 'RUNNING', 'STOPPED', NULL,
        'training-model-b-evaluator',
        'independent fold-out evaluation complete', gen_random_uuid());
    RETURN result_hash;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_cross_fit_model_b_nested_searches()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; next_fold integer; task_id uuid;
BEGIN
    FOR candidate IN
        SELECT fold_run.cross_fit_execution_id, fold_run.outer_fold_number
        FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        JOIN strategy_training.training_cross_fit_model_b_gate_runs gate_run
          ON gate_run.cross_fit_execution_id = fold_run.cross_fit_execution_id
         AND gate_run.state = 'RUNNING'
        JOIN strategy_training.training_optimizer_runs tpe
          ON tpe.optimizer_run_id = fold_run.tpe_optimizer_run_id
         AND tpe.state = 'SUCCEEDED'
        JOIN strategy_training.training_optimizer_runs random_control
          ON random_control.optimizer_run_id = fold_run.random_optimizer_run_id
         AND random_control.state = 'SUCCEEDED'
        WHERE fold_run.state = 'SEARCHING'
        ORDER BY fold_run.created_at, fold_run.outer_fold_number
    LOOP
        PERFORM strategy_training.prepare_cross_fit_model_b_fold_evaluation(
            candidate.cross_fit_execution_id, candidate.outer_fold_number);
        cross_fit_execution_id := candidate.cross_fit_execution_id;
        action := format('FOLD_%s_EVALUATION_CREATED', candidate.outer_fold_number);
        RETURN NEXT;
    END LOOP;

    FOR candidate IN
        SELECT fold_run.cross_fit_execution_id, fold_run.outer_fold_number,
               fold_run.evaluation_experiment_id,
               fold_run.evaluation_iteration_id
        FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        JOIN strategy_training.training_cross_fit_model_b_gate_runs gate_run
          ON gate_run.cross_fit_execution_id = fold_run.cross_fit_execution_id
         AND gate_run.state = 'RUNNING'
        WHERE fold_run.state = 'EVALUATING'
          AND NOT EXISTS (
              SELECT 1 FROM strategy_training.training_tasks replay
              WHERE replay.experiment_id = fold_run.evaluation_experiment_id
                AND replay.iteration_id = fold_run.evaluation_iteration_id
                AND replay.task_type = 'MODEL_B_REPLAY'
                AND replay.state <> 'SUCCEEDED')
          AND EXISTS (
              SELECT 1 FROM strategy_training.training_tasks replay
              WHERE replay.experiment_id = fold_run.evaluation_experiment_id
                AND replay.iteration_id = fold_run.evaluation_iteration_id
                AND replay.task_type = 'MODEL_B_REPLAY')
          AND NOT EXISTS (
              SELECT 1 FROM strategy_training.training_tasks finalizer
              WHERE finalizer.experiment_id = fold_run.evaluation_experiment_id
                AND finalizer.iteration_id = fold_run.evaluation_iteration_id
                AND finalizer.task_type = 'CROSS_FIT_MODEL_B_FINALIZE_FOLD')
        ORDER BY fold_run.created_at, fold_run.outer_fold_number
    LOOP
        task_id := strategy_training.enqueue_training_task(
            candidate.evaluation_experiment_id,
            candidate.evaluation_iteration_id, NULL, NULL,
            'CROSS_FIT_MODEL_B_FINALIZE_FOLD', 'EVALUATOR',
            encode(digest(concat_ws('|', candidate.cross_fit_execution_id,
                candidate.outer_fold_number,
                'CROSS_FIT_MODEL_B_FINALIZE_FOLD'), 'sha256'), 'hex'),
            jsonb_build_object(
                'task_type', 'CROSS_FIT_MODEL_B_FINALIZE_FOLD',
                'payload_version', 1,
                'execution_id', candidate.cross_fit_execution_id::text,
                'fold_number', candidate.outer_fold_number), 10);
        cross_fit_execution_id := candidate.cross_fit_execution_id;
        action := format('FOLD_%s_FINALIZATION_ENQUEUED',
                         candidate.outer_fold_number);
        RETURN NEXT;
    END LOOP;

    FOR candidate IN
        SELECT gate_run.cross_fit_execution_id
        FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
        WHERE gate_run.state = 'RUNNING'
          AND EXISTS (
              SELECT 1
              FROM strategy_training.training_cross_fit_model_b_fold_runs completed
              WHERE completed.cross_fit_execution_id = gate_run.cross_fit_execution_id
                AND completed.state = 'SUCCEEDED')
          AND NOT EXISTS (
              SELECT 1
              FROM strategy_training.training_cross_fit_model_b_fold_runs active
              WHERE active.cross_fit_execution_id = gate_run.cross_fit_execution_id
                AND active.state IN ('SEARCHING', 'EVALUATING'))
        ORDER BY gate_run.created_at
    LOOP
        SELECT min(eligibility.outer_fold_number) INTO next_fold
        FROM strategy_training.training_cross_fit_model_b_fold_eligibility eligibility
        WHERE eligibility.cross_fit_execution_id = candidate.cross_fit_execution_id
          AND eligibility.eligibility = 'ELIGIBLE'
          AND NOT EXISTS (
              SELECT 1
              FROM strategy_training.training_cross_fit_model_b_fold_runs existing
              WHERE existing.cross_fit_execution_id = candidate.cross_fit_execution_id
                AND existing.outer_fold_number = eligibility.outer_fold_number);
        IF next_fold IS NOT NULL THEN
            PERFORM strategy_training.create_cross_fit_model_b_nested_fold_pair(
                candidate.cross_fit_execution_id, next_fold);
            cross_fit_execution_id := candidate.cross_fit_execution_id;
            action := format('FOLD_%s_SEARCH_CREATED', next_fold);
            RETURN NEXT;
        END IF;
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.enforce_training_task_payload_contract()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_cross_fit_model_b_fold_task(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_cross_fit_model_b_nested_searches()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.finalize_cross_fit_model_b_fold_task(uuid, uuid),
    strategy_training.advance_cross_fit_model_b_nested_searches()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_cross_fit_model_b_fold_task(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.advance_cross_fit_model_b_nested_searches()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES ('093_training_cross_fit_model_b_fold_finalization',
    encode(digest('auto_trade_v2_093_training_cross_fit_model_b_fold_finalization_v1',
                  'sha256'), 'hex'),
    'Finalize independent Model-B folds under evaluator leases and advance eligible folds')
ON CONFLICT (version) DO NOTHING;

COMMIT;
