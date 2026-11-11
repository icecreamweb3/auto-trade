\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_model_b_formal_search_stop_facts (
    formal_search_run_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_model_b_formal_search_runs,
    stop_reason varchar(32) NOT NULL CHECK (stop_reason IN (
        'MAXIMUM_ITERATIONS', 'MAXIMUM_WALL_CLOCK', 'EARLY_STOPPING'
    )),
    effective_trial_count integer NOT NULL CHECK (effective_trial_count >= 0),
    maximum_iterations integer NOT NULL CHECK (maximum_iterations > 0),
    maximum_wall_clock_seconds integer NOT NULL
        CHECK (maximum_wall_clock_seconds > 0),
    elapsed_wall_clock_seconds integer NOT NULL
        CHECK (elapsed_wall_clock_seconds >= 0),
    early_stopping_not_before_iteration integer NOT NULL
        CHECK (early_stopping_not_before_iteration > 0),
    consecutive_train_no_improvement_rounds integer NOT NULL
        CHECK (consecutive_train_no_improvement_rounds > 0),
    observed_no_improvement_rounds integer NOT NULL
        CHECK (observed_no_improvement_rounds >= 0),
    last_improvement_trial_number integer,
    evidence_hash char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (effective_trial_count <= maximum_iterations),
    CHECK (
        last_improvement_trial_number IS NULL
        OR (last_improvement_trial_number >= 0
            AND last_improvement_trial_number < effective_trial_count)
    ),
    CHECK (
        (stop_reason = 'MAXIMUM_ITERATIONS'
         AND effective_trial_count = maximum_iterations)
        OR (stop_reason = 'MAXIMUM_WALL_CLOCK'
            AND elapsed_wall_clock_seconds >= maximum_wall_clock_seconds)
        OR (stop_reason = 'EARLY_STOPPING'
            AND effective_trial_count >= early_stopping_not_before_iteration
            AND observed_no_improvement_rounds >=
                consecutive_train_no_improvement_rounds)
    )
);

