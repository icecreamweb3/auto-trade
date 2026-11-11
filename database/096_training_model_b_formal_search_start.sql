\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_model_b_formal_search_runs
ADD CONSTRAINT training_model_b_formal_search_runs_gate_key
UNIQUE (go_no_go_evaluation_id);

CREATE FUNCTION strategy_training.initialize_training_model_b_formal_search(
    p_go_no_go_evaluation_id uuid
)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE gate_record strategy_training.training_go_no_go_evaluations%ROWTYPE;
        execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
        parent_record strategy_training.training_experiments%ROWTYPE;
        baseline_record strategy_training.training_model_b_round_zero_baseline_runs%ROWTYPE;
        corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
        protocol_record strategy_training.training_config_versions%ROWTYPE;
        formal_experiment_id uuid; qualification_id uuid;
        search_space_id uuid; tpe_id uuid; random_id uuid; formal_run_id uuid;
        trial_budget integer; base_seed bigint; question text;
        coverage_hash char(64); source_hash char(64); input_count bigint;
BEGIN
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_model_b_formal_search_runs formal
        WHERE formal.go_no_go_evaluation_id = p_go_no_go_evaluation_id
    ) THEN RETURN 'FORMAL_SEARCH_EXISTS'; END IF;

    SELECT * INTO STRICT gate_record
    FROM strategy_training.training_go_no_go_evaluations
    WHERE go_no_go_evaluation_id = p_go_no_go_evaluation_id FOR SHARE;
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE experiment_id = gate_record.experiment_id
      AND state = 'FORMAL_CORPUS_READY' FOR UPDATE;
    SELECT * INTO STRICT parent_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = execution_record.experiment_id FOR SHARE;
    SELECT * INTO STRICT baseline_record
    FROM strategy_training.training_model_b_round_zero_baseline_runs
    WHERE go_no_go_evaluation_id = p_go_no_go_evaluation_id
      AND cross_fit_execution_id = execution_record.cross_fit_execution_id
      AND state = 'SUCCEEDED' FOR SHARE;
    SELECT * INTO STRICT corpus_record
    FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_execution_id = execution_record.cross_fit_execution_id
      AND source = 'CROSS_FIT_MODEL_A' AND corpus_use = 'MODEL_B_TRAIN'
      AND source_corpus_id IS NOT NULL;
    SELECT * INTO STRICT protocol_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id
      AND config_type = 'CROSS_FIT_PROTOCOL' AND status = 'READY';

    IF gate_record.decision <> 'PASS' OR NOT gate_record.temporary_only
       OR baseline_record.evidence_hash IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_iterations iteration
           JOIN strategy_training.training_experiments experiment
             ON experiment.experiment_id = iteration.experiment_id
           JOIN strategy_training.training_tasks portfolio_task
             ON portfolio_task.iteration_id = iteration.iteration_id
            AND portfolio_task.task_type = 'PORTFOLIO_EVALUATION'
            AND portfolio_task.state = 'SUCCEEDED'
           WHERE iteration.iteration_id = baseline_record.iteration_id
             AND iteration.state = 'SUCCEEDED'
             AND experiment.experiment_id = baseline_record.experiment_id
             AND experiment.state = 'STOPPED'
       )
       OR NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_go_no_go_round_zero_baselines evidence
           WHERE evidence.go_no_go_evaluation_id = p_go_no_go_evaluation_id
             AND evidence.evidence_hash = baseline_record.evidence_hash
             AND evidence.baseline_definition_hash =
                 baseline_record.baseline_definition_hash
       )
       OR corpus_record.event_count < execution_record.minimum_event_count
       OR corpus_record.effective_fold_count < execution_record.minimum_effective_folds
       OR corpus_record.effective_day_count < execution_record.minimum_effective_days
       OR NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_experiment_config_bindings binding
           WHERE binding.experiment_id = parent_record.experiment_id
             AND binding.config_type = 'CROSS_FIT_PROTOCOL'
             AND binding.config_version_id = protocol_record.config_version_id
       ) THEN
        RAISE EXCEPTION 'formal Model-B start requires PASS, promoted power and completed immutable baseline'
            USING ERRCODE = '23514';
    END IF;

    FOREACH question IN ARRAY ARRAY['Q-019','Q-029','Q-030','Q-036','Q-039'] LOOP
        IF execution_record.question_readiness ->> question IS DISTINCT FROM 'READY'
           OR protocol_record.config_json #>> ARRAY['question_readiness', question]
                IS DISTINCT FROM 'READY' THEN
            RAISE EXCEPTION 'formal Model-B decision % is not READY', question
                USING ERRCODE = '23514';
        END IF;
    END LOOP;

    trial_budget := (protocol_record.config_json #>>
                     '{q019_search_budget,maximum_iterations}')::integer;
    base_seed := (protocol_record.config_json #>>
                 '{q030_cross_fit,random_seed}')::bigint;
    IF trial_budget <= 0 OR base_seed IS NULL THEN
        RAISE EXCEPTION 'formal Model-B Q-019 budget and seed are invalid'
            USING ERRCODE = '23514';
    END IF;
    SELECT binding.config_version_id INTO STRICT search_space_id
    FROM strategy_training.training_experiment_config_bindings binding
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'MODEL_B_SEARCH_SPACE' AND config.status = 'READY'
    WHERE binding.experiment_id = parent_record.experiment_id
      AND binding.config_type = 'MODEL_B_SEARCH_SPACE';

    source_hash := execution_record.source_revision_watermark_hash;
    coverage_hash := encode(digest(jsonb_build_object(
        'corpus_hash', corpus_record.corpus_hash,
        'effective_day_count', corpus_record.effective_day_count,
        'effective_fold_count', corpus_record.effective_fold_count,
        'event_count', corpus_record.event_count,
        'protocol_content_hash', protocol_record.content_hash,
        'source_revision_watermark_hash', source_hash
    )::text, 'sha256'), 'hex');

    formal_experiment_id := strategy_training.create_training_experiment(
        'EXIT_POLICY', parent_record.experiment_id,
        execution_record.dataset_version_id,
        parent_record.resource_limit_config_version_id,
        format('Formal Model-B search %s', p_go_no_go_evaluation_id),
        encode(digest(concat_ws('|', parent_record.exposure_identity_hash,
            p_go_no_go_evaluation_id, corpus_record.corpus_hash,
            protocol_record.content_hash, 'FORMAL_MODEL_B'), 'sha256'), 'hex'),
        parent_record.created_by_user_id
    );
    INSERT INTO strategy_training.training_experiment_config_bindings (
        experiment_id, config_type, config_version_id
    )
    SELECT formal_experiment_id, binding.config_type, binding.config_version_id
    FROM strategy_training.training_experiment_config_bindings binding
    WHERE binding.experiment_id = parent_record.experiment_id;
    PERFORM strategy_training.transition_training_experiment(
        formal_experiment_id, 'DRAFT', 'RUNNING', NULL,
        'training-model-b-orchestrator',
        'start fresh formal Model-B paired search', gen_random_uuid()
    );

    INSERT INTO strategy_training.training_model_b_decision_readiness (
        experiment_id, decision_code, config_version_id
    )
    SELECT formal_experiment_id, decision_code, protocol_record.config_version_id
    FROM unnest(ARRAY['Q-019','Q-029','Q-030','Q-036','Q-039']) decision_code;

    qualification_id := gen_random_uuid();
    INSERT INTO strategy_training.training_model_b_search_qualifications (
        qualification_id, experiment_id, dataset_version_id, coverage_state,
        backfill_accepted, coverage_report_hash, source_revision_hash,
        qualified_entry_count, qualification_report
    ) VALUES (
        qualification_id, formal_experiment_id, execution_record.dataset_version_id,
        'PASS', true, coverage_hash, source_hash, corpus_record.event_count,
        jsonb_build_object(
            'cross_fit_execution_id', execution_record.cross_fit_execution_id,
            'formal_corpus_id', corpus_record.cross_fit_corpus_id,
            'formal_corpus_hash', corpus_record.corpus_hash,
            'effective_fold_count', corpus_record.effective_fold_count,
            'effective_day_count', corpus_record.effective_day_count,
            'qualified_entry_count', corpus_record.event_count,
            'outcome_fields_used', false,
            'qualification_basis', 'PROMOTED_CROSS_FIT_CORPUS'
        )
    );

    tpe_id := strategy_training.create_training_optimizer_run(
        formal_experiment_id, 'TPE', search_space_id, trial_budget, base_seed,
        format('formal-model-b:%s:TPE', p_go_no_go_evaluation_id)
    );
    random_id := strategy_training.create_training_optimizer_run(
        formal_experiment_id, 'RANDOM', search_space_id, trial_budget,
        base_seed + 1, format('formal-model-b:%s:RANDOM', p_go_no_go_evaluation_id)
    );
    formal_run_id := strategy_training.create_model_b_formal_search_run(
        formal_experiment_id, p_go_no_go_evaluation_id, qualification_id,
        tpe_id, random_id
    );

    INSERT INTO strategy_training.training_model_b_formal_search_inputs (
        formal_search_run_id, entry_event_id, input_kind, inclusion_probability
    )
    SELECT formal_run_id, promoted.entry_event_id, 'NATURAL_ENTRY', NULL
    FROM strategy_training.formal_model_b_cross_fit_entries promoted
    WHERE promoted.cross_fit_execution_id = execution_record.cross_fit_execution_id
      AND promoted.cross_fit_corpus_id = corpus_record.cross_fit_corpus_id
      AND promoted.underlying_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
      AND promoted.underlying_use = 'GO_NO_GO'
      AND promoted.promoted_source = 'CROSS_FIT_MODEL_A'
      AND promoted.promoted_use = 'MODEL_B_TRAIN';
    GET DIAGNOSTICS input_count = ROW_COUNT;
    IF input_count <> corpus_record.event_count THEN
        RAISE EXCEPTION 'formal Model-B inputs differ from the promoted corpus'
            USING ERRCODE = '23514';
    END IF;

    PERFORM strategy_training.transition_training_optimizer_run(
        tpe_id, 'CREATED', 'RUNNING', NULL, NULL,
        'training-model-b-orchestrator',
        'start fresh formal Model-B TPE search', gen_random_uuid()
    );
    PERFORM strategy_training.transition_training_optimizer_run(
        random_id, 'CREATED', 'RUNNING', NULL, NULL,
        'training-model-b-orchestrator',
        'start fresh formal Model-B RANDOM comparator', gen_random_uuid()
    );
    RETURN 'FORMAL_SEARCH_INITIALIZED';
END
$$;

CREATE FUNCTION strategy_training.advance_training_model_b_formal_searches()
RETURNS TABLE (go_no_go_evaluation_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE candidate record;
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
END
$$;

ALTER FUNCTION strategy_training.initialize_training_model_b_formal_search(uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_b_formal_searches()
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.initialize_training_model_b_formal_search(uuid),
    strategy_training.advance_training_model_b_formal_searches()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.initialize_training_model_b_formal_search(uuid),
    strategy_training.advance_training_model_b_formal_searches()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '096_training_model_b_formal_search_start',
    encode(digest('auto_trade_v2_096_training_model_b_formal_search_start_v1',
                  'sha256'), 'hex'),
    'Start fresh formal Model-B TPE and RANDOM search after promoted corpus and real baseline'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
