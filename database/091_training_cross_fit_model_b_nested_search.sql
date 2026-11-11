\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE FUNCTION strategy_training.create_cross_fit_model_b_nested_fold_pair(
    p_cross_fit_execution_id uuid, p_outer_fold_number integer
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE gate_record strategy_training.training_cross_fit_model_b_gate_runs%ROWTYPE;
        eligibility_record strategy_training.training_cross_fit_model_b_fold_eligibility%ROWTYPE;
        fold_record strategy_training.training_cross_fit_folds%ROWTYPE;
        search_space_id uuid; trial_budget integer; base_seed bigint;
        tpe_id uuid; random_id uuid; prior_eligible_fold integer;
BEGIN
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_fold_runs fold_run
        WHERE fold_run.cross_fit_execution_id = p_cross_fit_execution_id
          AND fold_run.outer_fold_number = p_outer_fold_number
    ) THEN RETURN 'PAIR_EXISTS'; END IF;
    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_cross_fit_model_b_gate_runs
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND state = 'RUNNING' FOR UPDATE;
    SELECT * INTO STRICT eligibility_record
    FROM strategy_training.training_cross_fit_model_b_fold_eligibility
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND outer_fold_number = p_outer_fold_number
      AND eligibility = 'ELIGIBLE';
    SELECT max(outer_fold_number) INTO prior_eligible_fold
    FROM strategy_training.training_cross_fit_model_b_fold_eligibility
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND eligibility = 'ELIGIBLE' AND outer_fold_number < p_outer_fold_number;
    IF prior_eligible_fold IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_model_b_fold_runs prior
        WHERE prior.cross_fit_execution_id = p_cross_fit_execution_id
          AND prior.outer_fold_number = prior_eligible_fold
          AND prior.state = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'prior eligible Model-B fold is not complete'
            USING ERRCODE = '55000';
    END IF;
    SELECT fold.* INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_folds fold
    JOIN strategy_training.training_cross_fit_fold_executions fold_execution
      ON fold_execution.cross_fit_fold_id = fold.cross_fit_fold_id
     AND fold_execution.cross_fit_execution_id = p_cross_fit_execution_id
    WHERE fold.outer_fold_number = p_outer_fold_number
      AND fold.status = 'SUCCEEDED';
    SELECT binding.config_version_id INTO STRICT search_space_id
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'MODEL_B_SEARCH_SPACE' AND config.status = 'READY'
    WHERE binding.experiment_id = gate_record.temporary_experiment_id
      AND binding.config_type = 'MODEL_B_SEARCH_SPACE';
    SELECT (config.config_json #>> '{q030_cross_fit,tpe_trials_per_fold}')::integer,
           (config.config_json #>> '{q030_cross_fit,random_seed}')::bigint
    INTO STRICT trial_budget, base_seed
    FROM strategy_training.training_cross_fit_executions execution
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = execution.protocol_config_version_id
    WHERE execution.cross_fit_execution_id = p_cross_fit_execution_id;
    tpe_id := strategy_training.create_training_optimizer_run(
        gate_record.temporary_experiment_id, 'TPE', search_space_id,
        trial_budget, base_seed + p_outer_fold_number,
        format('cross-fit-model-b:%s:fold:%s:TPE',
               p_cross_fit_execution_id, p_outer_fold_number));
    random_id := strategy_training.create_training_optimizer_run(
        gate_record.temporary_experiment_id, 'RANDOM', search_space_id,
        trial_budget, base_seed + p_outer_fold_number,
        format('cross-fit-model-b:%s:fold:%s:RANDOM',
               p_cross_fit_execution_id, p_outer_fold_number));
    INSERT INTO strategy_training.training_cross_fit_model_b_fold_runs (
        cross_fit_execution_id, outer_fold_number, cross_fit_fold_id,
        tpe_optimizer_run_id, random_optimizer_run_id, training_end_at,
        prediction_start_at, prediction_end_at, state
    ) VALUES (p_cross_fit_execution_id, p_outer_fold_number,
        fold_record.cross_fit_fold_id, tpe_id, random_id,
        eligibility_record.training_end_at,
        eligibility_record.prediction_start_at,
        eligibility_record.prediction_end_at, 'SEARCHING');
    INSERT INTO strategy_training.training_cross_fit_model_b_fold_events (
        cross_fit_execution_id, outer_fold_number, entry_event_id,
        event_role, boundary_hash
    )
    SELECT p_cross_fit_execution_id, p_outer_fold_number, member.entry_event_id,
           CASE WHEN entry.signal_time < eligibility_record.training_end_at
                THEN 'TRAIN_PRIOR' ELSE 'FOLD_OUT' END,
           encode(digest(concat_ws('|', p_cross_fit_execution_id,
               p_outer_fold_number, member.entry_event_id,
               CASE WHEN entry.signal_time < eligibility_record.training_end_at
                    THEN 'TRAIN_PRIOR' ELSE 'FOLD_OUT' END,
               eligibility_record.eligibility_hash), 'sha256'), 'hex')
    FROM strategy_training.training_cross_fit_corpus_events member
    JOIN strategy_training.training_entry_events entry USING (entry_event_id)
    WHERE member.cross_fit_corpus_id = gate_record.candidate_corpus_id
      AND (entry.signal_time < eligibility_record.training_end_at
        OR (entry.signal_time >= eligibility_record.prediction_start_at
            AND entry.signal_time < eligibility_record.prediction_end_at));
    IF (SELECT count(*) FROM strategy_training.training_cross_fit_model_b_fold_events
        WHERE cross_fit_execution_id = p_cross_fit_execution_id
          AND outer_fold_number = p_outer_fold_number AND event_role = 'TRAIN_PRIOR')
       <> eligibility_record.prior_training_event_count
       OR (SELECT count(*) FROM strategy_training.training_cross_fit_model_b_fold_events
        WHERE cross_fit_execution_id = p_cross_fit_execution_id
          AND outer_fold_number = p_outer_fold_number AND event_role = 'FOLD_OUT')
       <> eligibility_record.fold_out_event_count THEN
        RAISE EXCEPTION 'nested fold events differ from frozen eligibility snapshot'
            USING ERRCODE = '23514';
    END IF;
    PERFORM strategy_training.transition_training_optimizer_run(tpe_id,
        'CREATED','RUNNING',NULL,NULL,'training-model-b-orchestrator',
        'start nested outer-fold TPE search',gen_random_uuid());
    PERFORM strategy_training.transition_training_optimizer_run(random_id,
        'CREATED','RUNNING',NULL,NULL,'training-model-b-orchestrator',
        'start nested outer-fold RANDOM control',gen_random_uuid());
    RETURN 'PAIR_CREATED';
END
$$;

CREATE FUNCTION strategy_training.initialize_cross_fit_model_b_nested_search(
    p_cross_fit_execution_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        parent_record strategy_training.training_experiments%ROWTYPE;
        protocol_json jsonb; temporary_id uuid; search_space_id uuid;
        trial_budget integer; base_seed bigint; first_fold integer;
        tpe_id uuid; random_id uuid; stress_multiplier numeric;
BEGIN
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM strategy_training.training_cross_fit_model_b_gate_runs
               WHERE cross_fit_execution_id = p_cross_fit_execution_id) THEN
        RETURN 'NESTED_SEARCH_EXISTS';
    END IF;
    IF NOT EXISTS (SELECT 1
        FROM strategy_training.training_cross_fit_model_b_fold_eligibility
        WHERE cross_fit_execution_id = p_cross_fit_execution_id) THEN
        IF strategy_training.freeze_cross_fit_model_b_fold_eligibility(
            p_cross_fit_execution_id) = 'INSUFFICIENT_POWER' THEN
            RETURN 'INSUFFICIENT_POWER';
        END IF;
    END IF;
    SELECT min(outer_fold_number) INTO STRICT first_fold
    FROM strategy_training.training_cross_fit_model_b_fold_eligibility
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND eligibility = 'ELIGIBLE';
    SELECT * INTO STRICT parent_record FROM strategy_training.training_experiments
    WHERE experiment_id = execution_record.experiment_id;
    SELECT config_json INTO STRICT protocol_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id;
    SELECT binding.config_version_id INTO STRICT search_space_id
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'MODEL_B_SEARCH_SPACE' AND config.status = 'READY'
    WHERE binding.experiment_id = parent_record.experiment_id
      AND binding.config_type = 'MODEL_B_SEARCH_SPACE';
    temporary_id := strategy_training.create_training_experiment(
        'EXIT_POLICY', parent_record.experiment_id,
        execution_record.dataset_version_id,
        parent_record.resource_limit_config_version_id,
        format('Q036 temporary Model-B nested %s', p_cross_fit_execution_id),
        encode(digest(concat_ws('|', parent_record.exposure_identity_hash,
            p_cross_fit_execution_id, 'Q036_MODEL_B_TEMPORARY'), 'sha256'), 'hex'),
        parent_record.created_by_user_id);
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id)
    SELECT temporary_id, binding.config_type, binding.config_version_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = parent_record.experiment_id;
    PERFORM strategy_training.transition_training_experiment(temporary_id,
        'DRAFT','RUNNING',NULL,'training-model-b-orchestrator',
        'start non-promotable Q-036 nested search',gen_random_uuid());
    trial_budget := (protocol_json #>> '{q030_cross_fit,tpe_trials_per_fold}')::integer;
    base_seed := (protocol_json #>> '{q030_cross_fit,random_seed}')::bigint;
    stress_multiplier := (protocol_json #>>
        '{q036_go_no_go,model_b,required_stress_multiplier}')::numeric;
    tpe_id := strategy_training.create_training_optimizer_run(temporary_id,
        'TPE',search_space_id,trial_budget,base_seed+first_fold,
        format('cross-fit-model-b:%s:fold:%s:TPE',
               p_cross_fit_execution_id,first_fold));
    random_id := strategy_training.create_training_optimizer_run(temporary_id,
        'RANDOM',search_space_id,trial_budget,base_seed+first_fold,
        format('cross-fit-model-b:%s:fold:%s:RANDOM',
               p_cross_fit_execution_id,first_fold));
    PERFORM strategy_training.create_cross_fit_model_b_gate_run(
        p_cross_fit_execution_id, temporary_id, tpe_id, random_id,
        stress_multiplier);
    -- The header pair is the first eligible fold pair.  Insert it through the
    -- same frozen eligibility path instead of creating a second pair.
    INSERT INTO strategy_training.training_cross_fit_model_b_fold_runs (
        cross_fit_execution_id, outer_fold_number, cross_fit_fold_id,
        tpe_optimizer_run_id, random_optimizer_run_id, training_end_at,
        prediction_start_at, prediction_end_at, state)
    SELECT p_cross_fit_execution_id, eligibility.outer_fold_number,
        fold.cross_fit_fold_id, tpe_id, random_id, eligibility.training_end_at,
        eligibility.prediction_start_at, eligibility.prediction_end_at, 'SEARCHING'
    FROM strategy_training.training_cross_fit_model_b_fold_eligibility eligibility
    JOIN strategy_training.training_cross_fit_folds fold
      ON fold.experiment_id = execution_record.experiment_id
     AND fold.outer_fold_number = eligibility.outer_fold_number
    WHERE eligibility.cross_fit_execution_id = p_cross_fit_execution_id
      AND eligibility.outer_fold_number = first_fold;
    INSERT INTO strategy_training.training_cross_fit_model_b_fold_events (
        cross_fit_execution_id, outer_fold_number, entry_event_id,
        event_role, boundary_hash)
    SELECT p_cross_fit_execution_id, first_fold, member.entry_event_id,
        CASE WHEN entry.signal_time < eligibility.training_end_at
             THEN 'TRAIN_PRIOR' ELSE 'FOLD_OUT' END,
        encode(digest(concat_ws('|',p_cross_fit_execution_id,first_fold,
            member.entry_event_id,eligibility.eligibility_hash),'sha256'),'hex')
    FROM strategy_training.training_cross_fit_model_b_gate_runs gate_run
    JOIN strategy_training.training_cross_fit_corpus_events member
      ON member.cross_fit_corpus_id = gate_run.candidate_corpus_id
    JOIN strategy_training.training_entry_events entry USING (entry_event_id)
    JOIN strategy_training.training_cross_fit_model_b_fold_eligibility eligibility
      ON eligibility.cross_fit_execution_id = p_cross_fit_execution_id
     AND eligibility.outer_fold_number = first_fold
    WHERE gate_run.cross_fit_execution_id = p_cross_fit_execution_id
      AND (entry.signal_time < eligibility.training_end_at
        OR (entry.signal_time >= eligibility.prediction_start_at
            AND entry.signal_time < eligibility.prediction_end_at));
    PERFORM strategy_training.transition_training_optimizer_run(tpe_id,
        'CREATED','RUNNING',NULL,NULL,'training-model-b-orchestrator',
        'start first eligible nested TPE search',gen_random_uuid());
    PERFORM strategy_training.transition_training_optimizer_run(random_id,
        'CREATED','RUNNING',NULL,NULL,'training-model-b-orchestrator',
        'start first eligible nested RANDOM control',gen_random_uuid());
    RETURN 'NESTED_SEARCH_INITIALIZED';
END
$$;

ALTER FUNCTION strategy_training.create_cross_fit_model_b_nested_fold_pair(uuid,integer)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.initialize_cross_fit_model_b_nested_search(uuid)
OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION
    strategy_training.create_cross_fit_model_b_nested_fold_pair(uuid,integer),
    strategy_training.initialize_cross_fit_model_b_nested_search(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.create_cross_fit_model_b_nested_fold_pair(uuid,integer),
    strategy_training.initialize_cross_fit_model_b_nested_search(uuid)
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES ('091_training_cross_fit_model_b_nested_search',
    encode(digest('auto_trade_v2_091_training_cross_fit_model_b_nested_search_v1',
                  'sha256'),'hex'),
    'Automatically create temporary Model-B experiments and per-eligible-fold optimizer pairs')
ON CONFLICT (version) DO NOTHING;

COMMIT;