CREATE TRIGGER trg_training_model_b_formal_search_stop_facts_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_model_b_formal_search_stop_facts
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.govern_training_model_b_formal_search_pair(
    p_optimizer_run_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE formal_record strategy_training.training_model_b_formal_search_runs%ROWTYPE;
        tpe_record strategy_training.training_optimizer_runs%ROWTYPE;
        random_record strategy_training.training_optimizer_runs%ROWTYPE;
        protocol_json jsonb; maximum_iterations integer;
        maximum_wall_clock_seconds integer;
        early_stopping_not_before_iteration integer;
        no_improvement_limit integer; tpe_count integer; random_count integer;
        elapsed_seconds integer; last_improvement integer;
        observed_no_improvement integer; stop_reason text;
        stop_report jsonb; persisted_hash char(64);
BEGIN
    SELECT formal.* INTO formal_record
    FROM strategy_training.training_model_b_formal_search_runs formal
    WHERE p_optimizer_run_id IN (
            formal.tpe_optimizer_run_id, formal.random_optimizer_run_id
          )
      AND formal.state = 'CREATED'
    FOR UPDATE;
    IF NOT FOUND THEN RETURN 'CONTINUE'; END IF;

    SELECT * INTO STRICT tpe_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = formal_record.tpe_optimizer_run_id FOR UPDATE;
    SELECT * INTO STRICT random_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = formal_record.random_optimizer_run_id FOR UPDATE;
    IF tpe_record.state <> 'RUNNING' OR random_record.state <> 'RUNNING' THEN
        RETURN 'FORMAL_PAIR_NOT_RUNNING';
    END IF;

    SELECT config.config_json INTO STRICT protocol_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'CROSS_FIT_PROTOCOL'
     AND config.status = 'READY'
    WHERE binding.experiment_id = formal_record.experiment_id
      AND binding.config_type = 'CROSS_FIT_PROTOCOL';
    maximum_iterations := (protocol_json #>>
        '{q019_search_budget,maximum_iterations}')::integer;
    maximum_wall_clock_seconds := (protocol_json #>>
        '{q019_search_budget,maximum_wall_clock_seconds}')::integer;
    early_stopping_not_before_iteration := (protocol_json #>>
        '{q019_search_budget,early_stopping_not_before_iteration}')::integer;
    no_improvement_limit := (protocol_json #>>
        '{q019_search_budget,consecutive_train_no_improvement_rounds}')::integer;
    IF maximum_iterations <= 0
       OR maximum_iterations <> tpe_record.trial_budget
       OR maximum_iterations <> random_record.trial_budget
       OR maximum_wall_clock_seconds <= 0
       OR early_stopping_not_before_iteration <= 0
       OR early_stopping_not_before_iteration > maximum_iterations
       OR no_improvement_limit <= 0
       OR no_improvement_limit > maximum_iterations THEN
        RAISE EXCEPTION 'formal Model-B Q-019 stopping budget is invalid'
            USING ERRCODE = '23514';
    END IF;

    SELECT count(*)::integer INTO tpe_count
    FROM strategy_training.training_optimizer_trial_results
    WHERE optimizer_run_id = tpe_record.optimizer_run_id;
    SELECT count(*)::integer INTO random_count
    FROM strategy_training.training_optimizer_trial_results
    WHERE optimizer_run_id = random_record.optimizer_run_id;
    IF tpe_count <> random_count THEN
        IF (p_optimizer_run_id = tpe_record.optimizer_run_id
                AND tpe_count > random_count)
           OR (p_optimizer_run_id = random_record.optimizer_run_id
                AND random_count > tpe_count) THEN
            RETURN 'WAITING_FORMAL_PEER_ROUND';
        END IF;
        RETURN 'CONTINUE';
    END IF;

    elapsed_seconds := floor(extract(epoch FROM
        (clock_timestamp() - least(tpe_record.started_at,
                                   random_record.started_at))))::integer;
    SELECT max(scored.trial_number) INTO last_improvement
    FROM (
        SELECT result.trial_number, result.train_objective,
               max(result.train_objective) OVER (
                   ORDER BY result.trial_number
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
               ) AS prior_best
        FROM strategy_training.training_optimizer_trial_results result
        WHERE result.optimizer_run_id = tpe_record.optimizer_run_id
          AND result.trial_state = 'COMPLETE'
    ) scored
    WHERE scored.prior_best IS NULL
       OR scored.train_objective > scored.prior_best;
    observed_no_improvement := tpe_count - COALESCE(last_improvement + 1, 0);

    IF tpe_count >= maximum_iterations THEN
        stop_reason := 'MAXIMUM_ITERATIONS';
    ELSIF elapsed_seconds >= maximum_wall_clock_seconds THEN
        stop_reason := 'MAXIMUM_WALL_CLOCK';
    ELSIF tpe_count >= early_stopping_not_before_iteration
          AND observed_no_improvement >= no_improvement_limit THEN
        stop_reason := 'EARLY_STOPPING';
    ELSE
        RETURN 'CONTINUE';
    END IF;

    IF EXISTS (
        SELECT 1 FROM strategy_training.training_tasks task
        WHERE task.optimizer_run_id IN (
                tpe_record.optimizer_run_id, random_record.optimizer_run_id
              )
          AND task.state IN ('QUEUED', 'LEASED', 'RUNNING', 'PAUSED')
    ) THEN
        RETURN 'WAITING_FORMAL_INFLIGHT_ROUND';
    END IF;

    stop_report := jsonb_build_object(
        'consecutive_train_no_improvement_rounds', no_improvement_limit,
        'early_stopping_not_before_iteration',
            early_stopping_not_before_iteration,
        'effective_trial_count', tpe_count,
        'elapsed_wall_clock_seconds', elapsed_seconds,
        'formal_search_run_id', formal_record.formal_search_run_id,
        'last_improvement_trial_number', last_improvement,
        'maximum_iterations', maximum_iterations,
        'maximum_wall_clock_seconds', maximum_wall_clock_seconds,
        'observed_no_improvement_rounds', observed_no_improvement,
        'random_optimizer_run_id', random_record.optimizer_run_id,
        'stop_reason', stop_reason,
        'tpe_optimizer_run_id', tpe_record.optimizer_run_id
    );
    persisted_hash := encode(digest(stop_report::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_model_b_formal_search_stop_facts (
        formal_search_run_id, stop_reason, effective_trial_count,
        maximum_iterations, maximum_wall_clock_seconds,
        elapsed_wall_clock_seconds, early_stopping_not_before_iteration,
        consecutive_train_no_improvement_rounds,
        observed_no_improvement_rounds, last_improvement_trial_number,
        evidence_hash
    ) VALUES (
        formal_record.formal_search_run_id, stop_reason, tpe_count,
        maximum_iterations, maximum_wall_clock_seconds, elapsed_seconds,
        early_stopping_not_before_iteration, no_improvement_limit,
        observed_no_improvement, last_improvement, persisted_hash
    );
    PERFORM strategy_training.transition_training_optimizer_run(
        tpe_record.optimizer_run_id, 'RUNNING', 'SUCCEEDED', NULL, NULL,
        'training-model-b-orchestrator',
        format('formal paired search stopped: %s', stop_reason), gen_random_uuid()
    );
    PERFORM strategy_training.transition_training_optimizer_run(
        random_record.optimizer_run_id, 'RUNNING', 'SUCCEEDED', NULL, NULL,
        'training-model-b-orchestrator',
        format('formal paired comparator stopped: %s', stop_reason), gen_random_uuid()
    );
    RETURN 'FORMAL_PAIR_STOPPED_' || stop_reason;
END
$$;

ALTER FUNCTION strategy_training.advance_training_model_b_optimizer_run(uuid)
RENAME TO advance_training_model_b_optimizer_run_unbudgeted;

CREATE FUNCTION strategy_training.advance_training_model_b_optimizer_run(
    p_optimizer_run_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE budget_action text;
BEGIN
    budget_action :=
        strategy_training.govern_training_model_b_formal_search_pair(
            p_optimizer_run_id
        );
    IF budget_action <> 'CONTINUE' THEN RETURN budget_action; END IF;
    -- The delegated implementation owns MODEL_B_PREPARE_CANDIDATE and
    -- PORTFOLIO_EVALUATION after the formal pair budget gate permits a round.
    RETURN strategy_training.advance_training_model_b_optimizer_run_unbudgeted(
        p_optimizer_run_id
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_model_b_formal_search(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        formal_record strategy_training.training_model_b_formal_search_runs%ROWTYPE;
        stop_record strategy_training.training_model_b_formal_search_stop_facts%ROWTYPE;
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
    SELECT * INTO STRICT stop_record
    FROM strategy_training.training_model_b_formal_search_stop_facts
    WHERE formal_search_run_id = formal_record.formal_search_run_id;
    SELECT * INTO STRICT tpe_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = formal_record.tpe_optimizer_run_id;
    SELECT * INTO STRICT random_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = formal_record.random_optimizer_run_id;
    IF tpe_record.state <> 'SUCCEEDED' OR random_record.state <> 'SUCCEEDED'
       OR tpe_record.trial_budget <> random_record.trial_budget
       OR tpe_record.trial_budget <> stop_record.maximum_iterations
       OR tpe_record.search_space_config_version_id <>
          random_record.search_space_config_version_id THEN
        RAISE EXCEPTION 'formal comparison requires a governed equal-budget stop'
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
    IF finalist_limit <= 0
       OR finalist_limit > stop_record.effective_trial_count THEN
        RAISE EXCEPTION 'formal finalist count violates the effective Q-019 budget'
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
    IF tpe_result_count <> stop_record.effective_trial_count
       OR random_result_count <> stop_record.effective_trial_count
       OR tpe_complete_count < finalist_limit
       OR tpe_unique_complete_count < finalist_limit THEN
        RAISE EXCEPTION 'formal comparison lacks its effective paired budget or finalists'
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
        'effective_paired_trial_budget', stop_record.effective_trial_count,
        'finalist_count', finalist_limit,
        'finalist_manifest_hash', finalist_manifest_hash,
        'formal_stop_evidence_hash', stop_record.evidence_hash,
        'formal_stop_reason', stop_record.stop_reason,
        'maximum_trial_budget', stop_record.maximum_iterations,
        'random_complete_trial_count', random_complete_count,
        'random_result_chain_hash', random_chain,
        'random_trial_result_count', random_result_count,
        'tpe_complete_trial_count', tpe_complete_count,
        'tpe_minus_random_objective',
            CASE WHEN best_random_objective IS NULL THEN NULL
                 ELSE best_tpe_objective - best_random_objective END,
        'tpe_result_chain_hash', tpe_chain,
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

ALTER TABLE strategy_training.training_model_b_formal_search_stop_facts
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.govern_training_model_b_formal_search_pair(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION
    strategy_training.advance_training_model_b_optimizer_run_unbudgeted(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_b_optimizer_run(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_model_b_formal_search(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_model_b_formal_search_stop_facts
FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.govern_training_model_b_formal_search_pair(uuid),
    strategy_training.advance_training_model_b_optimizer_run_unbudgeted(uuid),
    strategy_training.advance_training_model_b_optimizer_run(uuid)
FROM PUBLIC;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '098_training_model_b_formal_search_stopping',
    encode(digest(
        'auto_trade_v2_098_training_model_b_formal_search_stopping_v1',
        'sha256'), 'hex'),
    'Enforce paired Q-019 formal wall-clock and TRAIN no-improvement stopping'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
