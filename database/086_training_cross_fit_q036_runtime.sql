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
    'CROSS_FIT_FINALIZE_CORPUS', 'CROSS_FIT_EVALUATE_GATE'
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
        WHEN 'CROSS_FIT_EVALUATE_GATE' THEN 'EVALUATOR'
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

CREATE TABLE strategy_training.training_cross_fit_model_b_gate_runs (
    cross_fit_execution_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_cross_fit_executions,
    candidate_corpus_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_cross_fit_corpora,
    temporary_experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    tpe_optimizer_run_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_optimizer_runs,
    random_optimizer_run_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_optimizer_runs,
    stress_multiplier numeric NOT NULL CHECK (stress_multiplier >= 1),
    state varchar(16) NOT NULL CHECK (
        state IN ('RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')
    ),
    evidence_hash char(64),
    failure_code varchar(64),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    CHECK (tpe_optimizer_run_id <> random_optimizer_run_id),
    CHECK (evidence_hash IS NULL OR evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((state = 'RUNNING' AND completed_at IS NULL AND evidence_hash IS NULL
                              AND failure_code IS NULL)
        OR (state = 'SUCCEEDED' AND completed_at IS NOT NULL
                                AND evidence_hash IS NOT NULL AND failure_code IS NULL)
        OR (state IN ('FAILED', 'CANCELLED') AND completed_at IS NOT NULL
             AND evidence_hash IS NULL AND failure_code IS NOT NULL
             AND btrim(failure_code) <> ''))
);

CREATE TABLE strategy_training.training_cross_fit_model_b_gate_metrics (
    cross_fit_execution_id uuid NOT NULL
        REFERENCES strategy_training.training_cross_fit_model_b_gate_runs,
    entry_event_id char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    net_expectancy numeric NOT NULL CHECK (net_expectancy <> 'NaN'::numeric),
    stressed_net_expectancy numeric NOT NULL
        CHECK (stressed_net_expectancy <> 'NaN'::numeric),
    result_hash char(64) NOT NULL CHECK (result_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (cross_fit_execution_id, entry_event_id)
);

CREATE FUNCTION strategy_training.create_cross_fit_model_b_gate_run(
    p_cross_fit_execution_id uuid, p_temporary_experiment_id uuid,
    p_tpe_optimizer_run_id uuid, p_random_optimizer_run_id uuid,
    p_stress_multiplier numeric
)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
        execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        temporary_record strategy_training.training_experiments%ROWTYPE;
        tpe_record strategy_training.training_optimizer_runs%ROWTYPE;
        random_record strategy_training.training_optimizer_runs%ROWTYPE;
        required_stress numeric;
BEGIN
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    SELECT * INTO STRICT corpus_record FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND corpus_use = 'GO_NO_GO';
    SELECT * INTO STRICT temporary_record FROM strategy_training.training_experiments
    WHERE experiment_id = p_temporary_experiment_id;
    SELECT * INTO STRICT tpe_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_tpe_optimizer_run_id;
    SELECT * INTO STRICT random_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_random_optimizer_run_id;
    SELECT (config.config_json #>>
            '{q036_go_no_go,model_b,required_stress_multiplier}')::numeric
    INTO STRICT required_stress
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = execution_record.protocol_config_version_id
      AND config.status = 'READY' AND config.config_type = 'CROSS_FIT_PROTOCOL';
    IF execution_record.state <> 'CANDIDATE_READY'
       OR temporary_record.state <> 'RUNNING'
       OR temporary_record.experiment_mode <> 'EXIT_POLICY'
       OR temporary_record.parent_experiment_id <> execution_record.experiment_id
       OR temporary_record.dataset_version_id <> execution_record.dataset_version_id
       OR tpe_record.experiment_id <> p_temporary_experiment_id
       OR random_record.experiment_id <> p_temporary_experiment_id
       OR tpe_record.optimizer_kind <> 'TPE'
       OR random_record.optimizer_kind <> 'RANDOM'
       OR tpe_record.trial_budget <> random_record.trial_budget
       OR tpe_record.search_space_config_version_id <>
          random_record.search_space_config_version_id
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_config_versions config
           WHERE config.config_version_id = tpe_record.search_space_config_version_id
             AND config.config_type = 'MODEL_B_SEARCH_SPACE' AND config.status = 'READY'
       )
       OR p_stress_multiplier <> required_stress THEN
        RAISE EXCEPTION 'temporary Model-B gate run violates its frozen Q-036 contract'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_model_b_gate_runs (
        cross_fit_execution_id, candidate_corpus_id, temporary_experiment_id,
        tpe_optimizer_run_id, random_optimizer_run_id, stress_multiplier, state
    ) VALUES (
        p_cross_fit_execution_id, corpus_record.cross_fit_corpus_id,
        p_temporary_experiment_id, p_tpe_optimizer_run_id,
        p_random_optimizer_run_id, p_stress_multiplier, 'RUNNING'
    );
    RETURN p_cross_fit_execution_id;
END
$$;

CREATE FUNCTION strategy_training.record_cross_fit_model_b_gate_metric(
    p_cross_fit_execution_id uuid, p_entry_event_id char(64),
    p_net_expectancy numeric, p_stressed_net_expectancy numeric,
    p_result_hash char(64)
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF p_result_hash !~ '^[0-9a-f]{64}$'
       OR p_net_expectancy = 'NaN'::numeric
       OR p_stressed_net_expectancy = 'NaN'::numeric
       OR NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
           JOIN strategy_training.training_cross_fit_corpus_events member
             ON member.cross_fit_corpus_id = gate_run.candidate_corpus_id
            AND member.entry_event_id = p_entry_event_id
           WHERE gate_run.cross_fit_execution_id = p_cross_fit_execution_id
             AND gate_run.state = 'RUNNING'
             AND member.declared_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
             AND member.declared_use = 'GO_NO_GO'
       ) THEN
        RAISE EXCEPTION 'temporary Model-B metric is outside its fixed candidate corpus'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_model_b_gate_metrics (
        cross_fit_execution_id, entry_event_id, net_expectancy,
        stressed_net_expectancy, result_hash
    ) VALUES (
        p_cross_fit_execution_id, p_entry_event_id, p_net_expectancy,
        p_stressed_net_expectancy, p_result_hash
    );
END
$$;

CREATE FUNCTION strategy_training.finalize_cross_fit_model_b_gate_run(
    p_cross_fit_execution_id uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE gate_record strategy_training.training_cross_fit_model_b_gate_runs%ROWTYPE;
        expected_count bigint; observed_count bigint; persisted_hash char(64);
BEGIN
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF gate_record.state = 'SUCCEEDED' THEN RETURN gate_record.evidence_hash; END IF;
    SELECT event_count INTO STRICT expected_count
    FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_corpus_id = gate_record.candidate_corpus_id;
    SELECT count(*), encode(public.digest(COALESCE(string_agg(concat_ws('|',
        metric.entry_event_id, metric.net_expectancy::text,
        metric.stressed_net_expectancy::text, metric.result_hash
    ), '' ORDER BY metric.entry_event_id), ''), 'sha256'), 'hex')
    INTO observed_count, persisted_hash
    FROM strategy_training.training_cross_fit_model_b_gate_metrics metric
    WHERE metric.cross_fit_execution_id = p_cross_fit_execution_id;
    IF gate_record.state <> 'RUNNING' OR observed_count <> expected_count
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_optimizer_runs run
           WHERE run.optimizer_run_id = gate_record.tpe_optimizer_run_id
             AND run.state = 'SUCCEEDED'
       ) OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_optimizer_runs run
           WHERE run.optimizer_run_id = gate_record.random_optimizer_run_id
             AND run.state = 'SUCCEEDED'
       ) THEN
        RAISE EXCEPTION 'temporary Model-B gate cannot finalize without complete replay evidence'
            USING ERRCODE = '55000';
    END IF;
    UPDATE strategy_training.training_cross_fit_model_b_gate_runs
    SET state = 'SUCCEEDED', evidence_hash = persisted_hash,
        completed_at = clock_timestamp()
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    RETURN persisted_hash;
END
$$;

