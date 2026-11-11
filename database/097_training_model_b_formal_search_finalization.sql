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
    'MODEL_B_REPLAY', 'MODEL_B_FINALIZE_FORMAL', 'PORTFOLIO_EVALUATION',
    'OPTIMIZER_TRIAL', 'ARCHIVE_VERIFY', 'CROSS_FIT_COORDINATE',
    'CROSS_FIT_PREDICT', 'CROSS_FIT_FINALIZE_FOLD',
    'CROSS_FIT_FINALIZE_CORPUS', 'CROSS_FIT_EVALUATE_GATE',
    'CROSS_FIT_MODEL_B_FINALIZE_FOLD', 'CROSS_FIT_MODEL_B_FINALIZE_GATE'
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
        WHEN 'MODEL_B_FINALIZE_FORMAL' THEN 'EVALUATOR'
        WHEN 'PORTFOLIO_EVALUATION' THEN 'EVALUATOR'
        WHEN 'OPTIMIZER_TRIAL' THEN 'OPTIMIZER'
        WHEN 'ARCHIVE_VERIFY' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_COORDINATE' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_PREDICT' THEN 'WORKER'
        WHEN 'CROSS_FIT_FINALIZE_FOLD' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_FINALIZE_CORPUS' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_EVALUATE_GATE' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_MODEL_B_FINALIZE_FOLD' THEN 'EVALUATOR'
        WHEN 'CROSS_FIT_MODEL_B_FINALIZE_GATE' THEN 'EVALUATOR'
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

ALTER TABLE strategy_training.training_model_b_formal_search_runs
ADD COLUMN failure_code varchar(64),
ADD COLUMN completed_at timestamptz,
ADD CONSTRAINT training_model_b_formal_search_runs_terminal_check CHECK (
    (state IN ('CREATED', 'RUNNING') AND failure_code IS NULL
                                      AND completed_at IS NULL)
    OR (state = 'SUCCEEDED' AND failure_code IS NULL
                            AND completed_at IS NOT NULL)
    OR (state IN ('FAILED', 'CANCELLED')
        AND failure_code IS NOT NULL AND btrim(failure_code) <> ''
        AND completed_at IS NOT NULL)
);

