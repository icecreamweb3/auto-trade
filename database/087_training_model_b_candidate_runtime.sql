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
    'CROSS_FIT_EVALUATE_GATE'
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

ALTER TABLE strategy_training.training_model_b_sample_map
DROP CONSTRAINT training_model_b_sample_map_sample_use_check;
ALTER TABLE strategy_training.training_model_b_sample_map
DROP CONSTRAINT training_model_b_sample_map_entry_event_id_sample_use_key;
ALTER TABLE strategy_training.training_model_b_sample_map
ADD CONSTRAINT training_model_b_sample_map_sample_use_check CHECK (
    sample_use IN (
        'MODEL_B_PROTOTYPE', 'GO_NO_GO',
        'MODEL_B_TRAIN', 'MODEL_B_TRAIN_CONTROL'
    )
);

CREATE TABLE strategy_training.training_model_b_compiled_candidate_policies (
    model_b_iteration_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_iterations,
    optimizer_run_id uuid NOT NULL REFERENCES strategy_training.training_optimizer_runs,
    search_space_config_version_id uuid NOT NULL
        REFERENCES strategy_training.training_config_versions,
    base_exit_rule_version_id uuid NOT NULL
        REFERENCES strategy_training.training_config_versions,
    candidate_content_hash char(64) NOT NULL,
    effective_exit_rule_config jsonb NOT NULL,
    effective_exit_rule_content_hash char(64) NOT NULL,
    remaining_position_fraction numeric NOT NULL
        CHECK (remaining_position_fraction > 0 AND remaining_position_fraction <= 1),
    temporary_only boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (candidate_content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(effective_exit_rule_config) = 'object'
           AND effective_exit_rule_config <> '{}'::jsonb),
    CHECK (effective_exit_rule_content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (effective_exit_rule_content_hash = encode(
        digest(effective_exit_rule_config::text, 'sha256'), 'hex'
    ))
);

CREATE TRIGGER trg_training_model_b_compiled_candidate_policies_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_model_b_compiled_candidate_policies
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE FUNCTION strategy_training.training_model_b_candidate_preparation_context(
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
        is_temporary boolean; event_ids jsonb; existing_hash char(64);
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
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
        WHERE run_record.optimizer_run_id IN (
            gate_run.tpe_optimizer_run_id, gate_run.random_optimizer_run_id
        ) AND gate_run.state = 'RUNNING'
    ) INTO is_temporary;
    IF is_temporary THEN
        SELECT jsonb_agg(to_jsonb(member.entry_event_id::text)
                         ORDER BY member.entry_event_id)
        INTO event_ids
        FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
        JOIN strategy_training.training_cross_fit_corpus_events member
          ON member.cross_fit_corpus_id = gate_run.candidate_corpus_id
        WHERE run_record.optimizer_run_id IN (
            gate_run.tpe_optimizer_run_id, gate_run.random_optimizer_run_id
        ) AND gate_run.state = 'RUNNING'
          AND member.declared_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
          AND member.declared_use = 'GO_NO_GO';
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

CREATE FUNCTION strategy_training.record_training_model_b_compiled_candidate_policy(
    p_task_id uuid, p_lease_token uuid, p_effective_exit_rule_config jsonb,
    p_remaining_position_fraction numeric
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE context_record record; persisted_hash char(64);
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_model_b_candidate_preparation_context(
        p_task_id, p_lease_token
    );
    persisted_hash := encode(digest(p_effective_exit_rule_config::text, 'sha256'), 'hex');
    IF context_record.existing_effective_hash IS NOT NULL THEN
        IF context_record.existing_effective_hash <> persisted_hash THEN
            RAISE EXCEPTION 'compiled candidate policy is immutable'
                USING ERRCODE = '55000';
        END IF;
        RETURN persisted_hash;
    END IF;
    IF jsonb_typeof(p_effective_exit_rule_config) IS DISTINCT FROM 'object'
       OR p_effective_exit_rule_config ->> 'model_family' <> 'RULE_BASED_EXIT_V2'
       OR p_effective_exit_rule_config ->> 'return_basis' <>
          'ENTRY_FILL_PRICE_PERCENT'
       OR p_effective_exit_rule_config ->> 'intrabar_conflict_policy' <> 'WORST_CASE'
       OR p_effective_exit_rule_config ->> 'rule_activation_timing' <> 'NEXT_BAR'
       OR jsonb_typeof(p_effective_exit_rule_config -> 'max_holding_seconds')
          IS DISTINCT FROM 'number'
       OR (p_effective_exit_rule_config ->> 'max_holding_seconds')::integer < 300
       OR (p_effective_exit_rule_config ->> 'max_holding_seconds')::integer > 86400
       OR (p_effective_exit_rule_config ->> 'max_holding_seconds')::integer % 300 <> 0
       OR p_remaining_position_fraction <= 0
       OR p_remaining_position_fraction > 1 THEN
        RAISE EXCEPTION 'compiled Model-B candidate violates its governed runtime envelope'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_model_b_compiled_candidate_policies (
        model_b_iteration_id, optimizer_run_id,
        search_space_config_version_id, base_exit_rule_version_id,
        candidate_content_hash, effective_exit_rule_config,
        effective_exit_rule_content_hash, remaining_position_fraction,
        temporary_only
    ) VALUES (
        context_record.model_b_iteration_id, context_record.optimizer_run_id,
        context_record.search_space_config_version_id,
        context_record.base_exit_rule_version_id,
        context_record.candidate_content_hash, p_effective_exit_rule_config,
        persisted_hash, p_remaining_position_fraction, context_record.temporary_only
    );
    RETURN persisted_hash;
END
$$;

CREATE FUNCTION strategy_training.create_training_model_b_candidate_exit_episode(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64)
)
RETURNS TABLE (created_exit_episode_id char(64), created_model_b_sample_id char(64))
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE context_record record; entry_record strategy_training.training_entry_events%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        policy_record strategy_training.training_model_b_compiled_candidate_policies%ROWTYPE;
        fee_id uuid; slip_id uuid; sample_use_name text; source_name text;
        sample_id char(64); episode_id char(64); holding_seconds integer;
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_model_b_candidate_preparation_context(
        p_task_id, p_lease_token
    );
    IF NOT context_record.input_entry_event_ids ? p_entry_event_id::text THEN
        RAISE EXCEPTION 'entry is outside the frozen Model-B candidate corpus'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT policy_record
    FROM strategy_training.training_model_b_compiled_candidate_policies
    WHERE model_b_iteration_id = context_record.model_b_iteration_id;
    SELECT * INTO STRICT entry_record FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id AND status = 'COMPLETE';
    SELECT * INTO STRICT dataset_record FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = entry_record.dataset_version_id AND status = 'READY';
    SELECT fee.config_version_id, slip.config_version_id INTO STRICT fee_id, slip_id
    FROM strategy_training.training_experiment_config_bindings fee_binding
    JOIN strategy_training.training_config_versions fee
      ON fee.config_version_id = fee_binding.config_version_id
     AND fee.config_type = 'FEE_MODEL' AND fee.status = 'READY'
    JOIN strategy_training.training_experiment_config_bindings slip_binding
      ON slip_binding.experiment_id = fee_binding.experiment_id
     AND slip_binding.config_type = 'SLIPPAGE_MODEL'
    JOIN strategy_training.training_config_versions slip
      ON slip.config_version_id = slip_binding.config_version_id
     AND slip.config_type = 'SLIPPAGE_MODEL' AND slip.status = 'READY'
    WHERE fee_binding.experiment_id = (
        SELECT experiment_id FROM strategy_training.training_iterations
        WHERE iteration_id = context_record.model_b_iteration_id
    ) AND fee_binding.config_type = 'FEE_MODEL';
    IF context_record.temporary_only THEN
        IF entry_record.source <> 'CROSS_FIT_MODEL_A_CANDIDATE'
           OR entry_record.entry_use <> 'GO_NO_GO' THEN
            RAISE EXCEPTION 'temporary candidate requires GO_NO_GO Cross-fit entries'
                USING ERRCODE = '23514';
        END IF;
        sample_use_name := 'GO_NO_GO'; source_name := 'CROSS_FIT_MODEL_A_CANDIDATE';
    ELSIF entry_record.source = 'ADVERSE_OR_RANGE_CONTROL' THEN
        sample_use_name := 'MODEL_B_TRAIN_CONTROL'; source_name := entry_record.source;
    ELSIF EXISTS (
        SELECT 1 FROM strategy_training.formal_model_b_cross_fit_entries promoted
        WHERE promoted.entry_event_id = entry_record.entry_event_id
          AND promoted.dataset_version_id = entry_record.dataset_version_id
    ) THEN
        sample_use_name := 'MODEL_B_TRAIN'; source_name := 'CROSS_FIT_MODEL_A';
    ELSE
        RAISE EXCEPTION 'formal candidate requires promoted or control entries'
            USING ERRCODE = '23514';
    END IF;
    holding_seconds := (policy_record.effective_exit_rule_config
                        ->> 'max_holding_seconds')::integer;
    IF entry_record.entry_time + make_interval(secs => holding_seconds)
       > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'candidate holding path exceeds its TRAIN partition'
            USING ERRCODE = '23514';
    END IF;
    sample_id := encode(digest(concat_ws(':', p_entry_event_id,
        context_record.model_b_iteration_id, sample_use_name), 'sha256'), 'hex');
    episode_id := encode(digest(concat_ws(':', sample_id,
        context_record.base_exit_rule_version_id, fee_id, slip_id,
        policy_record.effective_exit_rule_content_hash), 'sha256'), 'hex');
    INSERT INTO strategy_training.training_model_b_sample_map (
        model_b_sample_id, entry_event_id, sample_use, natural_source, mapping_hash
    ) VALUES (sample_id, p_entry_event_id, sample_use_name, source_name,
        encode(digest(sample_id || ':' || p_entry_event_id, 'sha256'), 'hex'))
    ON CONFLICT (model_b_sample_id) DO NOTHING;
    INSERT INTO strategy_training.training_exit_episode_inputs (
        exit_episode_id, model_b_sample_id, model_b_iteration_id,
        dataset_version_id, instrument_id, symbol, direction, entry_time,
        entry_reference_price, maximum_end_at, interval_seconds,
        exit_rule_version_id, fee_model_version_id, slippage_model_version_id
    ) VALUES (episode_id, sample_id, context_record.model_b_iteration_id,
        entry_record.dataset_version_id, entry_record.instrument_id,
        entry_record.symbol, entry_record.direction, entry_record.entry_time,
        entry_record.entry_price,
        entry_record.entry_time + make_interval(secs => holding_seconds),
        dataset_record.interval_seconds, context_record.base_exit_rule_version_id,
        fee_id, slip_id)
    ON CONFLICT (exit_episode_id) DO NOTHING;
    RETURN QUERY SELECT episode_id, sample_id;
END
$$;

CREATE FUNCTION strategy_training.finalize_training_model_b_candidate_preparation(
    p_task_id uuid, p_lease_token uuid
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE context_record record; episode_record record; preparation_hash char(64);
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_model_b_candidate_preparation_context(
        p_task_id, p_lease_token
    );
    IF context_record.existing_effective_hash IS NULL THEN
        RAISE EXCEPTION 'candidate policy must be compiled before finalization'
            USING ERRCODE = '23514';
    END IF;
    IF (SELECT count(*) FROM strategy_training.training_exit_episode_inputs
        WHERE model_b_iteration_id = context_record.model_b_iteration_id)
       <> jsonb_array_length(context_record.input_entry_event_ids) THEN
        RAISE EXCEPTION 'candidate episodes do not match the frozen input corpus'
            USING ERRCODE = '23514';
    END IF;
    FOR episode_record IN
        SELECT episode.model_b_sample_id, episode.exit_episode_id
        FROM strategy_training.training_exit_episode_inputs episode
        WHERE episode.model_b_iteration_id = context_record.model_b_iteration_id
        ORDER BY episode.model_b_sample_id
    LOOP
        PERFORM strategy_training.enqueue_training_task(
            (SELECT experiment_id FROM strategy_training.training_iterations
             WHERE iteration_id = context_record.model_b_iteration_id),
            context_record.model_b_iteration_id, context_record.optimizer_run_id,
            p_task_id, 'MODEL_B_REPLAY', 'MODEL_B',
            encode(digest(concat_ws('|', context_record.model_b_iteration_id,
                episode_record.model_b_sample_id, 'MODEL_B_REPLAY'), 'sha256'), 'hex'),
            jsonb_build_object('task_type', 'MODEL_B_REPLAY', 'payload_version', 1,
                'model_b_sample_id', episode_record.model_b_sample_id), 20
        );
    END LOOP;
    SELECT encode(digest(concat_ws('|', context_record.model_b_iteration_id,
        context_record.existing_effective_hash,
        jsonb_array_length(context_record.input_entry_event_ids)), 'sha256'), 'hex')
    INTO preparation_hash;
    RETURN preparation_hash;
END
$$;

-- Candidate policies are overlays.  The READY base version remains the audit anchor;
-- workers and evaluators receive the exact same immutable effective JSON.
CREATE OR REPLACE FUNCTION strategy_training.training_effective_model_b_exit_config(
    p_model_b_iteration_id uuid, p_base_exit_rule_version_id uuid
)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
    SELECT COALESCE(
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

CREATE OR REPLACE FUNCTION strategy_training.training_model_b_replay_context(
    p_task_id uuid, p_lease_token uuid, p_model_b_sample_id char(64)
)
RETURNS TABLE (
    model_b_sample_id char(64), entry_event_id char(64), exit_episode_id char(64),
    episode_status text, exit_rule_version_id uuid, exit_rule_config jsonb,
    fee_model_version_id uuid, fee_model_config jsonb,
    slippage_model_version_id uuid, slippage_model_config jsonb, notional numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        episode_record strategy_training.training_exit_episode_inputs%ROWTYPE;
        sample_record strategy_training.training_model_b_sample_map%ROWTYPE;
        exit_config jsonb; fee_config jsonb; slippage_config jsonb;
        portfolio_config jsonb;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'MODEL_B'
       OR task_record.task_type <> 'MODEL_B_REPLAY'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'MODEL_B replay requires its active model-B lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT episode.* INTO STRICT episode_record
    FROM strategy_training.training_exit_episode_inputs episode
    WHERE episode.model_b_sample_id = p_model_b_sample_id;
    SELECT sample.* INTO STRICT sample_record
    FROM strategy_training.training_model_b_sample_map sample
    WHERE sample.model_b_sample_id = p_model_b_sample_id;
    IF task_record.iteration_id IS NULL
       OR episode_record.model_b_iteration_id <> task_record.iteration_id
       OR episode_record.status NOT IN ('RUNNING', 'DECIDED')
       OR NOT (
            (sample_record.sample_use = 'MODEL_B_PROTOTYPE'
             AND sample_record.natural_source = 'FIXED_BASELINE_MODEL_A')
         OR (sample_record.sample_use = 'GO_NO_GO'
             AND sample_record.natural_source = 'CROSS_FIT_MODEL_A_CANDIDATE')
         OR (sample_record.sample_use = 'MODEL_B_TRAIN'
             AND sample_record.natural_source = 'CROSS_FIT_MODEL_A')
         OR (sample_record.sample_use = 'MODEL_B_TRAIN_CONTROL'
             AND sample_record.natural_source = 'ADVERSE_OR_RANGE_CONTROL')
       ) THEN
        RAISE EXCEPTION 'model-B sample does not belong to its governed leased use'
            USING ERRCODE = '23514';
    END IF;
    exit_config := strategy_training.training_effective_model_b_exit_config(
        episode_record.model_b_iteration_id, episode_record.exit_rule_version_id
    );
    IF exit_config IS NULL THEN
        RAISE EXCEPTION 'model-B replay has no effective exit policy'
            USING ERRCODE = '23514';
    END IF;
    SELECT config_json INTO STRICT fee_config
    FROM strategy_training.training_config_versions
    WHERE config_version_id = episode_record.fee_model_version_id
      AND config_type = 'FEE_MODEL' AND status = 'READY';
    SELECT config_json INTO STRICT slippage_config
    FROM strategy_training.training_config_versions
    WHERE config_version_id = episode_record.slippage_model_version_id
      AND config_type = 'SLIPPAGE_MODEL' AND status = 'READY';
    SELECT config.config_json INTO STRICT portfolio_config
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'PORTFOLIO_RULES'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'PORTFOLIO_RULES' AND config.status = 'READY'
    WHERE iteration.iteration_id = episode_record.model_b_iteration_id;
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings exit_binding
          ON exit_binding.experiment_id = iteration.experiment_id
         AND exit_binding.config_type = 'EXIT_RULES'
         AND exit_binding.config_version_id = episode_record.exit_rule_version_id
        JOIN strategy_training.training_experiment_config_bindings fee_binding
          ON fee_binding.experiment_id = iteration.experiment_id
         AND fee_binding.config_type = 'FEE_MODEL'
         AND fee_binding.config_version_id = episode_record.fee_model_version_id
        JOIN strategy_training.training_experiment_config_bindings slip_binding
          ON slip_binding.experiment_id = iteration.experiment_id
         AND slip_binding.config_type = 'SLIPPAGE_MODEL'
         AND slip_binding.config_version_id = episode_record.slippage_model_version_id
        WHERE iteration.iteration_id = episode_record.model_b_iteration_id
          AND iteration.state = 'RUNNING'
    ) THEN
        RAISE EXCEPTION 'model-B replay configs are not frozen on the running iteration'
            USING ERRCODE = '23514';
    END IF;
    RETURN QUERY SELECT episode_record.model_b_sample_id,
        sample_record.entry_event_id, episode_record.exit_episode_id,
        episode_record.status::text, episode_record.exit_rule_version_id,
        exit_config, episode_record.fee_model_version_id, fee_config,
        episode_record.slippage_model_version_id, slippage_config,
        (portfolio_config ->> 'notional_per_trade')::numeric;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_portfolio_evaluation_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    model_b_iteration_id uuid, exit_rule_version_id uuid,
    exit_rule_config jsonb, fee_model_version_id uuid, fee_model_config jsonb,
    slippage_model_version_id uuid, slippage_model_config jsonb,
    portfolio_rule_version_id uuid, portfolio_rule_config jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
        iteration_record strategy_training.training_iterations%ROWTYPE;
        experiment_record strategy_training.training_experiments%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        exit_id uuid; fee_id uuid; slippage_id uuid; portfolio_id uuid;
        exit_json jsonb; fee_json jsonb; slippage_json jsonb; portfolio_json jsonb;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks
    WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'PORTFOLIO_EVALUATION'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'portfolio evaluation requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT * INTO STRICT iteration_record
    FROM strategy_training.training_iterations
    WHERE iteration_id = task_record.iteration_id;
    SELECT * INTO STRICT experiment_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = iteration_record.experiment_id;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = experiment_record.dataset_version_id;
    IF task_record.experiment_id <> experiment_record.experiment_id
       OR iteration_record.state <> 'RUNNING' OR experiment_record.state <> 'RUNNING'
       OR experiment_record.experiment_mode <> 'EXIT_POLICY'
       OR dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN' THEN
        RAISE EXCEPTION 'portfolio evaluation requires a running TRAIN EXIT_POLICY iteration'
            USING ERRCODE = '23514';
    END IF;
    SELECT binding.config_version_id,
           strategy_training.training_effective_model_b_exit_config(
               iteration_record.iteration_id, binding.config_version_id
           )
    INTO STRICT exit_id, exit_json
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'EXIT_RULES';
    SELECT binding.config_version_id, config.config_json INTO STRICT fee_id, fee_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'FEE_MODEL' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'FEE_MODEL';
    SELECT binding.config_version_id, config.config_json
    INTO STRICT slippage_id, slippage_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'SLIPPAGE_MODEL' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'SLIPPAGE_MODEL';
    SELECT binding.config_version_id, config.config_json
    INTO STRICT portfolio_id, portfolio_json
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'PORTFOLIO_RULES' AND config.status = 'READY'
    WHERE binding.experiment_id = experiment_record.experiment_id
      AND binding.config_type = 'PORTFOLIO_RULES';
    IF exit_json IS NULL OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_exit_episode_inputs episode
        WHERE episode.model_b_iteration_id = iteration_record.iteration_id
    ) OR EXISTS (
        SELECT 1 FROM strategy_training.training_exit_episode_inputs episode
        JOIN strategy_training.training_model_b_sample_map sample
          ON sample.model_b_sample_id = episode.model_b_sample_id
        WHERE episode.model_b_iteration_id = iteration_record.iteration_id
          AND (episode.status <> 'DECIDED'
            OR episode.exit_rule_version_id <> exit_id
            OR episode.fee_model_version_id <> fee_id
            OR episode.slippage_model_version_id <> slippage_id
            OR NOT (
                (sample.sample_use = 'MODEL_B_PROTOTYPE'
                 AND sample.natural_source = 'FIXED_BASELINE_MODEL_A')
             OR (sample.sample_use = 'GO_NO_GO'
                 AND sample.natural_source = 'CROSS_FIT_MODEL_A_CANDIDATE')
             OR (sample.sample_use = 'MODEL_B_TRAIN'
                 AND sample.natural_source = 'CROSS_FIT_MODEL_A')
             OR (sample.sample_use = 'MODEL_B_TRAIN_CONTROL'
                 AND sample.natural_source = 'ADVERSE_OR_RANGE_CONTROL')
            ))
    ) THEN
        RAISE EXCEPTION 'portfolio evaluation requires complete governed model-B episodes'
            USING ERRCODE = '23514';
    END IF;
    RETURN QUERY SELECT iteration_record.iteration_id, exit_id, exit_json,
        fee_id, fee_json, slippage_id, slippage_json, portfolio_id, portfolio_json;
END
$$;

ALTER TABLE strategy_training.training_model_b_compiled_candidate_policies
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_b_candidate_preparation_context(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_model_b_compiled_candidate_policy(
    uuid, uuid, jsonb, numeric
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_model_b_candidate_exit_episode(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_model_b_candidate_preparation(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_effective_model_b_exit_config(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_portfolio_evaluation_context(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_model_b_compiled_candidate_policies FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.training_model_b_candidate_preparation_context(uuid, uuid),
    strategy_training.record_training_model_b_compiled_candidate_policy(
        uuid, uuid, jsonb, numeric
    ),
    strategy_training.create_training_model_b_candidate_exit_episode(
        uuid, uuid, char(64)
    ),
    strategy_training.finalize_training_model_b_candidate_preparation(uuid, uuid),
    strategy_training.training_effective_model_b_exit_config(uuid, uuid),
    strategy_training.training_model_b_replay_context(uuid, uuid, char(64)),
    strategy_training.training_portfolio_evaluation_context(uuid, uuid)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_b_candidate_preparation_context(uuid, uuid),
    strategy_training.record_training_model_b_compiled_candidate_policy(
        uuid, uuid, jsonb, numeric
    ),
    strategy_training.create_training_model_b_candidate_exit_episode(
        uuid, uuid, char(64)
    ),
    strategy_training.finalize_training_model_b_candidate_preparation(uuid, uuid)
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_effective_model_b_exit_config(uuid, uuid)
TO tb2_training_model_b, tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) TO tb2_training_model_b;
GRANT EXECUTE ON FUNCTION strategy_training.training_portfolio_evaluation_context(
    uuid, uuid
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '087_training_model_b_candidate_runtime',
    encode(digest('auto_trade_v2_087_training_model_b_candidate_runtime_v1', 'sha256'), 'hex'),
    'Compile immutable Model-B candidate policies and prepare governed replay episodes'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