CREATE FUNCTION strategy_training.prepare_cross_fit_gate_evaluation_task(
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
    IF execution_record.state <> 'CANDIDATE_READY' THEN
        RETURN 'GATE_NOT_READY';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
        WHERE gate_run.cross_fit_execution_id = p_cross_fit_execution_id
          AND gate_run.state = 'SUCCEEDED'
    ) THEN RETURN 'WAITING_TEMPORARY_MODEL_B'; END IF;
    SELECT * INTO task_record FROM strategy_training.training_tasks task
    WHERE task.experiment_id = execution_record.experiment_id
      AND task.task_type = 'CROSS_FIT_EVALUATE_GATE'
      AND task.task_payload ->> 'execution_id' = p_cross_fit_execution_id::text;
    IF FOUND THEN
        IF task_record.state IN ('FAILED', 'CANCELLED') THEN
            UPDATE strategy_training.training_cross_fit_executions
            SET state = 'FAILED', failure_code = 'Q036_GATE_TASK_FAILED',
                completed_at = clock_timestamp()
            WHERE cross_fit_execution_id = p_cross_fit_execution_id;
            RETURN 'EXECUTION_FAILED';
        END IF;
        RETURN CASE task_record.state WHEN 'SUCCEEDED' THEN 'GATE_COMPLETED'
                    ELSE 'WAITING_GATE' END;
    END IF;
    PERFORM strategy_training.enqueue_training_task(
        execution_record.experiment_id, NULL, NULL, NULL,
        'CROSS_FIT_EVALUATE_GATE', 'EVALUATOR',
        encode(public.digest(concat_ws('|', p_cross_fit_execution_id::text,
            'CROSS_FIT_EVALUATE_GATE_V1'), 'sha256'), 'hex'),
        jsonb_build_object('task_type', 'CROSS_FIT_EVALUATE_GATE',
            'payload_version', 1, 'execution_id', p_cross_fit_execution_id::text), 20
    );
    RETURN 'GATE_ENQUEUED';