CREATE TABLE strategy_training.training_model_b_formal_search_comparisons (
    formal_search_run_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_model_b_formal_search_runs,
    finalist_count integer NOT NULL CHECK (finalist_count > 0),
    comparison_report jsonb NOT NULL CHECK (
        jsonb_typeof(comparison_report) = 'object'
        AND comparison_report <> '{}'::jsonb
    ),
    evidence_hash char(64) NOT NULL CHECK (
        evidence_hash ~ '^[0-9a-f]{64}$'
        AND evidence_hash = encode(digest(comparison_report::text, 'sha256'), 'hex')
    ),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE strategy_training.training_model_b_formal_search_finalists (
    formal_search_run_id uuid NOT NULL
        REFERENCES strategy_training.training_model_b_formal_search_runs,
    finalist_rank integer NOT NULL CHECK (finalist_rank > 0),
    iteration_id uuid NOT NULL UNIQUE REFERENCES strategy_training.training_iterations,
    train_objective numeric NOT NULL CHECK (train_objective <> 'NaN'::numeric),
    candidate_content_hash char(64) NOT NULL CHECK (
        candidate_content_hash ~ '^[0-9a-f]{64}$'
    ),
    train_evidence_hash char(64) NOT NULL CHECK (
        train_evidence_hash ~ '^[0-9a-f]{64}$'
    ),
    finalist_evidence_hash char(64) NOT NULL CHECK (
        finalist_evidence_hash ~ '^[0-9a-f]{64}$'
    ),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (formal_search_run_id, finalist_rank),
    UNIQUE (formal_search_run_id, candidate_content_hash)
);

CREATE TRIGGER trg_training_model_b_formal_search_comparisons_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_model_b_formal_search_comparisons
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_model_b_formal_search_finalists_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_model_b_formal_search_finalists
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.finalize_training_model_b_formal_search(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        formal_record strategy_training.training_model_b_formal_search_runs%ROWTYPE;
        tpe_record strategy_training.training_optimizer_runs%ROWTYPE;
        random_record strategy_training.training_optimizer_runs%ROWTYPE;
        requested_run_id uuid; protocol_json jsonb; finalist_limit integer;
        tpe_result_count integer; random_result_count integer;
        tpe_complete_count integer; random_complete_count integer;
        tpe_unique_complete_count integer;
        best_tpe_iteration_id uuid; best_random_iteration_id uuid;
        best_tpe_objective numeric; best_random_objective numeric;
        baseline_objective numeric; tpe_chain char(64); random_chain char(64);
        finalist_manifest_hash char(64); report jsonb; persisted_hash char(64);
        inserted_finalists integer; existing_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_B_FINALIZE_FORMAL'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NOT NULL
       OR task_record.optimizer_run_id IS NOT NULL
       OR task_record.task_payload ->> 'task_type' <> 'MODEL_B_FINALIZE_FORMAL'
       OR task_record.task_payload ->> 'payload_version' <> '1'
       OR (SELECT count(*) FROM jsonb_object_keys(task_record.task_payload)) <> 3 THEN
        RAISE EXCEPTION 'formal Model-B finalization requires its exact evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    BEGIN
        requested_run_id :=
            (task_record.task_payload ->> 'formal_search_run_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'invalid formal Model-B finalization payload'
            USING ERRCODE = '22023';
    END;
    SELECT comparison.evidence_hash INTO existing_hash
    FROM strategy_training.training_model_b_formal_search_comparisons comparison
    JOIN strategy_training.training_model_b_formal_search_runs formal
      ON formal.formal_search_run_id = comparison.formal_search_run_id
     AND formal.state = 'SUCCEEDED'
    WHERE comparison.formal_search_run_id = requested_run_id
      AND formal.experiment_id = task_record.experiment_id;
    IF FOUND THEN RETURN existing_hash; END IF;

    SELECT * INTO STRICT formal_record
    FROM strategy_training.training_model_b_formal_search_runs formal
    WHERE formal.formal_search_run_id = requested_run_id
      AND formal.experiment_id = task_record.experiment_id
      AND formal.state = 'CREATED' FOR UPDATE;
    SELECT * INTO STRICT tpe_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = formal_record.tpe_optimizer_run_id;
    SELECT * INTO STRICT random_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = formal_record.random_optimizer_run_id;
    IF tpe_record.state <> 'SUCCEEDED' OR random_record.state <> 'SUCCEEDED'
       OR tpe_record.trial_budget <> random_record.trial_budget
       OR tpe_record.search_space_config_version_id <>
          random_record.search_space_config_version_id THEN
        RAISE EXCEPTION 'formal comparison requires completed equal-budget frozen searches'
            USING ERRCODE = '55000';
    END IF;
    SELECT config.config_json INTO STRICT protocol_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'CROSS_FIT_PROTOCOL' AND config.status = 'READY'
    WHERE binding.experiment_id = formal_record.experiment_id
      AND binding.config_type = 'CROSS_FIT_PROTOCOL';
    finalist_limit := (protocol_json #>>
                      '{q019_search_budget,fixed_finalist_count}')::integer;
    IF finalist_limit <= 0 OR finalist_limit > tpe_record.trial_budget THEN
        RAISE EXCEPTION 'formal finalist count violates the frozen Q-019 budget'
            USING ERRCODE = '23514';
    END IF;

    SELECT count(*)::integer,
           count(*) FILTER (WHERE trial_state = 'COMPLETE')::integer,
           encode(digest(COALESCE(string_agg(result_hash, '' ORDER BY trial_number), ''),
                         'sha256'), 'hex')
    INTO tpe_result_count, tpe_complete_count, tpe_chain
    FROM strategy_training.training_optimizer_trial_results
    WHERE optimizer_run_id = tpe_record.optimizer_run_id;
    SELECT count(*)::integer,
           count(*) FILTER (WHERE trial_state = 'COMPLETE')::integer,
           encode(digest(COALESCE(string_agg(result_hash, '' ORDER BY trial_number), ''),
                         'sha256'), 'hex')
    INTO random_result_count, random_complete_count, random_chain
    FROM strategy_training.training_optimizer_trial_results
    WHERE optimizer_run_id = random_record.optimizer_run_id;
    SELECT count(DISTINCT candidate_content_hash)::integer
    INTO tpe_unique_complete_count
    FROM strategy_training.training_optimizer_trial_results
    WHERE optimizer_run_id = tpe_record.optimizer_run_id
      AND trial_state = 'COMPLETE';
    IF tpe_result_count <> tpe_record.trial_budget
       OR random_result_count <> random_record.trial_budget
       OR tpe_complete_count < finalist_limit
       OR tpe_unique_complete_count < finalist_limit THEN
        RAISE EXCEPTION 'formal comparison lacks its complete budget or TPE finalists'
            USING ERRCODE = '23514';
    END IF;

    SELECT result.iteration_id, result.train_objective
    INTO STRICT best_tpe_iteration_id, best_tpe_objective
    FROM strategy_training.training_optimizer_trial_results result
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = result.iteration_id
     AND iteration.state = 'SUCCEEDED'
    WHERE result.optimizer_run_id = tpe_record.optimizer_run_id
      AND result.trial_state = 'COMPLETE'
    ORDER BY result.train_objective DESC, result.trial_number,
             result.candidate_content_hash, result.iteration_id
    LIMIT 1;
    SELECT result.iteration_id, result.train_objective
    INTO best_random_iteration_id, best_random_objective
    FROM strategy_training.training_optimizer_trial_results result
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = result.iteration_id
     AND iteration.state = 'SUCCEEDED'
    WHERE result.optimizer_run_id = random_record.optimizer_run_id
      AND result.trial_state = 'COMPLETE'
    ORDER BY result.train_objective DESC, result.trial_number,
             result.candidate_content_hash, result.iteration_id
    LIMIT 1;
    SELECT (baseline.baseline_metrics ->>
            'net_expectancy_percentage_points')::numeric
    INTO STRICT baseline_objective
    FROM strategy_training.training_go_no_go_round_zero_baselines baseline
    WHERE baseline.go_no_go_evaluation_id = formal_record.go_no_go_evaluation_id;

    INSERT INTO strategy_training.training_model_b_formal_search_finalists (
        formal_search_run_id, finalist_rank, iteration_id, train_objective,
        candidate_content_hash, train_evidence_hash, finalist_evidence_hash
    )
    SELECT formal_record.formal_search_run_id, ranked.finalist_rank,
           ranked.iteration_id, ranked.train_objective,
           ranked.candidate_content_hash, ranked.train_evidence_hash,
           encode(digest(concat_ws('|', formal_record.formal_search_run_id,
               ranked.finalist_rank, ranked.iteration_id,
               ranked.train_objective, ranked.candidate_content_hash,
               ranked.train_evidence_hash), 'sha256'), 'hex')
    FROM (
        SELECT unique_result.iteration_id, unique_result.train_objective,
               unique_result.candidate_content_hash,
               unique_result.train_evidence_hash,
               row_number() OVER (ORDER BY unique_result.train_objective DESC,
                   unique_result.trial_number,
                   unique_result.candidate_content_hash,
                   unique_result.iteration_id)::integer AS finalist_rank
        FROM (
            SELECT DISTINCT ON (result.candidate_content_hash)
                   result.iteration_id, result.train_objective,
                   result.candidate_content_hash, result.train_evidence_hash,
                   result.trial_number
            FROM strategy_training.training_optimizer_trial_results result
            JOIN strategy_training.training_iterations iteration
              ON iteration.iteration_id = result.iteration_id
             AND iteration.state = 'SUCCEEDED'
            WHERE result.optimizer_run_id = tpe_record.optimizer_run_id
              AND result.trial_state = 'COMPLETE'
            ORDER BY result.candidate_content_hash,
                     result.train_objective DESC, result.trial_number,
                     result.iteration_id
        ) unique_result
    ) ranked
    WHERE ranked.finalist_rank <= finalist_limit;
    GET DIAGNOSTICS inserted_finalists = ROW_COUNT;
    IF inserted_finalists <> finalist_limit THEN
        RAISE EXCEPTION 'formal finalist manifest is incomplete'
            USING ERRCODE = '23514';
    END IF;
    SELECT encode(digest(string_agg(finalist.finalist_evidence_hash, ''
        ORDER BY finalist.finalist_rank), 'sha256'), 'hex')
    INTO STRICT finalist_manifest_hash
    FROM strategy_training.training_model_b_formal_search_finalists finalist
    WHERE finalist.formal_search_run_id = formal_record.formal_search_run_id;

    report := jsonb_build_object(
        'baseline_evidence_hash', (
            SELECT evidence_hash
            FROM strategy_training.training_go_no_go_round_zero_baselines
            WHERE go_no_go_evaluation_id = formal_record.go_no_go_evaluation_id
        ),
        'baseline_net_expectancy_percentage_points', baseline_objective,
        'best_random_iteration_id', best_random_iteration_id,
        'best_random_objective', best_random_objective,
        'best_random_excess_baseline',
            CASE WHEN best_random_objective IS NULL THEN NULL
                 ELSE best_random_objective - baseline_objective END,
        'best_tpe_iteration_id', best_tpe_iteration_id,
        'best_tpe_objective', best_tpe_objective,
        'best_tpe_excess_baseline', best_tpe_objective - baseline_objective,
        'comparison_status', CASE WHEN best_random_iteration_id IS NULL
            THEN 'RANDOM_NO_VALID_TRIAL' ELSE 'COMPLETE' END,
        'finalist_count', finalist_limit,
        'finalist_manifest_hash', finalist_manifest_hash,
        'random_complete_trial_count', random_complete_count,
        'random_result_chain_hash', random_chain,
        'random_trial_budget', random_record.trial_budget,
        'random_trial_result_count', random_result_count,
        'tpe_complete_trial_count', tpe_complete_count,
        'tpe_minus_random_objective',
            CASE WHEN best_random_objective IS NULL THEN NULL
                 ELSE best_tpe_objective - best_random_objective END,
        'tpe_result_chain_hash', tpe_chain,
        'tpe_trial_budget', tpe_record.trial_budget,
        'tpe_trial_result_count', tpe_result_count,
        'tpe_unique_complete_trial_count', tpe_unique_complete_count
    );
    persisted_hash := encode(digest(report::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_model_b_formal_search_comparisons (
        formal_search_run_id, finalist_count, comparison_report, evidence_hash
    ) VALUES (
        formal_record.formal_search_run_id, finalist_limit, report, persisted_hash
    );
    UPDATE strategy_training.training_model_b_formal_search_runs
    SET state = 'SUCCEEDED', completed_at = clock_timestamp()
    WHERE formal_search_run_id = formal_record.formal_search_run_id;
    PERFORM strategy_training.transition_training_experiment(
        formal_record.experiment_id, 'RUNNING', 'STOPPED', NULL,
        'training-model-b-evaluator',
        'formal paired search compared and finalists frozen', gen_random_uuid()
    );
    RETURN persisted_hash;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_model_b_formal_searches()
RETURNS TABLE (go_no_go_evaluation_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; task_record strategy_training.training_tasks%ROWTYPE;
        task_id uuid;
BEGIN
    FOR candidate IN
        SELECT baseline.go_no_go_evaluation_id
        FROM strategy_training.training_model_b_round_zero_baseline_runs baseline
        JOIN strategy_training.training_cross_fit_executions execution
          ON execution.cross_fit_execution_id = baseline.cross_fit_execution_id
         AND execution.state = 'FORMAL_CORPUS_READY'
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = baseline.iteration_id
         AND iteration.state = 'SUCCEEDED'
        JOIN strategy_training.training_experiments experiment
          ON experiment.experiment_id = baseline.experiment_id
         AND experiment.state = 'STOPPED'
        JOIN strategy_training.training_tasks portfolio_task
          ON portfolio_task.iteration_id = baseline.iteration_id
         AND portfolio_task.task_type = 'PORTFOLIO_EVALUATION'
         AND portfolio_task.state = 'SUCCEEDED'
        WHERE baseline.state = 'SUCCEEDED'
          AND NOT EXISTS (
              SELECT 1
              FROM strategy_training.training_model_b_formal_search_runs formal
              WHERE formal.go_no_go_evaluation_id = baseline.go_no_go_evaluation_id
          )
        ORDER BY baseline.completed_at, baseline.go_no_go_evaluation_id
    LOOP
        go_no_go_evaluation_id := candidate.go_no_go_evaluation_id;
        action := strategy_training.initialize_training_model_b_formal_search(
            candidate.go_no_go_evaluation_id
        );
        RETURN NEXT;
    END LOOP;

    FOR candidate IN
        SELECT formal.*, tpe.state AS tpe_state, random_run.state AS random_state
        FROM strategy_training.training_model_b_formal_search_runs formal
        JOIN strategy_training.training_optimizer_runs tpe
          ON tpe.optimizer_run_id = formal.tpe_optimizer_run_id
        JOIN strategy_training.training_optimizer_runs random_run
          ON random_run.optimizer_run_id = formal.random_optimizer_run_id
        WHERE formal.state = 'CREATED'
        ORDER BY formal.created_at, formal.formal_search_run_id
    LOOP
        go_no_go_evaluation_id := candidate.go_no_go_evaluation_id;
        IF candidate.tpe_state IN ('FAILED', 'CANCELLED')
           OR candidate.random_state IN ('FAILED', 'CANCELLED') THEN
            IF candidate.tpe_state IN ('CREATED', 'RUNNING', 'PAUSED') THEN
                PERFORM strategy_training.transition_training_optimizer_run(
                    candidate.tpe_optimizer_run_id, candidate.tpe_state,
                    'CANCELLED', 'FORMAL_PEER_FAILED', NULL,
                    'training-model-b-orchestrator',
                    'formal peer optimizer failed', gen_random_uuid());
            END IF;
            IF candidate.random_state IN ('CREATED', 'RUNNING', 'PAUSED') THEN
                PERFORM strategy_training.transition_training_optimizer_run(
                    candidate.random_optimizer_run_id, candidate.random_state,
                    'CANCELLED', 'FORMAL_PEER_FAILED', NULL,
                    'training-model-b-orchestrator',
                    'formal peer optimizer failed', gen_random_uuid());
            END IF;
            UPDATE strategy_training.training_model_b_formal_search_runs
            SET state = 'FAILED', failure_code = 'FORMAL_OPTIMIZER_FAILED',
                completed_at = clock_timestamp()
            WHERE formal_search_run_id = candidate.formal_search_run_id;
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator',
                'formal optimizer pair failed', gen_random_uuid());
            action := 'FORMAL_SEARCH_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        IF candidate.tpe_state <> 'SUCCEEDED'
           OR candidate.random_state <> 'SUCCEEDED' THEN
            CONTINUE;
        END IF;
        SELECT * INTO task_record
        FROM strategy_training.training_tasks task
        WHERE task.experiment_id = candidate.experiment_id
          AND task.task_type = 'MODEL_B_FINALIZE_FORMAL';
        IF NOT FOUND THEN
            task_id := strategy_training.enqueue_training_task(
                candidate.experiment_id, NULL, NULL, NULL,
                'MODEL_B_FINALIZE_FORMAL', 'EVALUATOR',
                encode(digest(concat_ws('|', candidate.formal_search_run_id,
                    'MODEL_B_FINALIZE_FORMAL'), 'sha256'), 'hex'),
                jsonb_build_object(
                    'task_type', 'MODEL_B_FINALIZE_FORMAL',
                    'payload_version', 1,
                    'formal_search_run_id', candidate.formal_search_run_id::text
                ), 10
            );
            action := 'FORMAL_FINALIZATION_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF task_record.state IN ('FAILED', 'CANCELLED') THEN
            UPDATE strategy_training.training_model_b_formal_search_runs
            SET state = 'FAILED', failure_code = 'FORMAL_FINALIZATION_FAILED',
                completed_at = clock_timestamp()
            WHERE formal_search_run_id = candidate.formal_search_run_id;
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator',
                'formal comparison or finalist freeze failed', gen_random_uuid());
            action := 'FORMAL_FINALIZATION_FAILED'; RETURN NEXT; CONTINUE;
        ELSIF task_record.state = 'SUCCEEDED' THEN
            UPDATE strategy_training.training_model_b_formal_search_runs
            SET state = 'FAILED', failure_code = 'FORMAL_EVIDENCE_MISSING',
                completed_at = clock_timestamp()
            WHERE formal_search_run_id = candidate.formal_search_run_id;
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator',
                'formal finalizer completed without evidence', gen_random_uuid());
            action := 'FORMAL_EVIDENCE_MISSING'; RETURN NEXT; CONTINUE;
        END IF;
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_model_b_formal_search_comparisons
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_b_formal_search_finalists
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.enforce_training_task_payload_contract()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_model_b_formal_search(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_b_formal_searches()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_model_b_formal_search_comparisons,
    strategy_training.training_model_b_formal_search_finalists FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.finalize_training_model_b_formal_search(uuid, uuid),
    strategy_training.advance_training_model_b_formal_searches()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_training_model_b_formal_search(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.advance_training_model_b_formal_searches()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '097_training_model_b_formal_search_finalization',
    encode(digest(
        'auto_trade_v2_097_training_model_b_formal_search_finalization_v1',
        'sha256'), 'hex'),
    'Compare formal paired search and freeze the governed Q-019 TPE finalist batch'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
