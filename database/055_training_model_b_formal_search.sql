\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

DO $$
DECLARE source_constraint text; use_constraint text;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO source_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_entry_events'::regclass
      AND conname = 'training_entry_events_source_check';
    SELECT pg_get_constraintdef(oid) INTO use_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_entry_events'::regclass
      AND conname = 'training_entry_events_source_use_check';
    IF source_constraint IS NULL
       OR position('CROSS_FIT_MODEL_A_CANDIDATE' IN source_constraint) = 0
       OR position('ADVERSE_OR_RANGE_CONTROL' IN source_constraint) = 0
       OR use_constraint IS NULL
       OR position('GO_NO_GO' IN use_constraint) = 0
       OR to_regclass('strategy_training.formal_model_b_cross_fit_entries') IS NULL THEN
        RAISE EXCEPTION '055 requires the post-048 Cross-fit source/use restoration';
    END IF;
END
$$;

ALTER TABLE strategy_training.training_model_b_sample_map
    DROP CONSTRAINT training_model_b_sample_map_sample_use_check;
ALTER TABLE strategy_training.training_model_b_sample_map
    ADD CONSTRAINT training_model_b_sample_map_sample_use_check CHECK (
        sample_use IN ('MODEL_B_PROTOTYPE', 'MODEL_B_TRAIN', 'MODEL_B_TRAIN_CONTROL')
    );

CREATE TABLE strategy_training.training_model_b_search_qualifications (
    qualification_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id          uuid NOT NULL REFERENCES strategy_training.training_experiments,
    dataset_version_id     uuid NOT NULL REFERENCES strategy_training.training_dataset_versions,
    coverage_state         varchar(16) NOT NULL CHECK (coverage_state IN ('PASS', 'FAIL')),
    backfill_accepted      boolean NOT NULL,
    coverage_report_hash   char(64) NOT NULL CHECK (coverage_report_hash ~ '^[0-9a-f]{64}$'),
    source_revision_hash   char(64) NOT NULL CHECK (source_revision_hash ~ '^[0-9a-f]{64}$'),
    qualified_entry_count  bigint NOT NULL CHECK (qualified_entry_count >= 0),
    qualification_report   jsonb NOT NULL CHECK (jsonb_typeof(qualification_report) = 'object'),
    recorded_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((coverage_state = 'PASS') = backfill_accepted),
    CHECK (coverage_state <> 'PASS' OR qualified_entry_count > 0),
    UNIQUE (experiment_id, dataset_version_id, coverage_report_hash)
);

CREATE TABLE strategy_training.training_model_b_decision_readiness (
    experiment_id          uuid NOT NULL REFERENCES strategy_training.training_experiments,
    decision_code          varchar(8) NOT NULL CHECK (
        decision_code IN ('Q-019', 'Q-029', 'Q-030', 'Q-036', 'Q-039')
    ),
    config_version_id      uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    recorded_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (experiment_id, decision_code)
);

