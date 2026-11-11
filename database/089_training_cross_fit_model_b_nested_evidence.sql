\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_cross_fit_model_b_fold_runs (
    cross_fit_execution_id uuid NOT NULL
        REFERENCES strategy_training.training_cross_fit_model_b_gate_runs,
    outer_fold_number integer NOT NULL CHECK (outer_fold_number > 0),
    cross_fit_fold_id uuid NOT NULL REFERENCES strategy_training.training_cross_fit_folds,
    tpe_optimizer_run_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_optimizer_runs,
    random_optimizer_run_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_optimizer_runs,
    selected_iteration_id uuid REFERENCES strategy_training.training_iterations,
    evaluation_iteration_id uuid UNIQUE REFERENCES strategy_training.training_iterations,
    training_end_at timestamptz NOT NULL,
    prediction_start_at timestamptz NOT NULL,
    prediction_end_at timestamptz NOT NULL,
    state varchar(16) NOT NULL CHECK (
        state IN ('SEARCHING', 'EVALUATING', 'SUCCEEDED', 'FAILED', 'CANCELLED')
    ),
    evidence_hash char(64),
    failure_code varchar(64),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    PRIMARY KEY (cross_fit_execution_id, outer_fold_number),
    UNIQUE (cross_fit_execution_id, cross_fit_fold_id),
    CHECK (tpe_optimizer_run_id <> random_optimizer_run_id),
    CHECK (training_end_at <= prediction_start_at
           AND prediction_start_at < prediction_end_at),
    CHECK (evidence_hash IS NULL OR evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK ((state IN ('SEARCHING', 'EVALUATING') AND completed_at IS NULL
             AND evidence_hash IS NULL AND failure_code IS NULL)
        OR (state = 'SUCCEEDED' AND completed_at IS NOT NULL
             AND evidence_hash IS NOT NULL AND failure_code IS NULL)
        OR (state IN ('FAILED', 'CANCELLED') AND completed_at IS NOT NULL
             AND evidence_hash IS NULL AND failure_code IS NOT NULL
             AND btrim(failure_code) <> ''))
);

CREATE TABLE strategy_training.training_cross_fit_model_b_fold_events (
    cross_fit_execution_id uuid NOT NULL,
    outer_fold_number integer NOT NULL,
    entry_event_id char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    event_role varchar(16) NOT NULL CHECK (event_role IN ('TRAIN_PRIOR', 'FOLD_OUT')),
    exit_episode_id char(64) REFERENCES strategy_training.training_exit_episode_inputs,
    boundary_hash char(64) NOT NULL CHECK (boundary_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (cross_fit_execution_id, outer_fold_number, entry_event_id, event_role),
    FOREIGN KEY (cross_fit_execution_id, outer_fold_number)
        REFERENCES strategy_training.training_cross_fit_model_b_fold_runs,
    CHECK ((event_role = 'TRAIN_PRIOR' AND exit_episode_id IS NULL)
        OR event_role = 'FOLD_OUT')
);

CREATE TABLE strategy_training.training_cross_fit_model_b_fold_metrics (
    cross_fit_execution_id uuid NOT NULL,
    outer_fold_number integer NOT NULL,
    entry_event_id char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    exit_episode_id char(64) NOT NULL UNIQUE
        REFERENCES strategy_training.training_exit_episode_inputs,
    net_expectancy numeric NOT NULL CHECK (net_expectancy <> 'NaN'::numeric),
    stressed_net_expectancy numeric NOT NULL
        CHECK (stressed_net_expectancy <> 'NaN'::numeric),
    result_hash char(64) NOT NULL CHECK (result_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (cross_fit_execution_id, outer_fold_number, entry_event_id),
    FOREIGN KEY (cross_fit_execution_id, outer_fold_number)
        REFERENCES strategy_training.training_cross_fit_model_b_fold_runs
);

CREATE TRIGGER trg_training_cross_fit_model_b_fold_metrics_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_cross_fit_model_b_fold_metrics
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.register_cross_fit_model_b_fold_run(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer,
    p_tpe_optimizer_run_id uuid, p_random_optimizer_run_id uuid
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE gate_record strategy_training.training_cross_fit_model_b_gate_runs%ROWTYPE;
        fold_record strategy_training.training_cross_fit_folds%ROWTYPE;
        tpe_record strategy_training.training_optimizer_runs%ROWTYPE;
        random_record strategy_training.training_optimizer_runs%ROWTYPE;
        prediction_start timestamptz; prediction_end timestamptz;
        training_end timestamptz; inserted_count bigint;
BEGIN
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id AND state = 'RUNNING'
    FOR UPDATE;
    SELECT fold.* INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_folds fold
    JOIN strategy_training.training_cross_fit_fold_executions fold_execution
      ON fold_execution.cross_fit_fold_id = fold.cross_fit_fold_id
     AND fold_execution.cross_fit_execution_id = p_cross_fit_execution_id
    WHERE fold.outer_fold_number = p_outer_fold_number
      AND fold.status = 'SUCCEEDED';
    SELECT min(scope.effective_train_end_at), min(scope.prediction_start_at),
           min(scope.prediction_end_at)
    INTO STRICT training_end, prediction_start, prediction_end
    FROM strategy_training.training_cross_fit_optimizer_scopes scope
    WHERE scope.cross_fit_execution_id = p_cross_fit_execution_id
      AND scope.outer_fold_number = p_outer_fold_number;
    SELECT * INTO STRICT tpe_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_tpe_optimizer_run_id;
    SELECT * INTO STRICT random_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_random_optimizer_run_id;
    IF tpe_record.experiment_id <> gate_record.temporary_experiment_id
       OR random_record.experiment_id <> gate_record.temporary_experiment_id
       OR tpe_record.optimizer_kind <> 'TPE'
       OR random_record.optimizer_kind <> 'RANDOM'
       OR tpe_record.trial_budget <> random_record.trial_budget
       OR tpe_record.search_space_config_version_id <>
          random_record.search_space_config_version_id
       OR training_end > prediction_start THEN
        RAISE EXCEPTION 'nested Model-B fold violates the frozen search boundary'
            USING ERRCODE = '23514';
    END IF;
    IF p_outer_fold_number > 1 AND NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_fold_runs prior
        WHERE prior.cross_fit_execution_id = p_cross_fit_execution_id
          AND prior.outer_fold_number = p_outer_fold_number - 1
          AND prior.state = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'nested Model-B folds must complete sequentially'
            USING ERRCODE = '55000';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_model_b_fold_runs (
        cross_fit_execution_id, outer_fold_number, cross_fit_fold_id,
        tpe_optimizer_run_id, random_optimizer_run_id, training_end_at,
        prediction_start_at, prediction_end_at, state
    ) VALUES (p_cross_fit_execution_id, p_outer_fold_number,
        fold_record.cross_fit_fold_id, p_tpe_optimizer_run_id,
        p_random_optimizer_run_id, training_end, prediction_start,
        prediction_end, 'SEARCHING');

    INSERT INTO strategy_training.training_cross_fit_model_b_fold_events (
        cross_fit_execution_id, outer_fold_number, entry_event_id,
        event_role, boundary_hash
    )
    SELECT p_cross_fit_execution_id, p_outer_fold_number, member.entry_event_id,
           CASE WHEN entry.signal_time < prediction_start
                THEN 'TRAIN_PRIOR' ELSE 'FOLD_OUT' END,
           encode(digest(concat_ws('|', p_cross_fit_execution_id,
               p_outer_fold_number, member.entry_event_id,
               CASE WHEN entry.signal_time < prediction_start
                    THEN 'TRAIN_PRIOR' ELSE 'FOLD_OUT' END,
               training_end, prediction_start, prediction_end), 'sha256'), 'hex')
    FROM strategy_training.training_cross_fit_corpus_events member
    JOIN strategy_training.training_entry_events entry USING (entry_event_id)
    WHERE member.cross_fit_corpus_id = gate_record.candidate_corpus_id
      AND member.declared_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
      AND member.declared_use = 'GO_NO_GO'
      AND (entry.signal_time < training_end
           OR (entry.signal_time >= prediction_start
               AND entry.signal_time < prediction_end));
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    IF inserted_count = 0
       OR NOT EXISTS (SELECT 1
          FROM strategy_training.training_cross_fit_model_b_fold_events event
          WHERE event.cross_fit_execution_id = p_cross_fit_execution_id
            AND event.outer_fold_number = p_outer_fold_number
            AND event.event_role = 'TRAIN_PRIOR')
       OR NOT EXISTS (SELECT 1
          FROM strategy_training.training_cross_fit_model_b_fold_events event
          WHERE event.cross_fit_execution_id = p_cross_fit_execution_id
            AND event.outer_fold_number = p_outer_fold_number
            AND event.event_role = 'FOLD_OUT') THEN
        RAISE EXCEPTION 'nested Model-B fold requires prior TRAIN and fold-out events'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE FUNCTION strategy_training.bind_cross_fit_model_b_fold_episode(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer,
    p_entry_event_id char(64), p_exit_episode_id char(64)
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        JOIN strategy_training.training_cross_fit_model_b_fold_events event
          ON event.cross_fit_execution_id = fold_run.cross_fit_execution_id
         AND event.outer_fold_number = fold_run.outer_fold_number
        JOIN strategy_training.training_exit_episode_inputs episode
          ON episode.exit_episode_id = p_exit_episode_id
        JOIN strategy_training.training_model_b_sample_map sample
          ON sample.model_b_sample_id = episode.model_b_sample_id
        WHERE fold_run.cross_fit_execution_id = p_cross_fit_execution_id
          AND fold_run.outer_fold_number = p_outer_fold_number
          AND fold_run.state = 'EVALUATING'
          AND event.entry_event_id = p_entry_event_id
          AND event.event_role = 'FOLD_OUT'
          AND sample.entry_event_id = event.entry_event_id
          AND episode.model_b_iteration_id = fold_run.evaluation_iteration_id
    ) THEN
        RAISE EXCEPTION 'fold-out episode is outside its nested evaluation boundary'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_cross_fit_model_b_fold_events
    SET exit_episode_id = p_exit_episode_id
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number
      AND entry_event_id = p_entry_event_id AND event_role = 'FOLD_OUT'
      AND exit_episode_id IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'fold-out episode was already bound' USING ERRCODE = '55000';
    END IF;
END
$$;

-- Replace the 087 context so temporary candidates see only events strictly
-- preceding their own outer prediction fold.  The full candidate corpus is
-- never exposed to a nested optimizer candidate.
CREATE OR REPLACE FUNCTION strategy_training.training_model_b_candidate_preparation_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    model_b_iteration_id uuid, optimizer_run_id uuid,
    search_space_config_version_id uuid, search_space_config jsonb,
    base_exit_rule_version_id uuid, base_exit_rule_config jsonb,
    candidate_parameters jsonb, candidate_content_hash char(64),
    temporary_only boolean, input_entry_event_ids jsonb,
    existing_effective_hash char(64)
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        iteration_record strategy_training.training_iterations%ROWTYPE;
        run_record strategy_training.training_optimizer_runs%ROWTYPE;
        search_id uuid; search_json jsonb; exit_id uuid; exit_json jsonb;
        is_temporary boolean; is_nested boolean; event_ids jsonb;
        existing_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_B_PREPARE_CANDIDATE'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL
       OR task_record.task_payload <> jsonb_build_object(
            'task_type', 'MODEL_B_PREPARE_CANDIDATE', 'payload_version', 1
       ) THEN
        RAISE EXCEPTION 'candidate preparation requires its exact active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT iteration.* INTO STRICT iteration_record
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = task_record.iteration_id;
    SELECT run.* INTO STRICT run_record
    FROM strategy_training.training_optimizer_trial_iterations trial_link
    JOIN strategy_training.training_optimizer_trial_proposals proposal
      ON proposal.optimizer_trial_proposal_id = trial_link.optimizer_trial_proposal_id
    JOIN strategy_training.training_optimizer_runs run
      ON run.optimizer_run_id = proposal.optimizer_run_id
    WHERE trial_link.iteration_id = iteration_record.iteration_id;
    IF iteration_record.state <> 'RUNNING'
       OR iteration_record.candidate_source NOT IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
       OR run_record.state <> 'RUNNING'
       OR run_record.experiment_id <> iteration_record.experiment_id
       OR task_record.experiment_id <> iteration_record.experiment_id
       OR task_record.optimizer_run_id IS DISTINCT FROM run_record.optimizer_run_id THEN
        RAISE EXCEPTION 'candidate preparation is outside its running optimizer iteration'
            USING ERRCODE = '23514';
    END IF;
    SELECT config.config_version_id, config.config_json
    INTO STRICT search_id, search_json
    FROM strategy_training.training_config_versions config
    WHERE config.config_version_id = run_record.search_space_config_version_id
      AND config.config_type = 'MODEL_B_SEARCH_SPACE' AND config.status = 'READY';
    SELECT config.config_version_id, config.config_json
    INTO STRICT exit_id, exit_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'EXIT_RULES' AND config.status = 'READY'
    WHERE binding.experiment_id = iteration_record.experiment_id
      AND binding.config_type = 'EXIT_RULES';

    SELECT EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        WHERE run_record.optimizer_run_id IN (
            fold_run.tpe_optimizer_run_id, fold_run.random_optimizer_run_id
        ) AND fold_run.state = 'SEARCHING'
    ) INTO is_nested;
    SELECT is_nested OR EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
        WHERE run_record.optimizer_run_id IN (
            gate_run.tpe_optimizer_run_id, gate_run.random_optimizer_run_id
        ) AND gate_run.state = 'RUNNING'
    ) INTO is_temporary;
    IF is_nested THEN
        SELECT jsonb_agg(to_jsonb(event.entry_event_id::text)
                         ORDER BY event.entry_event_id)
        INTO event_ids
        FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        JOIN strategy_training.training_cross_fit_model_b_fold_events event
          ON event.cross_fit_execution_id = fold_run.cross_fit_execution_id
         AND event.outer_fold_number = fold_run.outer_fold_number
        JOIN strategy_training.training_entry_events entry
          ON entry.entry_event_id = event.entry_event_id
        WHERE run_record.optimizer_run_id IN (
            fold_run.tpe_optimizer_run_id, fold_run.random_optimizer_run_id
        ) AND fold_run.state = 'SEARCHING'
          AND event.event_role = 'TRAIN_PRIOR'
          AND entry.signal_time < fold_run.training_end_at;
    ELSIF is_temporary THEN
        RAISE EXCEPTION 'temporary Model-B optimizer is not bound to an outer fold'
            USING ERRCODE = '23514';
    ELSE
        SELECT jsonb_agg(to_jsonb(input.entry_event_id::text)
                         ORDER BY input.entry_event_id)
        INTO event_ids
        FROM strategy_training.training_model_b_formal_search_runs formal_run
        JOIN strategy_training.training_model_b_formal_search_inputs input
          ON input.formal_search_run_id = formal_run.formal_search_run_id
        WHERE run_record.optimizer_run_id IN (
            formal_run.tpe_optimizer_run_id, formal_run.random_optimizer_run_id
        ) AND formal_run.state = 'CREATED';
    END IF;
    IF event_ids IS NULL OR jsonb_array_length(event_ids) = 0 THEN
        RAISE EXCEPTION 'candidate preparation has no governed input corpus'
            USING ERRCODE = '23514';
    END IF;
    SELECT policy.effective_exit_rule_content_hash INTO existing_hash
    FROM strategy_training.training_model_b_compiled_candidate_policies policy
    WHERE policy.model_b_iteration_id = iteration_record.iteration_id;
    RETURN QUERY SELECT iteration_record.iteration_id, run_record.optimizer_run_id,
        search_id, search_json, exit_id, exit_json,
        iteration_record.candidate_parameters,
        iteration_record.candidate_content_hash, is_temporary, event_ids, existing_hash;
END
$$;

CREATE FUNCTION strategy_training.finalize_cross_fit_model_b_fold_evidence(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE fold_record strategy_training.training_cross_fit_model_b_fold_runs%ROWTYPE;
        gate_record strategy_training.training_cross_fit_model_b_gate_runs%ROWTYPE;
        notional numeric; expected_count bigint; observed_count bigint;
        persisted_hash char(64);
BEGIN
    SELECT * INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_model_b_fold_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number FOR UPDATE;
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    IF fold_record.state = 'SUCCEEDED' THEN RETURN fold_record.evidence_hash; END IF;
    IF fold_record.state <> 'EVALUATING' THEN
        RAISE EXCEPTION 'nested Model-B fold is not evaluating' USING ERRCODE = '55000';
    END IF;
    SELECT (config.config_json ->> 'notional_per_trade')::numeric INTO STRICT notional
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'PORTFOLIO_RULES'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.status = 'READY'
    WHERE iteration.iteration_id = fold_record.evaluation_iteration_id;
    IF notional <= 0 THEN RAISE EXCEPTION 'invalid fold evaluation notional'; END IF;

    INSERT INTO strategy_training.training_cross_fit_model_b_fold_metrics (
        cross_fit_execution_id, outer_fold_number, entry_event_id,
        exit_episode_id, net_expectancy, stressed_net_expectancy, result_hash
    )
    SELECT p_cross_fit_execution_id, p_outer_fold_number, event.entry_event_id,
           event.exit_episode_id, outcome.net_pnl / notional * 100,
           (outcome.gross_pnl + outcome.funding_total
             - gate_record.stress_multiplier *
               (outcome.entry_fee + outcome.exit_fee + outcome.slippage_total))
             / notional * 100,
           encode(digest(concat_ws('|', event.entry_event_id,
               outcome.result_hash, gate_record.stress_multiplier, notional),
               'sha256'), 'hex')
    FROM strategy_training.training_cross_fit_model_b_fold_events event
    JOIN strategy_training.training_exit_episode_inputs episode
      ON episode.exit_episode_id = event.exit_episode_id
    JOIN strategy_training.training_exit_outcomes outcome
      ON outcome.exit_episode_id = episode.exit_episode_id
    WHERE event.cross_fit_execution_id = p_cross_fit_execution_id
      AND event.outer_fold_number = p_outer_fold_number
      AND event.event_role = 'FOLD_OUT' AND episode.status = 'DECIDED'
    ON CONFLICT DO NOTHING;
    SELECT count(*) INTO expected_count
    FROM strategy_training.training_cross_fit_model_b_fold_events
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number AND event_role = 'FOLD_OUT';
    SELECT count(*), encode(digest(COALESCE(string_agg(concat_ws('|',
        metric.entry_event_id, metric.net_expectancy,
        metric.stressed_net_expectancy, metric.result_hash), ''
        ORDER BY metric.entry_event_id), ''), 'sha256'), 'hex')
    INTO observed_count, persisted_hash
    FROM strategy_training.training_cross_fit_model_b_fold_metrics metric
    WHERE metric.cross_fit_execution_id = p_cross_fit_execution_id
      AND metric.outer_fold_number = p_outer_fold_number;
    IF observed_count <> expected_count THEN
        RAISE EXCEPTION 'nested Model-B fold evidence is incomplete'
            USING ERRCODE = '55000';
    END IF;
    UPDATE strategy_training.training_cross_fit_model_b_fold_runs
    SET state = 'SUCCEEDED', evidence_hash = persisted_hash,
        completed_at = clock_timestamp()
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number;
    RETURN persisted_hash;
END
$$;

CREATE FUNCTION strategy_training.finalize_cross_fit_model_b_nested_gate(
    p_cross_fit_execution_id uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE expected_count bigint; observed_count bigint; metric_record record;
        gate_state text; existing_hash char(64);
BEGIN
    SELECT state, evidence_hash INTO STRICT gate_state, existing_hash
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF gate_state = 'SUCCEEDED' THEN RETURN existing_hash; END IF;
    IF gate_state <> 'RUNNING' THEN
        RAISE EXCEPTION 'nested Model-B gate is not running' USING ERRCODE = '55000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        WHERE fold_run.cross_fit_execution_id = p_cross_fit_execution_id
          AND fold_run.state <> 'SUCCEEDED'
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        WHERE fold_run.cross_fit_execution_id = p_cross_fit_execution_id
    ) THEN
        RAISE EXCEPTION 'all nested Model-B folds must succeed before gate finalization'
            USING ERRCODE = '55000';
    END IF;
    FOR metric_record IN
        SELECT metric.*
        FROM strategy_training.training_cross_fit_model_b_fold_metrics metric
        WHERE metric.cross_fit_execution_id = p_cross_fit_execution_id
        ORDER BY metric.outer_fold_number, metric.entry_event_id
    LOOP
        PERFORM strategy_training.record_cross_fit_model_b_gate_metric(
            p_cross_fit_execution_id, metric_record.entry_event_id,
            metric_record.net_expectancy, metric_record.stressed_net_expectancy,
            metric_record.result_hash
        );
    END LOOP;
    SELECT corpus.event_count INTO STRICT expected_count
    FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
    JOIN strategy_training.training_cross_fit_corpora corpus
      ON corpus.cross_fit_corpus_id = gate_run.candidate_corpus_id
    WHERE gate_run.cross_fit_execution_id = p_cross_fit_execution_id;
    SELECT count(*) INTO observed_count
    FROM strategy_training.training_cross_fit_model_b_gate_metrics
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    IF observed_count <> expected_count THEN
        RAISE EXCEPTION 'nested folds do not cover the fixed Q-036 corpus exactly'
            USING ERRCODE = '23514';
    END IF;
    RETURN strategy_training.finalize_cross_fit_model_b_gate_run(
        p_cross_fit_execution_id
    );
END
$$;

ALTER TABLE strategy_training.training_cross_fit_model_b_fold_runs
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_model_b_fold_events
OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_model_b_fold_metrics
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.register_cross_fit_model_b_fold_run(
    uuid, integer, uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.bind_cross_fit_model_b_fold_episode(
    uuid, integer, char(64), char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_b_candidate_preparation_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_cross_fit_model_b_fold_evidence(uuid, integer)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_cross_fit_model_b_nested_gate(uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_model_b_fold_runs,
    strategy_training.training_cross_fit_model_b_fold_events,
    strategy_training.training_cross_fit_model_b_fold_metrics FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.register_cross_fit_model_b_fold_run(
    uuid, integer, uuid, uuid),
    strategy_training.bind_cross_fit_model_b_fold_episode(
        uuid, integer, char(64), char(64)),
    strategy_training.training_model_b_candidate_preparation_context(uuid, uuid),
    strategy_training.finalize_cross_fit_model_b_fold_evidence(uuid, integer),
    strategy_training.finalize_cross_fit_model_b_nested_gate(uuid)
FROM PUBLIC;
GRANT SELECT ON strategy_training.training_cross_fit_model_b_fold_runs,
    strategy_training.training_cross_fit_model_b_fold_events,
    strategy_training.training_cross_fit_model_b_fold_metrics
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.register_cross_fit_model_b_fold_run(
    uuid, integer, uuid, uuid),
    strategy_training.bind_cross_fit_model_b_fold_episode(
        uuid, integer, char(64), char(64)),
    strategy_training.finalize_cross_fit_model_b_fold_evidence(uuid, integer),
    strategy_training.finalize_cross_fit_model_b_nested_gate(uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_b_candidate_preparation_context(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES ('089_training_cross_fit_model_b_nested_evidence',
    encode(digest('auto_trade_v2_089_training_cross_fit_model_b_nested_evidence_v1',
                  'sha256'), 'hex'),
    'Enforce prior-fold Model-B training boundaries and aggregate fold-out cost stress evidence')
ON CONFLICT (version) DO NOTHING;

COMMIT;
