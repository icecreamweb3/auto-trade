\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_iterations
DROP CONSTRAINT training_iterations_candidate_source_check;
ALTER TABLE strategy_training.training_iterations
ADD CONSTRAINT training_iterations_candidate_source_check CHECK (
    candidate_source IN (
        'FIXED_BASELINE', 'ROUND_ZERO_BASELINE', 'OPTUNA_TPE',
        'RANDOM_SEARCH', 'LLM_ADVICE', 'MANUAL_APPROVED'
    )
);

CREATE TABLE strategy_training.training_model_b_round_zero_baseline_runs (
    go_no_go_evaluation_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_go_no_go_evaluations,
    cross_fit_execution_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_cross_fit_executions,
    formal_corpus_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_cross_fit_corpora,
    experiment_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_experiments,
    iteration_id uuid NOT NULL UNIQUE
        REFERENCES strategy_training.training_iterations,
    baseline_definition jsonb NOT NULL CHECK (
        jsonb_typeof(baseline_definition) = 'object'
        AND baseline_definition <> '{}'::jsonb
    ),
    baseline_definition_hash char(64) NOT NULL CHECK (
        baseline_definition_hash ~ '^[0-9a-f]{64}$'
        AND baseline_definition_hash = encode(
            digest(baseline_definition::text, 'sha256'), 'hex'
        )
    ),
    event_count integer NOT NULL CHECK (event_count > 0),
    state varchar(16) NOT NULL CHECK (
        state IN ('REPLAYING', 'EVALUATING', 'SUCCEEDED', 'FAILED', 'CANCELLED')
    ),
    evidence_hash char(64),
    failure_code varchar(64),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    CHECK (evidence_hash IS NULL OR evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (state IN ('REPLAYING', 'EVALUATING') AND evidence_hash IS NULL
                                              AND failure_code IS NULL
                                              AND completed_at IS NULL)
        OR (state = 'SUCCEEDED' AND evidence_hash IS NOT NULL
                                AND failure_code IS NULL
                                AND completed_at IS NOT NULL)
        OR (state IN ('FAILED', 'CANCELLED') AND evidence_hash IS NULL
             AND failure_code IS NOT NULL AND btrim(failure_code) <> ''
             AND completed_at IS NOT NULL)
    )
);

CREATE OR REPLACE FUNCTION strategy_training.training_effective_model_b_exit_config(
    p_model_b_iteration_id uuid, p_base_exit_rule_version_id uuid
)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
    SELECT COALESCE(
        (SELECT baseline.baseline_definition
         FROM strategy_training.training_model_b_round_zero_baseline_runs baseline
         WHERE baseline.iteration_id = p_model_b_iteration_id),
        (SELECT policy.effective_exit_rule_config
         FROM strategy_training.training_model_b_compiled_candidate_policies policy
         WHERE policy.model_b_iteration_id = p_model_b_iteration_id
           AND policy.base_exit_rule_version_id = p_base_exit_rule_version_id),
        (SELECT config.config_json
         FROM strategy_training.training_config_versions config
         WHERE config.config_version_id = p_base_exit_rule_version_id
           AND config.config_type = 'EXIT_RULES' AND config.status = 'READY')
    )
$$;