CREATE TABLE strategy_training.training_go_no_go_round_zero_baselines (
    go_no_go_evaluation_id uuid PRIMARY KEY
                           REFERENCES strategy_training.training_go_no_go_evaluations,
    baseline_definition_hash char(64) NOT NULL
                             CHECK (baseline_definition_hash ~ '^[0-9a-f]{64}$'),
    baseline_metrics       jsonb NOT NULL CHECK (
        jsonb_typeof(baseline_metrics) = 'object' AND baseline_metrics <> '{}'::jsonb
    ),
    evidence_hash          char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    recorded_at            timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE strategy_training.training_model_b_formal_search_runs (
    formal_search_run_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id          uuid NOT NULL REFERENCES strategy_training.training_experiments,
    go_no_go_evaluation_id uuid NOT NULL REFERENCES strategy_training.training_go_no_go_evaluations,
    qualification_id       uuid NOT NULL REFERENCES strategy_training.training_model_b_search_qualifications,
    tpe_optimizer_run_id   uuid NOT NULL UNIQUE REFERENCES strategy_training.training_optimizer_runs,
    random_optimizer_run_id uuid NOT NULL UNIQUE REFERENCES strategy_training.training_optimizer_runs,
    entry_source           varchar(48) NOT NULL DEFAULT 'CROSS_FIT_MODEL_A'
                           CHECK (entry_source = 'CROSS_FIT_MODEL_A'),
    control_source         varchar(48) NOT NULL DEFAULT 'ADVERSE_OR_RANGE_CONTROL'
                           CHECK (control_source = 'ADVERSE_OR_RANGE_CONTROL'),
    temporary_only         boolean NOT NULL DEFAULT false CHECK (NOT temporary_only),
    state                  varchar(16) NOT NULL DEFAULT 'CREATED'
                           CHECK (state IN ('CREATED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (tpe_optimizer_run_id <> random_optimizer_run_id)
);

CREATE TABLE strategy_training.training_model_b_formal_search_inputs (
    formal_search_run_id   uuid NOT NULL REFERENCES strategy_training.training_model_b_formal_search_runs,
    entry_event_id         char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    input_kind             varchar(32) NOT NULL CHECK (
        input_kind IN ('NATURAL_ENTRY', 'ADVERSE_OR_RANGE_CONTROL')
    ),
    inclusion_probability  numeric CHECK (inclusion_probability > 0 AND inclusion_probability <= 1),
    selected_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (formal_search_run_id, entry_event_id)
);

CREATE VIEW strategy_training.model_b_formal_safe_inputs
WITH (security_barrier = true)
AS
SELECT input.formal_search_run_id, input.entry_event_id,
       input.inclusion_probability, entry.instrument_id, entry.symbol,
       entry.direction, entry.entry_time, entry.entry_price, entry.trigger_score,
       entry.coverage_percent
FROM strategy_training.training_model_b_formal_search_inputs input
JOIN strategy_training.training_entry_events entry
  ON entry.entry_event_id = input.entry_event_id;

CREATE TABLE strategy_training.training_non_reusable_iterations (
    iteration_id           uuid PRIMARY KEY REFERENCES strategy_training.training_iterations,
    restriction_reason     varchar(32) NOT NULL CHECK (restriction_reason = 'GO_NO_GO_TEMPORARY'),
    go_no_go_evaluation_id uuid NOT NULL REFERENCES strategy_training.training_go_no_go_evaluations,
    recorded_at            timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE strategy_training.training_model_b_formal_search_selections (
    formal_search_run_id   uuid PRIMARY KEY
                           REFERENCES strategy_training.training_model_b_formal_search_runs,
    selected_iteration_id uuid NOT NULL UNIQUE REFERENCES strategy_training.training_iterations,
    comparison_evidence_hash char(64) NOT NULL
                             CHECK (comparison_evidence_hash ~ '^[0-9a-f]{64}$'),
    selected_at            timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION strategy_training.guard_model_b_formal_selection()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_model_b_formal_search_runs formal
        JOIN strategy_training.training_optimizer_runs tpe
          ON tpe.optimizer_run_id = formal.tpe_optimizer_run_id
        JOIN strategy_training.training_optimizer_runs random_run
          ON random_run.optimizer_run_id = formal.random_optimizer_run_id
        JOIN strategy_training.training_optimizer_trial_proposals proposal
          ON proposal.optimizer_run_id = tpe.optimizer_run_id
        JOIN strategy_training.training_optimizer_trial_iterations link
          ON link.optimizer_trial_proposal_id = proposal.optimizer_trial_proposal_id
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = link.iteration_id
        WHERE formal.formal_search_run_id = NEW.formal_search_run_id
          AND formal.state = 'SUCCEEDED'
          AND tpe.state = 'SUCCEEDED' AND random_run.state = 'SUCCEEDED'
          AND iteration.iteration_id = NEW.selected_iteration_id
          AND iteration.state = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'formal Model-B selection requires a succeeded TPE iteration and completed same-budget comparison'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_model_b_formal_selection_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_model_b_formal_search_selections
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_model_b_formal_selection();

CREATE OR REPLACE FUNCTION strategy_training.guard_non_reusable_model_artifact()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE source_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'training_model_versions' THEN
        source_id := NEW.source_iteration_id;
    ELSE
        source_id := NEW.iteration_id;
    END IF;
    IF EXISTS (
        SELECT 1 FROM strategy_training.training_non_reusable_iterations denied
        WHERE denied.iteration_id = source_id
    ) THEN
        RAISE EXCEPTION 'go/no-go temporary Model-B artifacts cannot register, freeze or promote'
            USING ERRCODE = '23514';
    END IF;
    IF TG_TABLE_NAME = 'training_model_versions' THEN
      IF NEW.model_type = 'MODEL_B' THEN
        IF EXISTS (
            SELECT 1
            FROM strategy_training.training_optimizer_trial_iterations link
            JOIN strategy_training.training_optimizer_trial_proposals proposal
              ON proposal.optimizer_trial_proposal_id = link.optimizer_trial_proposal_id
            JOIN strategy_training.training_model_b_formal_search_runs formal
              ON formal.random_optimizer_run_id = proposal.optimizer_run_id
            WHERE link.iteration_id = source_id
        ) THEN
            RAISE EXCEPTION 'formal RANDOM comparator iterations can never register'
                USING ERRCODE = '23514';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM strategy_training.training_optimizer_trial_iterations link
            JOIN strategy_training.training_optimizer_trial_proposals proposal
              ON proposal.optimizer_trial_proposal_id = link.optimizer_trial_proposal_id
            JOIN strategy_training.training_model_b_formal_search_runs formal
              ON formal.tpe_optimizer_run_id = proposal.optimizer_run_id
            WHERE link.iteration_id = source_id
        ) AND NOT EXISTS (
            SELECT 1 FROM strategy_training.training_model_b_formal_search_selections selected
            WHERE selected.selected_iteration_id = source_id
        ) THEN
            RAISE EXCEPTION 'formal TPE iteration requires governed paired-search selection before registration'
                USING ERRCODE = '23514';
        END IF;
      END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_model_versions_non_reusable
BEFORE INSERT OR UPDATE ON strategy_training.training_model_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_non_reusable_model_artifact();
CREATE TRIGGER trg_training_final_freezes_non_reusable
BEFORE INSERT OR UPDATE ON strategy_training.training_final_candidate_freezes
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_non_reusable_model_artifact();

CREATE OR REPLACE FUNCTION strategy_training.guard_model_b_decision_readiness()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_config_versions config
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = NEW.experiment_id
         AND binding.config_version_id = config.config_version_id
        WHERE config.config_version_id = NEW.config_version_id
          AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'Model-B decision readiness requires an experiment-bound READY config'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_model_b_decision_readiness_guard
BEFORE INSERT OR UPDATE ON strategy_training.training_model_b_decision_readiness
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_model_b_decision_readiness();

CREATE OR REPLACE FUNCTION strategy_training.create_model_b_formal_search_run(
    p_experiment_id uuid,
    p_go_no_go_evaluation_id uuid,
    p_qualification_id uuid,
    p_tpe_optimizer_run_id uuid,
    p_random_optimizer_run_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    experiment_record strategy_training.training_experiments%ROWTYPE;
    gate_record strategy_training.training_go_no_go_evaluations%ROWTYPE;
    qualification_record strategy_training.training_model_b_search_qualifications%ROWTYPE;
    tpe_record strategy_training.training_optimizer_runs%ROWTYPE;
    random_record strategy_training.training_optimizer_runs%ROWTYPE;
BEGIN
    SELECT * INTO STRICT experiment_record FROM strategy_training.training_experiments
    WHERE experiment_id = p_experiment_id FOR SHARE;
    SELECT * INTO STRICT gate_record FROM strategy_training.training_go_no_go_evaluations
    WHERE go_no_go_evaluation_id = p_go_no_go_evaluation_id;
    SELECT * INTO STRICT qualification_record
    FROM strategy_training.training_model_b_search_qualifications
    WHERE qualification_id = p_qualification_id;
    SELECT * INTO STRICT tpe_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_tpe_optimizer_run_id;
    SELECT * INTO STRICT random_record FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_random_optimizer_run_id;

    IF experiment_record.state <> 'RUNNING'
       OR experiment_record.experiment_mode <> 'EXIT_POLICY'
       OR experiment_record.parent_experiment_id IS DISTINCT FROM gate_record.experiment_id
       OR gate_record.decision <> 'PASS' OR NOT gate_record.temporary_only THEN
        RAISE EXCEPTION 'formal Model-B search requires a passing temporary Cross-fit gate and a fresh child experiment'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_go_no_go_round_zero_baselines baseline
        WHERE baseline.go_no_go_evaluation_id = p_go_no_go_evaluation_id
    ) THEN
        RAISE EXCEPTION 'formal Model-B search requires immutable round-zero baseline evidence'
            USING ERRCODE = '23514';
    END IF;
    IF qualification_record.experiment_id <> p_experiment_id
       OR qualification_record.dataset_version_id <> experiment_record.dataset_version_id
       OR qualification_record.coverage_state <> 'PASS'
       OR NOT qualification_record.backfill_accepted THEN
        RAISE EXCEPTION 'formal Model-B search coverage/backfill qualification did not PASS'
            USING ERRCODE = '23514';
    END IF;
    IF (SELECT count(*) FROM strategy_training.training_model_b_decision_readiness ready
        WHERE ready.experiment_id = p_experiment_id) <> 5 THEN
        RAISE EXCEPTION 'Q-019/Q-029/Q-030/Q-036/Q-039 must all be READY'
            USING ERRCODE = '23514';
    END IF;
    IF tpe_record.experiment_id <> p_experiment_id OR tpe_record.optimizer_kind <> 'TPE'
       OR random_record.experiment_id <> p_experiment_id OR random_record.optimizer_kind <> 'RANDOM'
       OR tpe_record.trial_budget <> random_record.trial_budget
       OR tpe_record.search_space_config_version_id <> random_record.search_space_config_version_id
       OR tpe_record.optimizer_run_id IN (gate_record.tpe_optimizer_run_id, gate_record.random_optimizer_run_id)
       OR random_record.optimizer_run_id IN (gate_record.tpe_optimizer_run_id, gate_record.random_optimizer_run_id) THEN
        RAISE EXCEPTION 'formal Model-B search requires fresh TPE/RANDOM runs with equal budget and search space'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.formal_model_b_cross_fit_entries promoted
        JOIN strategy_training.training_entry_events entry
          ON entry.entry_event_id = promoted.entry_event_id
        WHERE promoted.dataset_version_id = experiment_record.dataset_version_id
          AND promoted.underlying_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
          AND promoted.underlying_use = 'GO_NO_GO'
          AND promoted.promoted_source = 'CROSS_FIT_MODEL_A'
          AND promoted.promoted_use = 'MODEL_B_TRAIN'
          AND entry.status = 'COMPLETE'
    ) THEN
        RAISE EXCEPTION 'formal Model-B search requires natural-frequency CROSS_FIT_MODEL_A inputs'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO strategy_training.training_model_b_formal_search_runs (
        formal_search_run_id, experiment_id, go_no_go_evaluation_id, qualification_id,
        tpe_optimizer_run_id, random_optimizer_run_id
    ) VALUES (
        new_id, p_experiment_id, p_go_no_go_evaluation_id, p_qualification_id,
        p_tpe_optimizer_run_id, p_random_optimizer_run_id
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.add_model_b_formal_search_input(
    p_formal_search_run_id uuid,
    p_entry_event_id char(64),
    p_inclusion_probability numeric DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE run_record strategy_training.training_model_b_formal_search_runs%ROWTYPE;
        entry_record strategy_training.training_entry_events%ROWTYPE;
        kind text;
BEGIN
    SELECT * INTO STRICT run_record FROM strategy_training.training_model_b_formal_search_runs
    WHERE formal_search_run_id = p_formal_search_run_id AND state = 'CREATED';
    SELECT * INTO STRICT entry_record FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id AND status = 'COMPLETE';
    IF entry_record.dataset_version_id <> (
        SELECT dataset_version_id FROM strategy_training.training_experiments
        WHERE experiment_id = run_record.experiment_id
    ) THEN
        RAISE EXCEPTION 'formal Model-B input belongs to another dataset' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM strategy_training.formal_model_b_cross_fit_entries promoted
        WHERE promoted.entry_event_id = p_entry_event_id
          AND promoted.dataset_version_id = entry_record.dataset_version_id
          AND promoted.underlying_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
          AND promoted.underlying_use = 'GO_NO_GO'
          AND promoted.promoted_source = 'CROSS_FIT_MODEL_A'
          AND promoted.promoted_use = 'MODEL_B_TRAIN'
    ) THEN
        kind := 'NATURAL_ENTRY';
    ELSIF entry_record.source = 'ADVERSE_OR_RANGE_CONTROL' THEN
        kind := 'ADVERSE_OR_RANGE_CONTROL';
    ELSE
        kind := NULL;
    END IF;
    IF kind IS NULL THEN
        RAISE EXCEPTION 'formal Model-B inputs reject temporary or unapproved sources'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_model_b_formal_search_inputs (
        formal_search_run_id, entry_event_id, input_kind, inclusion_probability
    ) VALUES (p_formal_search_run_id, p_entry_event_id, kind, p_inclusion_probability);
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_formal_exit_episode(
    p_entry_event_id char(64), p_model_b_iteration_id uuid,
    p_exit_rule_version_id uuid, p_fee_model_version_id uuid,
    p_slippage_model_version_id uuid
)
RETURNS TABLE (created_exit_episode_id char(64), created_model_b_sample_id char(64))
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    entry_record strategy_training.training_entry_events%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    experiment_record strategy_training.training_experiments%ROWTYPE;
    exit_json jsonb; sample_id char(64); episode_id char(64); sample_use_name text;
    governed_source text;
BEGIN
    SELECT * INTO STRICT entry_record FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id AND status = 'COMPLETE';
    IF EXISTS (
        SELECT 1 FROM strategy_training.formal_model_b_cross_fit_entries promoted
        WHERE promoted.entry_event_id = p_entry_event_id
          AND promoted.dataset_version_id = entry_record.dataset_version_id
          AND promoted.underlying_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
          AND promoted.underlying_use = 'GO_NO_GO'
          AND promoted.promoted_source = 'CROSS_FIT_MODEL_A'
          AND promoted.promoted_use = 'MODEL_B_TRAIN'
    ) THEN
        sample_use_name := 'MODEL_B_TRAIN';
        governed_source := 'CROSS_FIT_MODEL_A';
    ELSIF entry_record.source = 'ADVERSE_OR_RANGE_CONTROL' THEN
        sample_use_name := 'MODEL_B_TRAIN_CONTROL';
        governed_source := 'ADVERSE_OR_RANGE_CONTROL';
    ELSE
        RAISE EXCEPTION 'formal Model-B episodes reject temporary and non-approved entry sources'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT dataset_record FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = entry_record.dataset_version_id AND status = 'READY';
    SELECT experiment.* INTO STRICT experiment_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment USING (experiment_id)
    JOIN strategy_training.training_optimizer_trial_iterations trial_link
      ON trial_link.iteration_id = iteration.iteration_id
    JOIN strategy_training.training_optimizer_trial_proposals proposal
      ON proposal.optimizer_trial_proposal_id = trial_link.optimizer_trial_proposal_id
    JOIN strategy_training.training_model_b_formal_search_runs run
      ON run.experiment_id = experiment.experiment_id
     AND proposal.optimizer_run_id IN (run.tpe_optimizer_run_id, run.random_optimizer_run_id)
    JOIN strategy_training.training_model_b_formal_search_inputs input
      ON input.formal_search_run_id = run.formal_search_run_id
     AND input.entry_event_id = entry_record.entry_event_id
    WHERE iteration.iteration_id = p_model_b_iteration_id
      AND iteration.state = 'RUNNING' AND experiment.state = 'RUNNING'
      AND experiment.experiment_mode = 'EXIT_POLICY'
      AND experiment.dataset_version_id = entry_record.dataset_version_id;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id AND config.status = 'READY'
        WHERE binding.experiment_id = experiment_record.experiment_id
          AND (binding.config_type, binding.config_version_id) IN (
              ('EXIT_RULES', p_exit_rule_version_id), ('FEE_MODEL', p_fee_model_version_id),
              ('SLIPPAGE_MODEL', p_slippage_model_version_id)
          )
        GROUP BY binding.experiment_id HAVING count(*) = 3
    ) THEN
        RAISE EXCEPTION 'formal Model-B configs must be READY and frozen' USING ERRCODE = '23514';
    END IF;
    SELECT config_json INTO STRICT exit_json FROM strategy_training.training_config_versions
    WHERE config_version_id = p_exit_rule_version_id AND config_type = 'EXIT_RULES';
    IF entry_record.entry_time + make_interval(
        secs => (exit_json ->> 'max_holding_seconds')::double precision
    ) > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'formal Model-B holding path exceeds TRAIN partition' USING ERRCODE = '23514';
    END IF;
    sample_id := encode(public.digest(
        p_entry_event_id || ':' || p_model_b_iteration_id::text || ':' || sample_use_name, 'sha256'
    ), 'hex');
    episode_id := encode(public.digest(concat_ws(':', sample_id,
        p_exit_rule_version_id::text, p_fee_model_version_id::text,
        p_slippage_model_version_id::text), 'sha256'), 'hex');
    INSERT INTO strategy_training.training_model_b_sample_map (
        model_b_sample_id, entry_event_id, sample_use, natural_source, mapping_hash
    ) VALUES (sample_id, p_entry_event_id, sample_use_name, governed_source,
        encode(public.digest(sample_id || ':' || p_entry_event_id, 'sha256'), 'hex'));
    INSERT INTO strategy_training.training_exit_episode_inputs (
        exit_episode_id, model_b_sample_id, model_b_iteration_id, dataset_version_id,
        instrument_id, symbol, direction, entry_time, entry_reference_price,
        maximum_end_at, interval_seconds, exit_rule_version_id,
        fee_model_version_id, slippage_model_version_id
    ) VALUES (episode_id, sample_id, p_model_b_iteration_id, entry_record.dataset_version_id,
        entry_record.instrument_id, entry_record.symbol, entry_record.direction,
        entry_record.entry_time, entry_record.entry_price,
        entry_record.entry_time + make_interval(
            secs => (exit_json ->> 'max_holding_seconds')::double precision),
        dataset_record.interval_seconds, p_exit_rule_version_id,
        p_fee_model_version_id, p_slippage_model_version_id);
    RETURN QUERY SELECT episode_id, sample_id;
END
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
        exit_config jsonb; fee_config jsonb; slippage_config jsonb; portfolio_config jsonb;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'MODEL_B'
       OR task_record.task_type <> 'MODEL_B_REPLAY' OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'MODEL_B replay requires its active model-B lease' USING ERRCODE = '40001';
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
       OR NOT ((sample_record.sample_use = 'MODEL_B_PROTOTYPE'
                AND sample_record.natural_source = 'FIXED_BASELINE_MODEL_A')
            OR (sample_record.sample_use = 'MODEL_B_TRAIN'
                AND sample_record.natural_source = 'CROSS_FIT_MODEL_A')
            OR (sample_record.sample_use = 'MODEL_B_TRAIN_CONTROL'
                AND sample_record.natural_source = 'ADVERSE_OR_RANGE_CONTROL')) THEN
        RAISE EXCEPTION 'model-B sample does not belong to its governed leased use'
            USING ERRCODE = '23514';
    END IF;
    SELECT config_json INTO STRICT exit_config FROM strategy_training.training_config_versions
    WHERE config_version_id = episode_record.exit_rule_version_id
      AND config_type = 'EXIT_RULES' AND status = 'READY';
    SELECT config_json INTO STRICT fee_config FROM strategy_training.training_config_versions
    WHERE config_version_id = episode_record.fee_model_version_id
      AND config_type = 'FEE_MODEL' AND status = 'READY';
    SELECT config_json INTO STRICT slippage_config FROM strategy_training.training_config_versions
    WHERE config_version_id = episode_record.slippage_model_version_id
      AND config_type = 'SLIPPAGE_MODEL' AND status = 'READY';
    SELECT config.config_json INTO STRICT portfolio_config
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id AND binding.config_type = 'PORTFOLIO_RULES'
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
    RETURN QUERY SELECT episode_record.model_b_sample_id, sample_record.entry_event_id,
        episode_record.exit_episode_id, episode_record.status::text,
        episode_record.exit_rule_version_id, exit_config,
        episode_record.fee_model_version_id, fee_config,
        episode_record.slippage_model_version_id, slippage_config,
        (portfolio_config ->> 'notional_per_trade')::numeric;
END
$$;

ALTER TABLE strategy_training.training_model_b_search_qualifications OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_b_decision_readiness OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_go_no_go_round_zero_baselines OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_b_formal_search_runs OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_b_formal_search_inputs OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_model_b_formal_search_selections OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_non_reusable_iterations OWNER TO tb2_training_owner;
ALTER VIEW strategy_training.model_b_formal_safe_inputs OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_model_b_formal_selection() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_non_reusable_model_artifact() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_model_b_decision_readiness() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_model_b_formal_search_run(
    uuid, uuid, uuid, uuid, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.add_model_b_formal_search_input(
    uuid, char(64), numeric
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_formal_exit_episode(
    char(64), uuid, uuid, uuid, uuid
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_model_b_search_qualifications,
    strategy_training.training_model_b_decision_readiness,
    strategy_training.training_go_no_go_round_zero_baselines,
    strategy_training.training_model_b_formal_search_runs,
    strategy_training.training_model_b_formal_search_inputs,
    strategy_training.training_model_b_formal_search_selections,
    strategy_training.training_non_reusable_iterations FROM PUBLIC;
REVOKE ALL ON strategy_training.model_b_formal_safe_inputs FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.create_model_b_formal_search_run(
    uuid, uuid, uuid, uuid, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.add_model_b_formal_search_input(
    uuid, char(64), numeric
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.create_training_formal_exit_episode(
    char(64), uuid, uuid, uuid, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) FROM PUBLIC;
GRANT SELECT, INSERT ON strategy_training.training_model_b_search_qualifications,
    strategy_training.training_model_b_decision_readiness,
    strategy_training.training_go_no_go_round_zero_baselines,
    strategy_training.training_non_reusable_iterations,
    strategy_training.training_model_b_formal_search_selections TO tb2_training_evaluator;
GRANT SELECT ON strategy_training.model_b_formal_safe_inputs TO tb2_training_model_b;
GRANT EXECUTE ON FUNCTION strategy_training.create_model_b_formal_search_run(
    uuid, uuid, uuid, uuid, uuid
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.add_model_b_formal_search_input(
    uuid, char(64), numeric
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.create_training_formal_exit_episode(
    char(64), uuid, uuid, uuid, uuid
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.training_model_b_replay_context(
    uuid, uuid, char(64)
) TO tb2_training_model_b;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '055_training_model_b_formal_search',
    encode(digest('auto_trade_v2_055_training_model_b_formal_search_v1', 'sha256'), 'hex'),
    'Add fail-closed fresh formal Model-B search, safe inputs and temporary artifact isolation'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