END
$$;

CREATE FUNCTION strategy_training.training_cross_fit_gate_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    execution_id uuid, execution_lease_token uuid,
    protocol_config_version_id uuid, corpus_hash char(64),
    model_b_evidence_hash char(64), tpe_optimizer_run_id uuid,
    random_optimizer_run_id uuid, alpha numeric, confidence_level numeric,
    minimum_effective_days integer, minimum_effective_folds integer,
    bootstrap_replicates integer, random_seed bigint,
    model_a_point_threshold numeric, model_a_ci_lower_threshold numeric,
    model_b_point_threshold numeric, model_b_stress_multiplier numeric,
    fold_number integer, prediction_day date, symbol text,
    tpe_value numeric, random_value numeric,
    model_b_net_expectancy numeric, model_b_stressed_net_expectancy numeric
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
        gate_record strategy_training.training_cross_fit_model_b_gate_runs%ROWTYPE;
        protocol_json jsonb; requested_execution_id uuid; evidence_count bigint;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'CROSS_FIT_EVALUATE_GATE'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.task_payload ->> 'task_type' <> 'CROSS_FIT_EVALUATE_GATE'
       OR task_record.task_payload ->> 'payload_version' <> '1'
       OR (SELECT count(*) FROM jsonb_object_keys(task_record.task_payload)) <> 3 THEN
        RAISE EXCEPTION 'Q-036 gate requires its exact active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    requested_execution_id := (task_record.task_payload ->> 'execution_id')::uuid;
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = requested_execution_id
      AND experiment_id = task_record.experiment_id FOR UPDATE;
    SELECT * INTO STRICT corpus_record FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_execution_id = requested_execution_id
      AND source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND corpus_use = 'GO_NO_GO';
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = requested_execution_id AND state = 'SUCCEEDED';
    SELECT count(*) INTO evidence_count
    FROM strategy_training.training_cross_fit_model_b_gate_metrics metric
    JOIN strategy_training.training_cross_fit_corpus_events member
      ON member.cross_fit_corpus_id = corpus_record.cross_fit_corpus_id
     AND member.entry_event_id = metric.entry_event_id
    WHERE metric.cross_fit_execution_id = requested_execution_id;
    IF execution_record.state <> 'CANDIDATE_READY'
       OR evidence_count <> corpus_record.event_count THEN
        RAISE EXCEPTION 'Q-036 requires complete temporary Model-B evidence on fixed corpus'
            USING ERRCODE = '23514';
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

    RETURN QUERY
    WITH model_a AS MATERIALIZED (
        SELECT fold.outer_fold_number, entry.entry_event_id,
               entry.signal_time::date AS metric_day, entry.symbol AS metric_symbol,
               outcome.mfe_percent AS metric_tpe_value,
               avg(random_outcome.mfe_percent) AS metric_random_value
        FROM strategy_training.training_cross_fit_corpus_events member
        JOIN strategy_training.training_entry_events entry USING (entry_event_id)
        JOIN strategy_training.training_entry_outcomes outcome USING (entry_event_id)
        JOIN strategy_training.training_cross_fit_predictions prediction
          ON prediction.selected_iteration_id = entry.generating_iteration_id
         AND prediction.optimizer_role = 'TPE'
        JOIN strategy_training.training_cross_fit_folds fold
          ON fold.outer_fold_number = prediction.outer_fold_number
         AND fold.experiment_id = execution_record.experiment_id
        JOIN strategy_training.training_cross_fit_fold_executions fold_execution
          ON fold_execution.cross_fit_fold_id = fold.cross_fit_fold_id
         AND fold_execution.cross_fit_execution_id = requested_execution_id
        JOIN strategy_training.training_random_entry_baselines baseline
          ON baseline.matched_entry_event_id = entry.entry_event_id
        CROSS JOIN LATERAL jsonb_array_elements_text(
            baseline.selected_candidate_ids
        ) selected(candidate_id)
        JOIN strategy_training.training_random_baseline_candidate_outcomes random_outcome
          ON random_outcome.candidate_id = selected.candidate_id::char(64)
         AND random_outcome.matched_entry_event_id = entry.entry_event_id
         AND random_outcome.is_complete
        WHERE member.cross_fit_corpus_id = corpus_record.cross_fit_corpus_id
          AND outcome.is_complete
        GROUP BY fold.outer_fold_number, entry.entry_event_id,
                 entry.signal_time::date, entry.symbol, outcome.mfe_percent
    )
    SELECT requested_execution_id, p_lease_token,
           execution_record.protocol_config_version_id, corpus_record.corpus_hash,
           gate_record.evidence_hash, gate_record.tpe_optimizer_run_id,
           gate_record.random_optimizer_run_id,
           (protocol_json #>> '{q036_go_no_go,alpha_per_gate}')::numeric,
           (protocol_json #>> '{q029_validation,confidence_level}')::numeric,
           execution_record.minimum_effective_days,
           execution_record.minimum_effective_folds,
           (protocol_json #>> '{q036_go_no_go,bootstrap_replicates}')::integer,
           (protocol_json #>> '{q030_cross_fit,random_seed}')::bigint,
           (protocol_json #>>
              '{q036_go_no_go,model_a,minimum_point_estimate_percentage_points}')::numeric,
           (protocol_json #>>
              '{q036_go_no_go,model_a,minimum_ci_lower_bound_percentage_points}')::numeric,
           (protocol_json #>>
              '{q036_go_no_go,model_b,minimum_point_estimate_percentage_points}')::numeric,
           gate_record.stress_multiplier, model_a.outer_fold_number,
           model_a.metric_day, model_a.metric_symbol,
           model_a.metric_tpe_value, model_a.metric_random_value,
           model_b.net_expectancy, model_b.stressed_net_expectancy
    FROM model_a
    JOIN strategy_training.training_cross_fit_model_b_gate_metrics model_b
      ON model_b.cross_fit_execution_id = requested_execution_id
     AND model_b.entry_event_id = model_a.entry_event_id
    ORDER BY model_a.metric_day, model_a.metric_symbol, model_a.entry_event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Q-036 fixed corpus has no joined Model-A/Model-B evidence'
            USING ERRCODE = '23514';
    END IF;
END
$$;

ALTER TABLE strategy_training.training_cross_fit_model_b_gate_runs
    OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_model_b_gate_metrics
    OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_cross_fit_model_b_gate_run(
    uuid, uuid, uuid, uuid, numeric
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_model_b_gate_metric(
    uuid, char(64), numeric, numeric, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_cross_fit_model_b_gate_run(uuid)
    OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.prepare_cross_fit_gate_evaluation_task(uuid)
    OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_cross_fit_gate_context(uuid, uuid)
    OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_model_b_gate_runs,
    strategy_training.training_cross_fit_model_b_gate_metrics FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.create_cross_fit_model_b_gate_run(
    uuid, uuid, uuid, uuid, numeric
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.record_cross_fit_model_b_gate_metric(
    uuid, char(64), numeric, numeric, char(64)
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.finalize_cross_fit_model_b_gate_run(uuid)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.prepare_cross_fit_gate_evaluation_task(uuid)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_cross_fit_gate_context(uuid, uuid)
    FROM PUBLIC;

GRANT SELECT ON strategy_training.training_cross_fit_model_b_gate_runs,
    strategy_training.training_cross_fit_model_b_gate_metrics
    TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.create_cross_fit_model_b_gate_run(
    uuid, uuid, uuid, uuid, numeric
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.record_cross_fit_model_b_gate_metric(
    uuid, char(64), numeric, numeric, char(64)
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.finalize_cross_fit_model_b_gate_run(uuid)
    TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.prepare_cross_fit_gate_evaluation_task(uuid)
    TO tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION strategy_training.training_cross_fit_gate_context(uuid, uuid)
    TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '086_training_cross_fit_q036_runtime',
    encode(digest('auto_trade_v2_086_training_cross_fit_q036_runtime_v1',
                  'sha256'), 'hex'),
    'Persist temporary Model-B Q-036 evidence and execute the combined Cross-fit gate'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