CREATE FUNCTION strategy_training.initialize_training_model_b_round_zero_baseline(
    p_go_no_go_evaluation_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE gate_record strategy_training.training_go_no_go_evaluations%ROWTYPE;
        execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        parent_record strategy_training.training_experiments%ROWTYPE;
        corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        baseline_experiment_id uuid; baseline_iteration_id uuid;
        exit_rule_id uuid; fee_id uuid; slippage_id uuid; portfolio_id uuid;
        definition jsonb; definition_hash char(64); episode_record record;
        created_episode_count integer;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM strategy_training.training_model_b_round_zero_baseline_runs baseline
        WHERE baseline.go_no_go_evaluation_id = p_go_no_go_evaluation_id
    ) THEN RETURN 'ROUND_ZERO_BASELINE_EXISTS'; END IF;
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_go_no_go_evaluations
    WHERE go_no_go_evaluation_id = p_go_no_go_evaluation_id FOR SHARE;
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE experiment_id = gate_record.experiment_id
      AND state = 'FORMAL_CORPUS_READY' FOR UPDATE;
    SELECT * INTO STRICT parent_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = execution_record.experiment_id;
    SELECT * INTO STRICT corpus_record
    FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_execution_id = execution_record.cross_fit_execution_id
      AND source = 'CROSS_FIT_MODEL_A' AND corpus_use = 'MODEL_B_TRAIN';
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = execution_record.dataset_version_id
      AND status = 'READY' AND partition = 'TRAIN' AND interval_seconds = 300;
    IF gate_record.decision <> 'PASS' OR NOT gate_record.temporary_only
       OR corpus_record.event_count <= 0
       OR corpus_record.source_corpus_id IS NULL THEN
        RAISE EXCEPTION 'round-zero baseline requires a passing promoted Cross-fit corpus'
            USING ERRCODE = '23514';
    END IF;
    SELECT exit_binding.config_version_id, fee_binding.config_version_id,
           slip_binding.config_version_id, portfolio_binding.config_version_id
    INTO STRICT exit_rule_id, fee_id, slippage_id, portfolio_id
    FROM strategy_training.training_experiment_config_bindings exit_binding
    JOIN strategy_training.training_config_versions exit_config
      ON exit_config.config_version_id = exit_binding.config_version_id
     AND exit_config.config_type = 'EXIT_RULES' AND exit_config.status = 'READY'
    JOIN strategy_training.training_experiment_config_bindings fee_binding
      ON fee_binding.experiment_id = exit_binding.experiment_id
     AND fee_binding.config_type = 'FEE_MODEL'
    JOIN strategy_training.training_config_versions fee_config
      ON fee_config.config_version_id = fee_binding.config_version_id
     AND fee_config.config_type = 'FEE_MODEL' AND fee_config.status = 'READY'
    JOIN strategy_training.training_experiment_config_bindings slip_binding
      ON slip_binding.experiment_id = exit_binding.experiment_id
     AND slip_binding.config_type = 'SLIPPAGE_MODEL'
    JOIN strategy_training.training_config_versions slip_config
      ON slip_config.config_version_id = slip_binding.config_version_id
     AND slip_config.config_type = 'SLIPPAGE_MODEL' AND slip_config.status = 'READY'
    JOIN strategy_training.training_experiment_config_bindings portfolio_binding
      ON portfolio_binding.experiment_id = exit_binding.experiment_id
     AND portfolio_binding.config_type = 'PORTFOLIO_RULES'
    JOIN strategy_training.training_config_versions portfolio_config
      ON portfolio_config.config_version_id = portfolio_binding.config_version_id
     AND portfolio_config.config_type = 'PORTFOLIO_RULES'
     AND portfolio_config.status = 'READY'
    WHERE exit_binding.experiment_id = parent_record.experiment_id
      AND exit_binding.config_type = 'EXIT_RULES';
    definition := jsonb_build_object(
        'intrabar_conflict_policy', 'WORST_CASE',
        'max_holding_seconds', 86400,
        'model_family', 'TIME_EXIT_V1'
    );
    definition_hash := encode(digest(definition::text, 'sha256'), 'hex');
    baseline_experiment_id := strategy_training.create_training_experiment(
        'EXIT_POLICY', parent_record.experiment_id,
        execution_record.dataset_version_id,
        parent_record.resource_limit_config_version_id,
        format('Model-B round-zero 24h baseline %s', p_go_no_go_evaluation_id),
        encode(digest(concat_ws('|', parent_record.exposure_identity_hash,
            p_go_no_go_evaluation_id, definition_hash), 'sha256'), 'hex'),
        parent_record.created_by_user_id
    );
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    )
    SELECT baseline_experiment_id, binding.config_type, binding.config_version_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = parent_record.experiment_id;
    PERFORM strategy_training.transition_training_experiment(
        baseline_experiment_id, 'DRAFT', 'RUNNING', NULL,
        'training-model-b-orchestrator',
        'start immutable 24h round-zero baseline', gen_random_uuid()
    );
    baseline_iteration_id := strategy_training.create_training_iteration(
        baseline_experiment_id, 1, NULL, 'ROUND_ZERO_BASELINE',
        gate_record.random_seed,
        jsonb_build_object(
            'baseline_definition', definition,
            'baseline_definition_hash', definition_hash,
            'fee_model_version_id', fee_id,
            'formal_corpus_hash', corpus_record.corpus_hash,
            'go_no_go_evaluation_id', p_go_no_go_evaluation_id,
            'portfolio_rule_version_id', portfolio_id,
            'slippage_model_version_id', slippage_id
        ),
        jsonb_build_object('event_count', corpus_record.event_count), NULL
    );
    PERFORM strategy_training.transition_training_iteration(
        baseline_iteration_id, 'CREATED', 'VALIDATING', NULL, NULL, NULL,
        'training-model-b-orchestrator', 'validate round-zero baseline',
        gen_random_uuid()
    );
    PERFORM strategy_training.transition_training_iteration(
        baseline_iteration_id, 'VALIDATING', 'RUNNING', NULL, NULL, NULL,
        'training-model-b-orchestrator', 'start round-zero baseline replay',
        gen_random_uuid()
    );
    INSERT INTO strategy_training.training_model_b_round_zero_baseline_runs (
        go_no_go_evaluation_id, cross_fit_execution_id, formal_corpus_id,
        experiment_id, iteration_id, baseline_definition,
        baseline_definition_hash, event_count, state
    ) VALUES (
        p_go_no_go_evaluation_id, execution_record.cross_fit_execution_id,
        corpus_record.cross_fit_corpus_id, baseline_experiment_id,
        baseline_iteration_id, definition, definition_hash,
        corpus_record.event_count, 'REPLAYING'
    );
    IF EXISTS (
        SELECT 1
        FROM strategy_training.formal_model_b_cross_fit_entries promoted
        WHERE promoted.cross_fit_execution_id = execution_record.cross_fit_execution_id
          AND promoted.entry_time + interval '24 hours' > dataset_record.partition_end_at
    ) THEN
        RAISE EXCEPTION 'round-zero 24h path exceeds the TRAIN partition'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_model_b_sample_map (
        model_b_sample_id, entry_event_id, sample_use, natural_source, mapping_hash
    )
    SELECT encode(digest(concat_ws(':', promoted.entry_event_id,
               baseline_iteration_id, 'ROUND_ZERO_BASELINE'), 'sha256'), 'hex'),
           promoted.entry_event_id, 'MODEL_B_TRAIN', 'CROSS_FIT_MODEL_A',
           encode(digest(concat_ws(':', promoted.entry_event_id,
               baseline_iteration_id, corpus_record.corpus_hash), 'sha256'), 'hex')
    FROM strategy_training.formal_model_b_cross_fit_entries promoted
    WHERE promoted.cross_fit_execution_id = execution_record.cross_fit_execution_id;
    INSERT INTO strategy_training.training_exit_episode_inputs (
        exit_episode_id, model_b_sample_id, model_b_iteration_id,
        dataset_version_id, instrument_id, symbol, direction, entry_time,
        entry_reference_price, maximum_end_at, interval_seconds,
        exit_rule_version_id, fee_model_version_id, slippage_model_version_id
    )
    SELECT encode(digest(concat_ws(':', sample.model_b_sample_id,
               definition_hash, exit_rule_id, fee_id, slippage_id), 'sha256'), 'hex'),
           sample.model_b_sample_id, baseline_iteration_id,
           promoted.dataset_version_id, promoted.instrument_id, promoted.symbol,
           promoted.direction, promoted.entry_time, promoted.entry_price,
           promoted.entry_time + interval '24 hours', 300,
           exit_rule_id, fee_id, slippage_id
    FROM strategy_training.formal_model_b_cross_fit_entries promoted
    JOIN strategy_training.training_model_b_sample_map sample
      ON sample.entry_event_id = promoted.entry_event_id
     AND sample.sample_use = 'MODEL_B_TRAIN'
     AND sample.natural_source = 'CROSS_FIT_MODEL_A'
    WHERE promoted.cross_fit_execution_id = execution_record.cross_fit_execution_id
      AND sample.model_b_sample_id = encode(digest(concat_ws(':',
          promoted.entry_event_id, baseline_iteration_id,
          'ROUND_ZERO_BASELINE'), 'sha256'), 'hex');
    GET DIAGNOSTICS created_episode_count = ROW_COUNT;
    IF created_episode_count <> corpus_record.event_count THEN
        RAISE EXCEPTION 'round-zero episodes differ from the promoted corpus'
            USING ERRCODE = '23514';
    END IF;
    FOR episode_record IN
        SELECT episode.model_b_sample_id
        FROM strategy_training.training_exit_episode_inputs episode
        WHERE episode.model_b_iteration_id = baseline_iteration_id
        ORDER BY episode.model_b_sample_id
    LOOP
        PERFORM strategy_training.enqueue_training_task(
            baseline_experiment_id, baseline_iteration_id, NULL, NULL,
            'MODEL_B_REPLAY', 'MODEL_B',
            encode(digest(concat_ws('|', baseline_iteration_id,
                episode_record.model_b_sample_id, 'ROUND_ZERO_REPLAY'),
                'sha256'), 'hex'),
            jsonb_build_object('task_type', 'MODEL_B_REPLAY',
                'payload_version', 1,
                'model_b_sample_id', episode_record.model_b_sample_id), 20
        );
    END LOOP;
    RETURN 'ROUND_ZERO_BASELINE_INITIALIZED';
