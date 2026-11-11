\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_cross_fit_model_b_fold_runs
ADD COLUMN evaluation_experiment_id uuid UNIQUE
    REFERENCES strategy_training.training_experiments;

CREATE FUNCTION strategy_training.prepare_cross_fit_model_b_fold_evaluation(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer
)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE fold_record strategy_training.training_cross_fit_model_b_fold_runs%ROWTYPE;
        gate_record strategy_training.training_cross_fit_model_b_gate_runs%ROWTYPE;
        temporary_record strategy_training.training_experiments%ROWTYPE;
        selected_iteration strategy_training.training_iterations%ROWTYPE;
        selected_policy strategy_training.training_model_b_compiled_candidate_policies%ROWTYPE;
        entry_record strategy_training.training_entry_events%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        v_evaluation_experiment_id uuid; v_evaluation_iteration_id uuid;
        exit_rule_id uuid; fee_model_id uuid; slippage_model_id uuid;
        holding_seconds integer; expected_count integer; created_count integer := 0;
        sample_id char(64); episode_id char(64); event_record record;
BEGIN
    SELECT * INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_model_b_fold_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number FOR UPDATE;
    IF fold_record.state = 'EVALUATING' THEN
        RETURN fold_record.evaluation_iteration_id;
    END IF;
    IF fold_record.state <> 'SEARCHING' THEN
        RAISE EXCEPTION 'nested Model-B fold is not awaiting evaluation'
            USING ERRCODE = '55000';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_optimizer_runs run
        WHERE run.optimizer_run_id = fold_record.tpe_optimizer_run_id
          AND run.state = 'SUCCEEDED'
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_optimizer_runs run
        WHERE run.optimizer_run_id = fold_record.random_optimizer_run_id
          AND run.state = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'both nested optimizer controls must finish before fold-out evaluation'
            USING ERRCODE = '55000';
    END IF;
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND state = 'RUNNING';
    SELECT * INTO STRICT temporary_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = gate_record.temporary_experiment_id
      AND state = 'RUNNING';

    -- Eligibility is immutable. Refuse to evaluate if the materialized event
    -- boundary no longer matches the snapshot used to admit this fold.
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_model_b_fold_eligibility eligibility
        WHERE eligibility.cross_fit_execution_id = p_cross_fit_execution_id
          AND eligibility.outer_fold_number = p_outer_fold_number
          AND eligibility.eligibility = 'ELIGIBLE'
          AND eligibility.prior_training_event_count = (
              SELECT count(*)
              FROM strategy_training.training_cross_fit_model_b_fold_events event
              WHERE event.cross_fit_execution_id = p_cross_fit_execution_id
                AND event.outer_fold_number = p_outer_fold_number
                AND event.event_role = 'TRAIN_PRIOR')
          AND eligibility.fold_out_event_count = (
              SELECT count(*)
              FROM strategy_training.training_cross_fit_model_b_fold_events event
              WHERE event.cross_fit_execution_id = p_cross_fit_execution_id
                AND event.outer_fold_number = p_outer_fold_number
                AND event.event_role = 'FOLD_OUT')
    ) THEN
        RAISE EXCEPTION 'nested fold events differ from frozen eligibility snapshot'
            USING ERRCODE = '23514';
    END IF;

    -- Candidate selection uses TRAIN-only TPE objectives. RANDOM remains an
    -- audit control and can never supply the fold-out candidate.
    SELECT iteration.* INTO STRICT selected_iteration
    FROM strategy_training.training_optimizer_trial_iterations trial_link
    JOIN strategy_training.training_optimizer_trial_proposals proposal
      ON proposal.optimizer_trial_proposal_id = trial_link.optimizer_trial_proposal_id
     AND proposal.optimizer_run_id = fold_record.tpe_optimizer_run_id
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = trial_link.iteration_id
     AND iteration.state = 'SUCCEEDED'
    JOIN strategy_training.training_model_b_iteration_objectives objective
      ON objective.model_b_iteration_id = iteration.iteration_id
    ORDER BY objective.net_expectancy_percentage_points DESC,
             iteration.candidate_content_hash, iteration.iteration_id
    LIMIT 1;
    SELECT * INTO STRICT selected_policy
    FROM strategy_training.training_model_b_compiled_candidate_policies
    WHERE model_b_iteration_id = selected_iteration.iteration_id
      AND optimizer_run_id = fold_record.tpe_optimizer_run_id
      AND temporary_only;

    v_evaluation_experiment_id := strategy_training.create_training_experiment(
        'EXIT_POLICY', gate_record.temporary_experiment_id,
        temporary_record.dataset_version_id,
        temporary_record.resource_limit_config_version_id,
        format('Q036 Model-B fold-out %s fold %s',
               p_cross_fit_execution_id, p_outer_fold_number),
        encode(digest(concat_ws('|', temporary_record.exposure_identity_hash,
            p_outer_fold_number, selected_iteration.candidate_content_hash,
            'INDEPENDENT_FOLD_OUT'), 'sha256'), 'hex'),
        temporary_record.created_by_user_id);
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id)
    SELECT v_evaluation_experiment_id, binding.config_type, binding.config_version_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = gate_record.temporary_experiment_id;
    PERFORM strategy_training.transition_training_experiment(
        v_evaluation_experiment_id, 'DRAFT', 'RUNNING', NULL,
        'training-model-b-orchestrator',
        'start independent outer-fold evaluation', gen_random_uuid());

    v_evaluation_iteration_id := strategy_training.create_training_iteration(
        v_evaluation_experiment_id, 1, selected_iteration.iteration_id,
        'OPTUNA_TPE', selected_iteration.random_seed,
        selected_iteration.candidate_parameters,
        jsonb_build_object(
            'evaluation_scope', 'INDEPENDENT_FOLD_OUT',
            'cross_fit_execution_id', p_cross_fit_execution_id,
            'outer_fold_number', p_outer_fold_number,
            'selected_iteration_id', selected_iteration.iteration_id));
    PERFORM strategy_training.transition_training_iteration(
        v_evaluation_iteration_id, 'CREATED', 'VALIDATING', NULL, NULL,
        NULL, 'training-model-b-orchestrator',
        'validate immutable fold-out candidate', gen_random_uuid());
    PERFORM strategy_training.transition_training_iteration(
        v_evaluation_iteration_id, 'VALIDATING', 'RUNNING', NULL, NULL,
        NULL, 'training-model-b-orchestrator',
        'start independent fold-out replay', gen_random_uuid());

    INSERT INTO strategy_training.training_model_b_compiled_candidate_policies (
        model_b_iteration_id, optimizer_run_id,
        search_space_config_version_id, base_exit_rule_version_id,
        candidate_content_hash, effective_exit_rule_config,
        effective_exit_rule_content_hash, remaining_position_fraction,
        temporary_only)
    VALUES (v_evaluation_iteration_id, selected_policy.optimizer_run_id,
        selected_policy.search_space_config_version_id,
        selected_policy.base_exit_rule_version_id,
        selected_policy.candidate_content_hash,
        selected_policy.effective_exit_rule_config,
        selected_policy.effective_exit_rule_content_hash,
        selected_policy.remaining_position_fraction, true);

    SELECT binding.config_version_id INTO STRICT exit_rule_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = v_evaluation_experiment_id
      AND binding.config_type = 'EXIT_RULES';
    IF exit_rule_id <> selected_policy.base_exit_rule_version_id THEN
        RAISE EXCEPTION 'selected policy exit-rule anchor changed before evaluation'
            USING ERRCODE = '23514';
    END IF;
    SELECT binding.config_version_id INTO STRICT fee_model_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = v_evaluation_experiment_id
      AND binding.config_type = 'FEE_MODEL';
    SELECT binding.config_version_id INTO STRICT slippage_model_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = v_evaluation_experiment_id
      AND binding.config_type = 'SLIPPAGE_MODEL';
    holding_seconds := (selected_policy.effective_exit_rule_config
                        ->> 'max_holding_seconds')::integer;

    UPDATE strategy_training.training_cross_fit_model_b_fold_runs
    SET selected_iteration_id = selected_iteration.iteration_id,
        evaluation_experiment_id = v_evaluation_experiment_id,
        evaluation_iteration_id = v_evaluation_iteration_id,
        state = 'EVALUATING'
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number;

    FOR event_record IN
        SELECT event.entry_event_id
        FROM strategy_training.training_cross_fit_model_b_fold_events event
        WHERE event.cross_fit_execution_id = p_cross_fit_execution_id
          AND event.outer_fold_number = p_outer_fold_number
          AND event.event_role = 'FOLD_OUT'
        ORDER BY event.entry_event_id
    LOOP
        SELECT * INTO STRICT entry_record
        FROM strategy_training.training_entry_events
        WHERE entry_event_id = event_record.entry_event_id
          AND status = 'COMPLETE';
        SELECT * INTO STRICT dataset_record
        FROM strategy_training.training_dataset_versions
        WHERE dataset_version_id = entry_record.dataset_version_id
          AND status = 'READY' AND partition = 'TRAIN';
        IF entry_record.signal_time < fold_record.prediction_start_at
           OR entry_record.signal_time >= fold_record.prediction_end_at
           OR entry_record.entry_time + make_interval(secs => holding_seconds)
              > dataset_record.partition_end_at THEN
            RAISE EXCEPTION 'fold-out event exceeds its frozen evaluation boundary'
                USING ERRCODE = '23514';
        END IF;
        sample_id := encode(digest(concat_ws(':', event_record.entry_event_id,
            v_evaluation_iteration_id, 'GO_NO_GO'), 'sha256'), 'hex');
        episode_id := encode(digest(concat_ws(':', sample_id, exit_rule_id,
            fee_model_id, slippage_model_id,
            selected_policy.effective_exit_rule_content_hash), 'sha256'), 'hex');
        INSERT INTO strategy_training.training_model_b_sample_map (
            model_b_sample_id, entry_event_id, sample_use,
            natural_source, mapping_hash)
        VALUES (sample_id, event_record.entry_event_id, 'GO_NO_GO',
            'CROSS_FIT_MODEL_A_CANDIDATE',
            encode(digest(sample_id || ':' || event_record.entry_event_id,
                          'sha256'), 'hex'));
        INSERT INTO strategy_training.training_exit_episode_inputs (
            exit_episode_id, model_b_sample_id, model_b_iteration_id,
            dataset_version_id, instrument_id, symbol, direction, entry_time,
            entry_reference_price, maximum_end_at, interval_seconds,
            exit_rule_version_id, fee_model_version_id,
            slippage_model_version_id)
        VALUES (episode_id, sample_id, v_evaluation_iteration_id,
            entry_record.dataset_version_id, entry_record.instrument_id,
            entry_record.symbol, entry_record.direction, entry_record.entry_time,
            entry_record.entry_price,
            entry_record.entry_time + make_interval(secs => holding_seconds),
            dataset_record.interval_seconds, exit_rule_id,
            fee_model_id, slippage_model_id);
        PERFORM strategy_training.bind_cross_fit_model_b_fold_episode(
            p_cross_fit_execution_id, p_outer_fold_number,
            event_record.entry_event_id, episode_id);
        PERFORM strategy_training.enqueue_training_task(
            v_evaluation_experiment_id, v_evaluation_iteration_id, NULL, NULL,
            'MODEL_B_REPLAY', 'MODEL_B',
            encode(digest(concat_ws('|', v_evaluation_iteration_id,
                sample_id, 'MODEL_B_REPLAY'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'MODEL_B_REPLAY',
                'payload_version', 1, 'model_b_sample_id', sample_id), 20);
        created_count := created_count + 1;
    END LOOP;
    SELECT count(*)::integer INTO expected_count
    FROM strategy_training.training_cross_fit_model_b_fold_events
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number
      AND event_role = 'FOLD_OUT';
    IF expected_count = 0 OR created_count <> expected_count THEN
        RAISE EXCEPTION 'independent fold-out replay set is incomplete'
            USING ERRCODE = '23514';
    END IF;
    RETURN v_evaluation_iteration_id;
END
$$;

CREATE FUNCTION strategy_training.advance_cross_fit_model_b_nested_searches()
RETURNS TABLE (cross_fit_execution_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE candidate record;
BEGIN
    -- Initialization remains an explicit administrative decision. Once a
    -- nested gate exists, the orchestrator may only advance completed search
    -- pairs into their already-frozen independent fold-out evaluation.
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
        action := format('FOLD_%s_EVALUATION_CREATED',
                         candidate.outer_fold_number);
        RETURN NEXT;
    END LOOP;
END
$$;

ALTER FUNCTION strategy_training.prepare_cross_fit_model_b_fold_evaluation(
    uuid, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_cross_fit_model_b_nested_searches()
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.prepare_cross_fit_model_b_fold_evaluation(uuid, integer),
    strategy_training.advance_cross_fit_model_b_nested_searches()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.prepare_cross_fit_model_b_fold_evaluation(uuid, integer),
    strategy_training.advance_cross_fit_model_b_nested_searches()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES ('092_training_cross_fit_model_b_fold_evaluation',
    encode(digest('auto_trade_v2_092_training_cross_fit_model_b_fold_evaluation_v1',
                  'sha256'), 'hex'),
    'Create isolated Model-B outer-fold evaluation iterations from TRAIN-only TPE winners')
ON CONFLICT (version) DO NOTHING;

COMMIT;
