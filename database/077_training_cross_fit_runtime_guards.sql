\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- A Cross-fit optimizer must be bound to its outer-fold TRAIN interval before it
-- can create any candidate-scan task.  The final fold fact in migration 054 is
-- deliberately written only after the search succeeds, so this planning fact is
-- separate from training_cross_fit_fold_executions.
CREATE TABLE strategy_training.training_cross_fit_optimizer_scopes (
    cross_fit_execution_id uuid NOT NULL
        REFERENCES strategy_training.training_cross_fit_executions,
    outer_fold_number integer NOT NULL CHECK (outer_fold_number > 0),
    optimizer_run_id uuid PRIMARY KEY
        REFERENCES strategy_training.training_optimizer_runs,
    optimizer_role varchar(8) NOT NULL CHECK (optimizer_role IN ('TPE', 'RANDOM')),
    effective_train_start_at timestamptz NOT NULL,
    effective_train_end_at timestamptz NOT NULL,
    prediction_start_at timestamptz NOT NULL,
    prediction_end_at timestamptz NOT NULL,
    trial_budget integer NOT NULL CHECK (trial_budget > 0),
    wall_clock_budget_seconds integer NOT NULL CHECK (wall_clock_budget_seconds > 0),
    repeat_count integer NOT NULL CHECK (repeat_count > 0),
    random_seed bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (effective_train_start_at < effective_train_end_at),
    CHECK (effective_train_end_at < prediction_start_at),
    CHECK (prediction_start_at < prediction_end_at),
    UNIQUE (cross_fit_execution_id, outer_fold_number, optimizer_role)
);