END
$$;

CREATE FUNCTION strategy_training.finalize_training_model_b_round_zero_baseline(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        baseline_record strategy_training.training_model_b_round_zero_baseline_runs%ROWTYPE;
        portfolio_record strategy_training.training_portfolio_runs%ROWTYPE;
        observed_count integer; accepted_count integer;
        accepted_net_pnl numeric; gross_pnl numeric; fees numeric;
        funding numeric; slippage numeric; net_expectancy numeric;
        metrics jsonb; outcome_chain_hash char(64); persisted_hash char(64);
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks WHERE task_id = p_task_id FOR UPDATE;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'PORTFOLIO_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL
       OR task_record.task_payload <> jsonb_build_object(
            'task_type', 'PORTFOLIO_EVALUATION', 'payload_version', 1
       ) THEN
        RAISE EXCEPTION 'round-zero finalization requires its portfolio evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT * INTO baseline_record
    FROM strategy_training.training_model_b_round_zero_baseline_runs baseline
    WHERE baseline.iteration_id = task_record.iteration_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF baseline_record.state = 'SUCCEEDED' THEN
        RETURN baseline_record.evidence_hash;
    END IF;
    IF baseline_record.state <> 'EVALUATING'
       OR baseline_record.experiment_id <> task_record.experiment_id
       OR EXISTS (
            SELECT 1 FROM strategy_training.training_tasks replay
            WHERE replay.iteration_id = baseline_record.iteration_id
              AND replay.task_type = 'MODEL_B_REPLAY'
              AND replay.state <> 'SUCCEEDED'
       ) THEN
        RAISE EXCEPTION 'round-zero replay evidence is incomplete'
            USING ERRCODE = '55000';
    END IF;
    SELECT * INTO STRICT portfolio_record
    FROM strategy_training.training_portfolio_runs portfolio
    WHERE portfolio.model_b_iteration_id = baseline_record.iteration_id
      AND portfolio.status = 'COMPLETE';
    SELECT count(*)::integer,
           COALESCE(sum(outcome.gross_pnl), 0),
           COALESCE(sum(outcome.entry_fee + outcome.exit_fee), 0),
           COALESCE(sum(outcome.funding_total), 0),
           COALESCE(sum(outcome.slippage_total), 0),
           encode(digest(COALESCE(string_agg(outcome.result_hash, ''
               ORDER BY outcome.exit_episode_id), ''), 'sha256'), 'hex')
    INTO observed_count, gross_pnl, fees, funding, slippage, outcome_chain_hash
    FROM strategy_training.training_exit_episode_inputs episode
    JOIN strategy_training.training_exit_outcomes outcome
      ON outcome.exit_episode_id = episode.exit_episode_id
    WHERE episode.model_b_iteration_id = baseline_record.iteration_id;
    SELECT count(*)::integer, COALESCE(sum(trade.net_pnl), 0)
    INTO accepted_count, accepted_net_pnl
    FROM strategy_training.training_portfolio_trades trade
    WHERE trade.portfolio_run_id = portfolio_record.portfolio_run_id;
    IF observed_count <> baseline_record.event_count
       OR portfolio_record.result_hash IS NULL
       OR EXISTS (
            SELECT 1
            FROM strategy_training.training_exit_episode_inputs episode
            JOIN strategy_training.training_exit_outcomes outcome
              ON outcome.exit_episode_id = episode.exit_episode_id
            WHERE episode.model_b_iteration_id = baseline_record.iteration_id
              AND outcome.risk_violation_codes <> '[]'::jsonb
       ) THEN
        RAISE EXCEPTION 'round-zero baseline facts are incomplete or unsafe'
            USING ERRCODE = '23514';
    END IF;
    net_expectancy := accepted_net_pnl
        / (portfolio_record.notional_per_trade * baseline_record.event_count) * 100;
    metrics := jsonb_build_object(
        'accepted_trade_count', accepted_count,
        'event_count', baseline_record.event_count,
        'gross_pnl_all_episodes', gross_pnl,
        'net_expectancy_percentage_points', net_expectancy,
        'portfolio_result_hash', portfolio_record.result_hash,
        'total_fees_all_episodes', fees,
        'total_funding_all_episodes', funding,
        'total_slippage_all_episodes', slippage
    );
    persisted_hash := encode(digest(concat_ws('|',
        baseline_record.baseline_definition_hash, metrics::text,
        outcome_chain_hash, portfolio_record.result_hash), 'sha256'), 'hex');
    INSERT INTO strategy_training.training_go_no_go_round_zero_baselines (
        go_no_go_evaluation_id, baseline_definition_hash,
        baseline_metrics, evidence_hash
    ) VALUES (
        baseline_record.go_no_go_evaluation_id,
        baseline_record.baseline_definition_hash, metrics, persisted_hash
    );
    UPDATE strategy_training.training_model_b_round_zero_baseline_runs
    SET state = 'SUCCEEDED', evidence_hash = persisted_hash,
        completed_at = clock_timestamp()
    WHERE go_no_go_evaluation_id = baseline_record.go_no_go_evaluation_id;
    RETURN persisted_hash;
END
$$;

CREATE FUNCTION strategy_training.advance_training_model_b_round_zero_baselines()
RETURNS TABLE (go_no_go_evaluation_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; task_record strategy_training.training_tasks%ROWTYPE;
        replay_count integer; succeeded_count integer;
BEGIN
    FOR candidate IN
        SELECT gate.go_no_go_evaluation_id
        FROM strategy_training.training_go_no_go_evaluations gate
        JOIN strategy_training.training_cross_fit_executions execution
          ON execution.experiment_id = gate.experiment_id
         AND execution.state = 'FORMAL_CORPUS_READY'
        WHERE gate.decision = 'PASS' AND gate.temporary_only
          AND NOT EXISTS (
              SELECT 1
              FROM strategy_training.training_model_b_round_zero_baseline_runs baseline
              WHERE baseline.go_no_go_evaluation_id = gate.go_no_go_evaluation_id
          )
        ORDER BY gate.created_at
    LOOP
        go_no_go_evaluation_id := candidate.go_no_go_evaluation_id;
        action := strategy_training.initialize_training_model_b_round_zero_baseline(
            candidate.go_no_go_evaluation_id
        );
        RETURN NEXT;
    END LOOP;
    FOR candidate IN
        SELECT baseline.*
        FROM strategy_training.training_model_b_round_zero_baseline_runs baseline
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = baseline.iteration_id
         AND iteration.state = 'RUNNING'
        WHERE baseline.state IN ('REPLAYING', 'EVALUATING', 'SUCCEEDED')
        ORDER BY baseline.created_at
    LOOP
        go_no_go_evaluation_id := candidate.go_no_go_evaluation_id;
        IF candidate.state = 'SUCCEEDED' THEN
            SELECT * INTO task_record
            FROM strategy_training.training_tasks task
            WHERE task.iteration_id = candidate.iteration_id
              AND task.task_type = 'PORTFOLIO_EVALUATION';
            IF task_record.state <> 'SUCCEEDED' THEN
                action := 'WAITING_ROUND_ZERO_TASK_COMPLETION';
                RETURN NEXT; CONTINUE;
            END IF;
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'SUCCEEDED', NULL,
                candidate.evidence_hash, NULL, 'training-model-b-orchestrator',
                'round-zero evidence task confirmed', gen_random_uuid()
            );
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator',
                'round-zero 24h baseline complete', gen_random_uuid()
            );
            action := 'ROUND_ZERO_BASELINE_COMPLETED'; RETURN NEXT; CONTINUE;
        END IF;
        IF EXISTS (
            SELECT 1 FROM strategy_training.training_tasks replay
            WHERE replay.iteration_id = candidate.iteration_id
              AND replay.task_type = 'MODEL_B_REPLAY'
              AND replay.state IN ('FAILED', 'CANCELLED')
        ) THEN
            UPDATE strategy_training.training_model_b_round_zero_baseline_runs
            SET state = 'FAILED', failure_code = 'ROUND_ZERO_REPLAY_FAILED',
                completed_at = clock_timestamp()
            WHERE go_no_go_evaluation_id = candidate.go_no_go_evaluation_id;
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                'ROUND_ZERO_REPLAY_FAILED', NULL, NULL,
                'training-model-b-orchestrator', 'round-zero replay failed',
                gen_random_uuid()
            );
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator', 'round-zero replay failed',
                gen_random_uuid()
            );
            action := 'ROUND_ZERO_BASELINE_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT count(*)::integer,
               count(*) FILTER (WHERE state = 'SUCCEEDED')::integer
        INTO replay_count, succeeded_count
        FROM strategy_training.training_tasks replay
        WHERE replay.iteration_id = candidate.iteration_id
          AND replay.task_type = 'MODEL_B_REPLAY';
        IF candidate.state = 'REPLAYING'
           AND (replay_count <> candidate.event_count
                OR succeeded_count <> candidate.event_count) THEN
            action := 'WAITING_ROUND_ZERO_REPLAY'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT * INTO task_record
        FROM strategy_training.training_tasks task
        WHERE task.iteration_id = candidate.iteration_id
          AND task.task_type = 'PORTFOLIO_EVALUATION';
        IF candidate.state = 'REPLAYING' AND NOT FOUND THEN
            PERFORM strategy_training.enqueue_training_task(
                candidate.experiment_id, candidate.iteration_id, NULL, NULL,
                'PORTFOLIO_EVALUATION', 'EVALUATOR',
                encode(digest(concat_ws('|', candidate.iteration_id,
                    'ROUND_ZERO_PORTFOLIO'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'PORTFOLIO_EVALUATION',
                    'payload_version', 1), 20
            );
            UPDATE strategy_training.training_model_b_round_zero_baseline_runs
            SET state = 'EVALUATING'
            WHERE go_no_go_evaluation_id = candidate.go_no_go_evaluation_id;
            action := 'ROUND_ZERO_PORTFOLIO_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF task_record.state IN ('FAILED', 'CANCELLED') THEN
            UPDATE strategy_training.training_model_b_round_zero_baseline_runs
            SET state = 'FAILED', failure_code = 'ROUND_ZERO_PORTFOLIO_FAILED',
                completed_at = clock_timestamp()
            WHERE go_no_go_evaluation_id = candidate.go_no_go_evaluation_id;
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                'ROUND_ZERO_PORTFOLIO_FAILED', task_record.result_hash, NULL,
                'training-model-b-orchestrator', 'round-zero portfolio failed',
                gen_random_uuid()
            );
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator', 'round-zero portfolio failed',
                gen_random_uuid()
            );
            action := 'ROUND_ZERO_BASELINE_FAILED'; RETURN NEXT; CONTINUE;
        ELSIF task_record.state = 'SUCCEEDED' THEN
            UPDATE strategy_training.training_model_b_round_zero_baseline_runs
            SET state = 'FAILED', failure_code = 'ROUND_ZERO_EVIDENCE_MISSING',
                completed_at = clock_timestamp()
            WHERE go_no_go_evaluation_id = candidate.go_no_go_evaluation_id;
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                'ROUND_ZERO_EVIDENCE_MISSING', task_record.result_hash, NULL,
                'training-model-b-orchestrator',
                'round-zero portfolio completed without baseline evidence',
                gen_random_uuid()
            );
            PERFORM strategy_training.transition_training_experiment(
                candidate.experiment_id, 'RUNNING', 'STOPPED', NULL,
                'training-model-b-orchestrator',
                'round-zero evidence missing', gen_random_uuid()
            );
            action := 'ROUND_ZERO_EVIDENCE_MISSING'; RETURN NEXT; CONTINUE;
        END IF;
        action := 'WAITING_ROUND_ZERO_PORTFOLIO'; RETURN NEXT;
    END LOOP;
END
$$;

ALTER TABLE strategy_training.training_model_b_round_zero_baseline_runs
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_effective_model_b_exit_config(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.initialize_training_model_b_round_zero_baseline(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_model_b_round_zero_baseline(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_b_round_zero_baselines()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_model_b_round_zero_baseline_runs FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.initialize_training_model_b_round_zero_baseline(uuid),
    strategy_training.finalize_training_model_b_round_zero_baseline(uuid, uuid),
    strategy_training.advance_training_model_b_round_zero_baselines()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.initialize_training_model_b_round_zero_baseline(uuid),
    strategy_training.advance_training_model_b_round_zero_baselines()
TO tb2_training_orchestrator;
GRANT EXECUTE ON FUNCTION
    strategy_training.finalize_training_model_b_round_zero_baseline(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '095_training_model_b_round_zero_baseline',
    encode(digest('auto_trade_v2_095_training_model_b_round_zero_baseline_v1',
                  'sha256'), 'hex'),
    'Replay and persist the immutable 24h fixed-exit baseline before formal Model-B search'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