CREATE OR REPLACE FUNCTION strategy_training.register_cross_fit_optimizer_scope(
    p_cross_fit_execution_id uuid, p_lease_token uuid,
    p_outer_fold_number integer, p_optimizer_run_id uuid,
    p_optimizer_role text, p_effective_train_start_at timestamptz,
    p_effective_train_end_at timestamptz, p_prediction_start_at timestamptz,
    p_prediction_end_at timestamptz
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE
    execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
    optimizer_record strategy_training.training_optimizer_runs%ROWTYPE;
    protocol_json jsonb;
    expected_budget integer;
    expected_wall_clock integer;
    expected_repeat integer;
    expected_seed bigint;
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    SELECT config_json INTO STRICT protocol_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id
      AND status = 'READY' AND config_type = 'CROSS_FIT_PROTOCOL';
    SELECT * INTO STRICT optimizer_record
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_optimizer_run_id FOR SHARE;

    expected_budget := CASE p_optimizer_role
        WHEN 'TPE' THEN (protocol_json #>> '{q030_cross_fit,tpe_trials_per_fold}')::integer
        WHEN 'RANDOM' THEN (protocol_json #>> '{q030_cross_fit,random_trials_per_fold}')::integer
        ELSE NULL
    END;
    expected_wall_clock := (
        protocol_json #>> '{q030_cross_fit,maximum_wall_clock_seconds_per_optimizer_per_fold}'
    )::integer;
    expected_repeat := (
        protocol_json #>> '{q030_cross_fit,repeat_count_per_fold}'
    )::integer;
    expected_seed := (protocol_json #>> '{q030_cross_fit,random_seed}')::bigint
        + p_outer_fold_number - 1;

    IF execution_record.state <> 'RUNNING'
       OR p_outer_fold_number <= 0
       OR optimizer_record.experiment_id <> execution_record.experiment_id
       OR optimizer_record.state <> 'CREATED'
       OR optimizer_record.optimizer_kind <> p_optimizer_role
       OR optimizer_record.trial_budget <> expected_budget
       OR optimizer_record.random_seed <> expected_seed
       OR expected_wall_clock IS NULL OR expected_wall_clock <= 0
       OR expected_repeat IS NULL OR expected_repeat <= 0
       OR p_effective_train_start_at >= p_effective_train_end_at
       OR p_effective_train_end_at - p_effective_train_start_at
            < make_interval(days => (
                    protocol_json #>> '{q030_cross_fit,minimum_training_window_effective_days}'
                )::integer)
       OR p_effective_train_end_at >= p_prediction_start_at
       OR p_prediction_start_at >= p_prediction_end_at
       OR p_prediction_end_at > (
            SELECT eligible_end_at
            FROM strategy_training.training_dataset_versions
            WHERE dataset_version_id = execution_record.dataset_version_id
       )
       OR p_effective_train_start_at < (
            SELECT eligible_start_at
            FROM strategy_training.training_dataset_versions
            WHERE dataset_version_id = execution_record.dataset_version_id
       )
       OR p_effective_train_end_at
            > p_prediction_start_at
              - make_interval(hours => (
                    protocol_json #>> '{q030_cross_fit,label_settlement_embargo_hours}'
                )::integer)
       OR p_prediction_end_at - p_prediction_start_at
            <> make_interval(days => (
                    protocol_json #>> '{q030_cross_fit,prediction_signal_window_days}'
                )::integer) THEN
        RAISE EXCEPTION 'optimizer scope violates its READY Cross-fit protocol'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO strategy_training.training_cross_fit_optimizer_scopes (
        cross_fit_execution_id, outer_fold_number, optimizer_run_id,
        optimizer_role, effective_train_start_at, effective_train_end_at,
        prediction_start_at, prediction_end_at, trial_budget,
        wall_clock_budget_seconds, repeat_count, random_seed
    ) VALUES (
        p_cross_fit_execution_id, p_outer_fold_number, p_optimizer_run_id,
        p_optimizer_role, p_effective_train_start_at, p_effective_train_end_at,
        p_prediction_start_at, p_prediction_end_at, expected_budget,
        expected_wall_clock, expected_repeat, expected_seed
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_cross_fit_fold_runtime_scope()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE
    scope_record strategy_training.training_cross_fit_optimizer_scopes%ROWTYPE;
    fold_record strategy_training.training_cross_fit_folds%ROWTYPE;
    protocol_json jsonb;
BEGIN
    SELECT * INTO STRICT scope_record
    FROM strategy_training.training_cross_fit_optimizer_scopes
    WHERE optimizer_run_id = NEW.optimizer_run_id;
    SELECT * INTO STRICT fold_record
    FROM strategy_training.training_cross_fit_folds
    WHERE cross_fit_fold_id = NEW.cross_fit_fold_id;
    SELECT config.config_json INTO STRICT protocol_json
    FROM strategy_training.training_cross_fit_executions execution
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = execution.protocol_config_version_id
    WHERE execution.cross_fit_execution_id = NEW.cross_fit_execution_id
      AND config.status = 'READY' AND config.config_type = 'CROSS_FIT_PROTOCOL';

    IF scope_record.cross_fit_execution_id <> NEW.cross_fit_execution_id
       OR scope_record.outer_fold_number <> fold_record.outer_fold_number
       OR scope_record.optimizer_role <> 'TPE'
       OR fold_record.effective_train_start_at <> scope_record.effective_train_start_at
       OR fold_record.effective_train_end_at <> scope_record.effective_train_end_at
       OR fold_record.prediction_start_at <> scope_record.prediction_start_at
       OR fold_record.prediction_end_at <> scope_record.prediction_end_at
       OR NEW.effective_training_sample_count < (
            protocol_json #>> '{q030_cross_fit,minimum_fitting_samples_per_fold}'
          )::bigint
       OR NEW.trial_budget <> scope_record.trial_budget
       OR NEW.wall_clock_budget_seconds <> scope_record.wall_clock_budget_seconds
       OR NEW.repeat_count <> scope_record.repeat_count
       OR NEW.random_seed <> scope_record.random_seed THEN
        RAISE EXCEPTION 'completed fold does not match its frozen optimizer scope'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_cross_fit_fold_runtime_scope
BEFORE INSERT OR UPDATE ON strategy_training.training_cross_fit_fold_executions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_cross_fit_fold_runtime_scope();

-- Override the v1 scan context so a Cross-fit optimizer sees only its frozen
-- effective TRAIN interval.  An active Cross-fit experiment fails closed when
-- an optimizer has not been scoped first.
CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    iteration_id uuid, dataset_version_id uuid, interval_seconds integer,
    eligible_start_at timestamptz, eligible_end_at timestamptz,
    ticker_pool_rule_version_id uuid, factor_registry_version_id uuid,
    factor_registry_config jsonb, scan_parameters_version_id uuid,
    scan_parameters_config jsonb, candidate_parameters jsonb,
    dataset_root_fingerprint char(64), maximum_signal_count bigint,
    existing_batch_hash char(64)
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS NULL THEN
        RAISE EXCEPTION 'candidate scan requires its active worker lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN QUERY
    SELECT iteration.iteration_id, dataset.dataset_version_id,
           dataset.interval_seconds,
           COALESCE(scope.effective_train_start_at, dataset.eligible_start_at),
           COALESCE(scope.effective_train_end_at, dataset.eligible_end_at),
           dataset.ticker_pool_rule_version_id,
           factor.config_version_id, factor.config_json,
           scan.config_version_id, scan.config_json,
           iteration.candidate_parameters, dataset.root_fingerprint,
           (limits.config_json ->> 'max_signal_count')::bigint,
           batch.batch_hash
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = experiment.dataset_version_id
    JOIN strategy_training.training_experiment_config_bindings factor_binding
      ON factor_binding.experiment_id = experiment.experiment_id
     AND factor_binding.config_type = 'FACTOR_REGISTRY'
    JOIN strategy_training.training_config_versions factor
      ON factor.config_version_id = factor_binding.config_version_id
     AND factor.config_type = 'FACTOR_REGISTRY' AND factor.status = 'READY'
    JOIN strategy_training.training_experiment_config_bindings scan_binding
      ON scan_binding.experiment_id = experiment.experiment_id
     AND scan_binding.config_type = 'SEARCH_SPACE'
    JOIN strategy_training.training_config_versions scan
      ON scan.config_version_id = scan_binding.config_version_id
     AND scan.config_type = 'SEARCH_SPACE' AND scan.status = 'READY'
    JOIN strategy_training.training_config_versions limits
      ON limits.config_version_id = experiment.resource_limit_config_version_id
     AND limits.config_type = 'RESOURCE_LIMITS' AND limits.status = 'READY'
    LEFT JOIN strategy_training.training_iteration_entry_batches batch
      ON batch.iteration_id = iteration.iteration_id
    LEFT JOIN strategy_training.training_cross_fit_optimizer_scopes scope
      ON scope.optimizer_run_id = task_record.optimizer_run_id
    WHERE iteration.iteration_id = task_record.iteration_id
      AND iteration.state = 'RUNNING'
      AND iteration.candidate_source IN (
          'FIXED_BASELINE', 'OPTUNA_TPE', 'RANDOM_SEARCH'
      )
      AND dataset.status = 'READY' AND dataset.partition = 'TRAIN'
      AND dataset.interval_seconds = 300
      AND (
          iteration.candidate_source = 'FIXED_BASELINE'
          OR scope.optimizer_run_id IS NOT NULL
          OR NOT EXISTS (
              SELECT 1
              FROM strategy_training.training_cross_fit_executions execution
              WHERE execution.experiment_id = experiment.experiment_id
                AND execution.state IN ('RUNNING', 'CANDIDATE_READY', 'GO_NO_GO_PASSED')
          )
      );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'candidate scan context is not READY or Cross-fit scoped'
            USING ERRCODE = '23514';
    END IF;
END
$$;

-- Q-036 is an intersection-union gate.  Persist the frozen thresholds and both
-- model gates so neither the evaluator nor an API caller can manufacture PASS.
ALTER TABLE strategy_training.training_go_no_go_evaluations
    ADD COLUMN confidence_level numeric NOT NULL CHECK (
        confidence_level > 0 AND confidence_level < 1
    ),
    ADD COLUMN bootstrap_method text NOT NULL CHECK (btrim(bootstrap_method) <> ''),
    ADD COLUMN model_a_ci_lower_bound numeric NOT NULL,
    ADD COLUMN model_a_ci_upper_bound numeric NOT NULL,
    ADD COLUMN model_a_point_estimate_threshold numeric NOT NULL CHECK (
        model_a_point_estimate_threshold > 0
    ),
    ADD COLUMN model_a_ci_lower_bound_threshold numeric NOT NULL CHECK (
        model_a_ci_lower_bound_threshold > 0
    ),
    ADD COLUMN model_b_net_expectancy numeric NOT NULL,
    ADD COLUMN model_b_stressed_ci_lower_bound numeric NOT NULL,
    ADD COLUMN model_b_point_estimate_threshold numeric NOT NULL CHECK (
        model_b_point_estimate_threshold > 0
    ),
    ADD COLUMN model_b_stress_multiplier numeric NOT NULL CHECK (
        model_b_stress_multiplier >= 1
    ),
    ADD CONSTRAINT training_go_no_go_model_a_ci_order_check CHECK (
        model_a_ci_lower_bound <= model_a_ci_upper_bound
    ),
    ADD CONSTRAINT training_go_no_go_decision_evidence_check CHECK (
        decision <> 'PASS' OR (
            excess_mean >= model_a_point_estimate_threshold
            AND model_a_ci_lower_bound >= model_a_ci_lower_bound_threshold
            AND model_b_net_expectancy >= model_b_point_estimate_threshold
            AND model_b_stressed_ci_lower_bound > 0
        )
    );

DROP FUNCTION strategy_training.record_cross_fit_go_no_go(
    uuid, uuid, uuid, uuid, numeric, integer, integer, integer, bigint,
    numeric, numeric, numeric, numeric, integer, integer, text
);

CREATE FUNCTION strategy_training.record_cross_fit_go_no_go(
    p_cross_fit_execution_id uuid, p_lease_token uuid,
    p_tpe_optimizer_run_id uuid, p_random_optimizer_run_id uuid,
    p_tpe_mean numeric, p_random_mean numeric, p_excess_mean numeric,
    p_p_value numeric, p_model_a_ci_lower_bound numeric,
    p_model_a_ci_upper_bound numeric, p_model_b_net_expectancy numeric,
    p_model_b_stressed_ci_lower_bound numeric,
    p_model_b_stress_multiplier numeric, p_effective_day_count integer,
    p_effective_fold_count integer
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE protocol_json jsonb;
DECLARE new_id uuid := gen_random_uuid();
DECLARE gate_decision text;
DECLARE gate_alpha numeric;
DECLARE gate_bootstrap_replicates integer;
DECLARE gate_seed bigint;
DECLARE gate_confidence numeric;
DECLARE gate_bootstrap_method text;
DECLARE model_a_point_threshold numeric;
DECLARE model_a_ci_threshold numeric;
DECLARE model_b_point_threshold numeric;
DECLARE model_b_required_stress numeric;
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    SELECT config_json INTO STRICT protocol_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id
      AND status = 'READY' AND config_type = 'CROSS_FIT_PROTOCOL';

    gate_alpha := (protocol_json #>> '{q036_go_no_go,alpha_per_gate}')::numeric;
    gate_bootstrap_replicates := (
        protocol_json #>> '{q036_go_no_go,bootstrap_replicates}'
    )::integer;
    gate_seed := (protocol_json #>> '{q030_cross_fit,random_seed}')::bigint;
    gate_confidence := (protocol_json #>> '{q029_validation,confidence_level}')::numeric;
    gate_bootstrap_method := protocol_json #>> '{q036_go_no_go,bootstrap_method}';
    model_a_point_threshold := (
        protocol_json #>> '{q036_go_no_go,model_a,minimum_point_estimate_percentage_points}'
    )::numeric;
    model_a_ci_threshold := (
        protocol_json #>> '{q036_go_no_go,model_a,minimum_ci_lower_bound_percentage_points}'
    )::numeric;
    model_b_point_threshold := (
        protocol_json #>> '{q036_go_no_go,model_b,minimum_point_estimate_percentage_points}'
    )::numeric;
    model_b_required_stress := (
        protocol_json #>> '{q036_go_no_go,model_b,required_stress_multiplier}'
    )::numeric;

    IF execution_record.state <> 'CANDIDATE_READY'
       OR protocol_json #>> '{q036_go_no_go,model_a,final_thresholds_locked}' <> 'true'
       OR protocol_json #>> '{q036_go_no_go,gate_combination}'
            <> 'INTERSECTION_UNION_BOTH_MUST_PASS'
       OR p_model_a_ci_lower_bound > p_model_a_ci_upper_bound
       OR p_model_b_stress_multiplier <> model_b_required_stress
       OR execution_record.minimum_effective_days <> (
            protocol_json #>> '{q036_go_no_go,minimum_effective_independent_utc_days}'
          )::integer
       OR execution_record.minimum_effective_folds <> (
            protocol_json #>> '{q036_go_no_go,minimum_eligible_outer_folds}'
          )::integer
       OR execution_record.minimum_event_count <> (
            protocol_json #>> '{q036_go_no_go,minimum_complete_event_count}'
          )::bigint
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_cross_fit_corpora corpus
           WHERE corpus.cross_fit_execution_id = p_cross_fit_execution_id
             AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
             AND corpus.effective_day_count = p_effective_day_count
             AND corpus.effective_fold_count = p_effective_fold_count
       ) THEN
        RAISE EXCEPTION 'Q-036 facts do not match the locked candidate corpus and protocol'
            USING ERRCODE = '23514';
    END IF;

    IF p_effective_day_count < execution_record.minimum_effective_days
       OR p_effective_fold_count < execution_record.minimum_effective_folds THEN
        gate_decision := 'INSUFFICIENT_POWER';
    ELSIF p_p_value <= gate_alpha
       AND p_excess_mean >= model_a_point_threshold
       AND p_model_a_ci_lower_bound >= model_a_ci_threshold
       AND p_model_b_net_expectancy >= model_b_point_threshold
       AND p_model_b_stressed_ci_lower_bound > 0 THEN
        gate_decision := 'PASS';
    ELSE
        gate_decision := 'FAIL';
    END IF;

    INSERT INTO strategy_training.training_go_no_go_evaluations (
        go_no_go_evaluation_id, experiment_id, candidate_source,
        tpe_optimizer_run_id, random_optimizer_run_id, alpha,
        minimum_effective_days, minimum_effective_folds, bootstrap_replicates,
        random_seed, tpe_mean, random_mean, excess_mean, p_value,
        effective_day_count, effective_fold_count, decision, temporary_only,
        confidence_level, bootstrap_method, model_a_ci_lower_bound,
        model_a_ci_upper_bound, model_a_point_estimate_threshold,
        model_a_ci_lower_bound_threshold, model_b_net_expectancy,
        model_b_stressed_ci_lower_bound, model_b_point_estimate_threshold,
        model_b_stress_multiplier
    ) VALUES (
        new_id, execution_record.experiment_id, 'CROSS_FIT_MODEL_A_CANDIDATE',
        p_tpe_optimizer_run_id, p_random_optimizer_run_id, gate_alpha,
        execution_record.minimum_effective_days,
        execution_record.minimum_effective_folds, gate_bootstrap_replicates,
        gate_seed, p_tpe_mean, p_random_mean, p_excess_mean, p_p_value,
        p_effective_day_count, p_effective_fold_count, gate_decision, true,
        gate_confidence, gate_bootstrap_method, p_model_a_ci_lower_bound,
        p_model_a_ci_upper_bound, model_a_point_threshold,
        model_a_ci_threshold, p_model_b_net_expectancy,
        p_model_b_stressed_ci_lower_bound, model_b_point_threshold,
        p_model_b_stress_multiplier
    );
    RETURN new_id;
END
$$;

ALTER TABLE strategy_training.training_cross_fit_optimizer_scopes
    OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.register_cross_fit_optimizer_scope(
    uuid, uuid, integer, uuid, text, timestamptz, timestamptz,
    timestamptz, timestamptz
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_cross_fit_fold_runtime_scope()
    OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_go_no_go(
    uuid, uuid, uuid, uuid, numeric, numeric, numeric, numeric, numeric,
    numeric, numeric, numeric, numeric, integer, integer
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_optimizer_scopes FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION strategy_training.register_cross_fit_optimizer_scope(
    uuid, uuid, integer, uuid, text, timestamptz, timestamptz,
    timestamptz, timestamptz
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION strategy_training.record_cross_fit_go_no_go(
    uuid, uuid, uuid, uuid, numeric, numeric, numeric, numeric, numeric,
    numeric, numeric, numeric, numeric, integer, integer
) FROM PUBLIC;

GRANT SELECT ON strategy_training.training_cross_fit_optimizer_scopes
    TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.register_cross_fit_optimizer_scope(
    uuid, uuid, integer, uuid, text, timestamptz, timestamptz,
    timestamptz, timestamptz
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.record_cross_fit_go_no_go(
    uuid, uuid, uuid, uuid, numeric, numeric, numeric, numeric, numeric,
    numeric, numeric, numeric, numeric, integer, integer
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '077_training_cross_fit_runtime_guards',
    encode(digest(
        'auto_trade_v2_077_training_cross_fit_runtime_guards_v1',
        'sha256'
    ), 'hex'),
    'Bind optimizer scans to Cross-fit TRAIN folds and enforce locked Q-036 CI gates'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
