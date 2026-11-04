\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- 048 narrowed this constraint for discovery.  M6 restores the complete governed
-- source set while retaining the source/use pairing introduced by 033.
ALTER TABLE strategy_training.training_entry_events
    DROP CONSTRAINT training_entry_events_source_check;
ALTER TABLE strategy_training.training_entry_events
    ADD CONSTRAINT training_entry_events_source_check CHECK (source IN (
        'FIXED_BASELINE_MODEL_A', 'CROSS_FIT_MODEL_A_CANDIDATE',
        'CROSS_FIT_MODEL_A', 'LOCKED_MODEL_A_VALIDATION_SIGNAL',
        'MODEL_A_SIGNAL', 'ORACLE_ENTRY_BENCHMARK',
        'ADVERSE_OR_RANGE_CONTROL', 'IN_SAMPLE_MODEL_A'
    ));
ALTER TABLE strategy_training.training_entry_events
    DROP CONSTRAINT training_entry_events_entry_use_check;
ALTER TABLE strategy_training.training_entry_events
    DROP CONSTRAINT training_entry_events_source_use_check;
UPDATE strategy_training.training_entry_events
SET entry_use = 'MODEL_A_DISCOVERY'
WHERE source = 'IN_SAMPLE_MODEL_A';
UPDATE strategy_training.training_entry_events
SET entry_use = 'MODEL_B_TRAIN'
WHERE source = 'ADVERSE_OR_RANGE_CONTROL';
ALTER TABLE strategy_training.training_entry_events
    ADD CONSTRAINT training_entry_events_entry_use_check CHECK (entry_use IN (
        'MODEL_A_DISCOVERY', 'MODEL_B_PROTOTYPE', 'GO_NO_GO', 'MODEL_B_TRAIN',
        'VALIDATION', 'END_TO_END_TEST', 'ORACLE_BENCHMARK'
    ));
ALTER TABLE strategy_training.training_entry_events
    ADD CONSTRAINT training_entry_events_source_use_check CHECK (
        (source = 'IN_SAMPLE_MODEL_A' AND entry_use = 'MODEL_A_DISCOVERY')
        OR (source = 'FIXED_BASELINE_MODEL_A' AND entry_use = 'MODEL_B_PROTOTYPE')
        OR (source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND entry_use = 'GO_NO_GO')
        OR (source = 'CROSS_FIT_MODEL_A' AND entry_use = 'MODEL_B_TRAIN')
        OR (source = 'LOCKED_MODEL_A_VALIDATION_SIGNAL' AND entry_use = 'VALIDATION')
        OR (source = 'MODEL_A_SIGNAL' AND entry_use = 'END_TO_END_TEST')
        OR (source = 'ORACLE_ENTRY_BENCHMARK' AND entry_use = 'ORACLE_BENCHMARK')
        OR (source = 'ADVERSE_OR_RANGE_CONTROL' AND entry_use = 'MODEL_B_TRAIN')
    );

CREATE OR REPLACE FUNCTION strategy_training.guard_training_entry_event_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    iteration_state text;
    iteration_source text;
    experiment_dataset_id uuid;
    pool_record strategy_training.training_historical_pool_evaluations%ROWTYPE;
    factor_config_type text;
    factor_config_status text;
    factor_config_json jsonb;
    scan_config_type text;
    scan_config_status text;
BEGIN
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id FOR SHARE;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR NEW.signal_time < dataset_record.eligible_start_at
       OR NEW.signal_time >= dataset_record.eligible_end_at
       OR NEW.entry_time <> NEW.signal_time + make_interval(secs => dataset_record.interval_seconds)
       OR NEW.entry_event_id <> strategy_training.compute_training_entry_event_id(
           NEW.dataset_version_id, NEW.generating_iteration_id, NEW.symbol,
           NEW.signal_time, NEW.entry_time, NEW.direction
       ) THEN
        RAISE EXCEPTION 'entry signal/entry time is outside the governed TRAIN interval'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.state, iteration.candidate_source, experiment.dataset_version_id
    INTO STRICT iteration_state, iteration_source, experiment_dataset_id
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = NEW.generating_iteration_id;
    IF iteration_state <> 'RUNNING' OR experiment_dataset_id <> NEW.dataset_version_id
       OR NOT (
           (iteration_source = 'FIXED_BASELINE' AND NEW.source = 'FIXED_BASELINE_MODEL_A')
           OR (iteration_source IN ('OPTUNA_TPE', 'RANDOM_SEARCH')
               AND NEW.source IN ('IN_SAMPLE_MODEL_A', 'CROSS_FIT_MODEL_A_CANDIDATE',
                                  'CROSS_FIT_MODEL_A'))
       ) THEN
        RAISE EXCEPTION 'entry source does not match its running TRAIN generator'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT pool_record
    FROM strategy_training.training_historical_pool_evaluations
    WHERE pool_evaluation_id = NEW.pool_evaluation_id;
    IF pool_record.dataset_version_id <> NEW.dataset_version_id
       OR pool_record.instrument_id <> NEW.instrument_id
       OR pool_record.symbol <> NEW.symbol OR NOT pool_record.is_eligible
       OR pool_record.evaluation_at > NEW.signal_time THEN
        RAISE EXCEPTION 'entry lacks contemporaneous eligible-pool evidence'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.ticker_pool_rule_version_id <> dataset_record.ticker_pool_rule_version_id THEN
        RAISE EXCEPTION 'entry ticker-pool rule does not match its dataset'
            USING ERRCODE = '23514';
    END IF;
    SELECT config_type, status, config_json
    INTO STRICT factor_config_type, factor_config_status, factor_config_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.factor_registry_version_id;
    SELECT config_type, status INTO STRICT scan_config_type, scan_config_status
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.scan_parameters_version_id;
    IF factor_config_type <> 'FACTOR_REGISTRY' OR factor_config_status <> 'READY'
       OR jsonb_typeof(factor_config_json -> 'factors') IS DISTINCT FROM 'array'
       OR jsonb_array_length(factor_config_json -> 'factors') = 0
       OR scan_config_type <> 'SEARCH_SPACE' OR scan_config_status <> 'READY' THEN
        RAISE EXCEPTION 'entry requires READY factor-registry and scan configs'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
        WHERE iteration.iteration_id = NEW.generating_iteration_id
          AND binding.config_type = 'FACTOR_REGISTRY'
          AND binding.config_version_id = NEW.factor_registry_version_id
    ) OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
        WHERE iteration.iteration_id = NEW.generating_iteration_id
          AND binding.config_type = 'SEARCH_SPACE'
          AND binding.config_version_id = NEW.scan_parameters_version_id
    ) THEN
        RAISE EXCEPTION 'entry configs are not frozen on its experiment'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_candidate_entry_event(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64),
    p_dataset_version_id uuid, p_generating_iteration_id uuid,
    p_instrument_id bigint, p_symbol text, p_signal_time timestamptz,
    p_entry_time timestamptz, p_direction text, p_trigger_score numeric,
    p_coverage_percent numeric, p_theoretical_signal_price numeric,
    p_entry_price numeric, p_pool_evaluation_id uuid,
    p_ticker_pool_rule_version_id uuid, p_factor_registry_version_id uuid,
    p_scan_parameters_version_id uuid, p_signal_payload_hash char(64)
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS DISTINCT FROM p_generating_iteration_id THEN
        RAISE EXCEPTION 'candidate entry write requires its active scan lease'
            USING ERRCODE = '40001';
    END IF;
    INSERT INTO strategy_training.training_entry_events (
        entry_event_id, dataset_version_id, generating_iteration_id,
        instrument_id, symbol, source, entry_use, signal_time, entry_time, direction,
        trigger_score, coverage_percent, theoretical_signal_price, entry_price,
        pool_evaluation_id, ticker_pool_rule_version_id,
        factor_registry_version_id, scan_parameters_version_id, signal_payload_hash
    ) VALUES (
        p_entry_event_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, upper(p_symbol), 'IN_SAMPLE_MODEL_A', 'MODEL_A_DISCOVERY',
        p_signal_time, p_entry_time, p_direction, p_trigger_score, p_coverage_percent,
        p_theoretical_signal_price, p_entry_price, p_pool_evaluation_id,
        p_ticker_pool_rule_version_id, p_factor_registry_version_id,
        p_scan_parameters_version_id, p_signal_payload_hash
    );
    RETURN p_entry_event_id;
END
$$;

CREATE TABLE strategy_training.training_cross_fit_executions (
    cross_fit_execution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id uuid NOT NULL UNIQUE REFERENCES strategy_training.training_experiments,
    dataset_version_id uuid NOT NULL REFERENCES strategy_training.training_dataset_versions,
    protocol_config_version_id uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    coverage_evidence_hash char(64) NOT NULL CHECK (coverage_evidence_hash ~ '^[0-9a-f]{64}$'),
    source_revision_watermark_hash char(64) NOT NULL
        CHECK (source_revision_watermark_hash ~ '^[0-9a-f]{64}$'),
    coverage_gate_status varchar(24) NOT NULL CHECK (coverage_gate_status IN (
        'BACKFILL_PENDING', 'ACCEPTED', 'REJECTED'
    )),
    state varchar(32) NOT NULL DEFAULT 'PLANNED' CHECK (state IN (
        'PLANNED', 'RUNNING', 'CANDIDATE_READY', 'GO_NO_GO_PASSED',
        'FORMAL_CORPUS_READY', 'INSUFFICIENT_POWER', 'FAILED'
    )),
    question_readiness jsonb NOT NULL,
    minimum_effective_folds integer NOT NULL CHECK (minimum_effective_folds > 0),
    minimum_effective_days integer NOT NULL CHECK (minimum_effective_days > 0),
    minimum_event_count bigint NOT NULL CHECK (minimum_event_count > 0),
    failure_code varchar(64),
    lease_token uuid,
    leased_by text,
    lease_expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at timestamptz,
    completed_at timestamptz,
    CHECK (jsonb_typeof(question_readiness) = 'object'),
    CHECK ((lease_token IS NULL AND leased_by IS NULL AND lease_expires_at IS NULL)
        OR (lease_token IS NOT NULL AND leased_by IS NOT NULL
            AND btrim(leased_by) <> '' AND lease_expires_at IS NOT NULL)),
    CHECK ((state = 'PLANNED' AND started_at IS NULL AND completed_at IS NULL
                            AND failure_code IS NULL)
        OR (state IN ('RUNNING', 'CANDIDATE_READY', 'GO_NO_GO_PASSED')
                            AND started_at IS NOT NULL AND completed_at IS NULL
                            AND failure_code IS NULL)
        OR (state = 'FORMAL_CORPUS_READY' AND started_at IS NOT NULL
                            AND completed_at IS NOT NULL AND failure_code IS NULL)
        OR (state IN ('INSUFFICIENT_POWER', 'FAILED') AND completed_at IS NOT NULL
                            AND failure_code IS NOT NULL AND btrim(failure_code) <> ''))
);

ALTER TABLE strategy_training.training_cross_fit_folds
    ADD CONSTRAINT training_cross_fit_folds_model_version_fk
    FOREIGN KEY (fold_model_version_id)
    REFERENCES strategy_training.training_model_versions (model_version_id);

ALTER TABLE strategy_training.training_cross_fit_fold_searches
    DROP CONSTRAINT training_cross_fit_fold_searches_training_entry_source_check;
ALTER TABLE strategy_training.training_cross_fit_fold_searches
    ADD CONSTRAINT training_cross_fit_fold_searches_training_entry_source_check
    CHECK (training_entry_source = 'CROSS_FIT_MODEL_A_CANDIDATE');
CREATE UNIQUE INDEX ux_training_cross_fit_fold_search_optimizer
ON strategy_training.training_cross_fit_fold_searches (inner_optimizer_run_id);

ALTER TABLE strategy_training.training_go_no_go_evaluations
    ADD CONSTRAINT training_go_no_go_distinct_optimizers_check
    CHECK (tpe_optimizer_run_id <> random_optimizer_run_id),
    ADD CONSTRAINT training_go_no_go_temporary_only_check
    CHECK (temporary_only);

CREATE OR REPLACE FUNCTION strategy_training.guard_cross_fit_optimizer_links()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE fold_experiment_id uuid;
DECLARE optimizer_experiment_id uuid;
DECLARE optimizer_kind text;
BEGIN
    IF TG_TABLE_NAME = 'training_cross_fit_fold_searches' THEN
        SELECT experiment_id INTO STRICT fold_experiment_id
        FROM strategy_training.training_cross_fit_folds
        WHERE cross_fit_fold_id = NEW.cross_fit_fold_id;
        SELECT experiment_id, optimizer_kind
        INTO STRICT optimizer_experiment_id, optimizer_kind
        FROM strategy_training.training_optimizer_runs
        WHERE optimizer_run_id = NEW.inner_optimizer_run_id;
        IF optimizer_experiment_id <> fold_experiment_id
           OR optimizer_kind NOT IN ('TPE', 'RANDOM')
           OR NEW.training_entry_source <> 'CROSS_FIT_MODEL_A_CANDIDATE'
           OR NEW.inner_validation_count <> 0 THEN
            RAISE EXCEPTION 'fold search must use a new same-experiment candidate optimizer'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        SELECT experiment_id, optimizer_kind
        INTO STRICT optimizer_experiment_id, optimizer_kind
        FROM strategy_training.training_optimizer_runs
        WHERE optimizer_run_id = NEW.tpe_optimizer_run_id;
        IF optimizer_experiment_id <> NEW.experiment_id OR optimizer_kind <> 'TPE' THEN
            RAISE EXCEPTION 'go/no-go TPE run is invalid' USING ERRCODE = '23514';
        END IF;
        SELECT experiment_id, optimizer_kind
        INTO STRICT optimizer_experiment_id, optimizer_kind
        FROM strategy_training.training_optimizer_runs
        WHERE optimizer_run_id = NEW.random_optimizer_run_id;
        IF optimizer_experiment_id <> NEW.experiment_id OR optimizer_kind <> 'RANDOM'
           OR NEW.tpe_optimizer_run_id = NEW.random_optimizer_run_id OR NOT NEW.temporary_only THEN
            RAISE EXCEPTION 'go/no-go random control is invalid' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_cross_fit_fold_optimizer_link
BEFORE INSERT OR UPDATE ON strategy_training.training_cross_fit_fold_searches
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_cross_fit_optimizer_links();
CREATE TRIGGER trg_cross_fit_gate_optimizer_links
BEFORE INSERT OR UPDATE ON strategy_training.training_go_no_go_evaluations
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_cross_fit_optimizer_links();

CREATE TABLE strategy_training.training_cross_fit_fold_executions (
    cross_fit_fold_id uuid PRIMARY KEY REFERENCES strategy_training.training_cross_fit_folds,
    cross_fit_execution_id uuid NOT NULL REFERENCES strategy_training.training_cross_fit_executions,
    optimizer_run_id uuid NOT NULL UNIQUE REFERENCES strategy_training.training_optimizer_runs,
    raw_training_sample_count bigint NOT NULL CHECK (raw_training_sample_count >= 0),
    effective_training_sample_count bigint NOT NULL CHECK (
        effective_training_sample_count >= 0
        AND effective_training_sample_count <= raw_training_sample_count
    ),
    prediction_sample_count bigint NOT NULL CHECK (prediction_sample_count >= 0),
    warmup_excluded_count bigint NOT NULL CHECK (warmup_excluded_count >= 0),
    purge_excluded_count bigint NOT NULL CHECK (purge_excluded_count >= 0),
    embargo_excluded_count bigint NOT NULL CHECK (embargo_excluded_count >= 0),
    trial_budget integer NOT NULL CHECK (trial_budget > 0),
    wall_clock_budget_seconds integer NOT NULL CHECK (wall_clock_budget_seconds > 0),
    repeat_count integer NOT NULL CHECK (repeat_count > 0),
    random_seed bigint NOT NULL,
    from_scratch boolean NOT NULL CHECK (from_scratch),
    inner_validation_count integer NOT NULL DEFAULT 0 CHECK (inner_validation_count = 0),
    fold_protocol_hash char(64) NOT NULL CHECK (fold_protocol_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (cross_fit_execution_id, cross_fit_fold_id)
);

CREATE TABLE strategy_training.training_cross_fit_corpora (
    cross_fit_corpus_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cross_fit_execution_id uuid NOT NULL REFERENCES strategy_training.training_cross_fit_executions,
    source varchar(48) NOT NULL CHECK (source IN (
        'CROSS_FIT_MODEL_A_CANDIDATE', 'CROSS_FIT_MODEL_A'
    )),
    corpus_use varchar(24) NOT NULL CHECK (corpus_use IN ('GO_NO_GO', 'MODEL_B_TRAIN')),
    source_corpus_id uuid REFERENCES strategy_training.training_cross_fit_corpora,
    event_count bigint NOT NULL CHECK (event_count > 0),
    effective_fold_count integer NOT NULL CHECK (effective_fold_count > 0),
    effective_day_count integer NOT NULL CHECK (effective_day_count > 0),
    corpus_hash char(64) NOT NULL CHECK (corpus_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND corpus_use = 'GO_NO_GO'
            AND source_corpus_id IS NULL)
        OR (source = 'CROSS_FIT_MODEL_A' AND corpus_use = 'MODEL_B_TRAIN'
            AND source_corpus_id IS NOT NULL)),
    UNIQUE (cross_fit_execution_id, source),
    UNIQUE (source_corpus_id)
);

CREATE TABLE strategy_training.training_cross_fit_corpus_events (
    cross_fit_corpus_id uuid NOT NULL REFERENCES strategy_training.training_cross_fit_corpora,
    entry_event_id char(64) NOT NULL REFERENCES strategy_training.training_entry_events,
    declared_source varchar(48) NOT NULL CHECK (declared_source IN (
        'CROSS_FIT_MODEL_A_CANDIDATE', 'CROSS_FIT_MODEL_A'
    )),
    declared_use varchar(24) NOT NULL CHECK (declared_use IN ('GO_NO_GO', 'MODEL_B_TRAIN')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (cross_fit_corpus_id, entry_event_id),
    CHECK ((declared_source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND declared_use = 'GO_NO_GO')
        OR (declared_source = 'CROSS_FIT_MODEL_A' AND declared_use = 'MODEL_B_TRAIN'))
);

CREATE VIEW strategy_training.formal_model_b_cross_fit_entries
WITH (security_barrier = true)
AS
SELECT corpus.cross_fit_execution_id, corpus.cross_fit_corpus_id,
       member.entry_event_id, event.source AS underlying_source,
       event.entry_use AS underlying_use, member.declared_source AS promoted_source,
       member.declared_use AS promoted_use, event.dataset_version_id,
       event.generating_iteration_id, event.instrument_id, event.symbol,
       event.signal_time, event.entry_time, event.direction,
       event.trigger_score, event.coverage_percent, event.entry_price
FROM strategy_training.training_cross_fit_corpora corpus
JOIN strategy_training.training_cross_fit_corpus_events member
  ON member.cross_fit_corpus_id = corpus.cross_fit_corpus_id
JOIN strategy_training.training_entry_events event
  ON event.entry_event_id = member.entry_event_id
WHERE corpus.source = 'CROSS_FIT_MODEL_A'
  AND corpus.corpus_use = 'MODEL_B_TRAIN'
  AND member.declared_source = 'CROSS_FIT_MODEL_A'
  AND member.declared_use = 'MODEL_B_TRAIN';

CREATE OR REPLACE FUNCTION strategy_training.guard_cross_fit_corpus_event()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
DECLARE event_source text;
DECLARE event_use text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Cross-fit corpus membership is append-only' USING ERRCODE = '55000';
    END IF;
    SELECT * INTO STRICT corpus_record
    FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_corpus_id = NEW.cross_fit_corpus_id;
    SELECT source, entry_use INTO STRICT event_source, event_use
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = NEW.entry_event_id;
    IF event_source <> 'CROSS_FIT_MODEL_A_CANDIDATE' OR event_use <> 'GO_NO_GO' THEN
        RAISE EXCEPTION 'corpus membership requires an underlying candidate event'
            USING ERRCODE = '23514';
    END IF;
    IF corpus_record.source = 'CROSS_FIT_MODEL_A_CANDIDATE' THEN
        IF NEW.declared_source <> 'CROSS_FIT_MODEL_A_CANDIDATE'
           OR NEW.declared_use <> 'GO_NO_GO' THEN
            RAISE EXCEPTION 'candidate corpus membership cannot be promoted in place'
                USING ERRCODE = '23514';
        END IF;
    ELSIF corpus_record.source = 'CROSS_FIT_MODEL_A' THEN
        IF NEW.declared_source <> 'CROSS_FIT_MODEL_A'
           OR NEW.declared_use <> 'MODEL_B_TRAIN'
           OR NOT EXISTS (
               SELECT 1 FROM strategy_training.training_cross_fit_corpus_events candidate
               WHERE candidate.cross_fit_corpus_id = corpus_record.source_corpus_id
                 AND candidate.entry_event_id = NEW.entry_event_id
                 AND candidate.declared_source = 'CROSS_FIT_MODEL_A_CANDIDATE'
           ) THEN
            RAISE EXCEPTION 'formal membership requires its immutable candidate mapping'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_cross_fit_corpus_event_guard
BEFORE INSERT OR UPDATE OR DELETE ON strategy_training.training_cross_fit_corpus_events
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_cross_fit_corpus_event();

CREATE OR REPLACE FUNCTION strategy_training.assert_cross_fit_execution_lease(
    p_cross_fit_execution_id uuid, p_lease_token uuid
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_executions execution
        WHERE execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND execution.lease_token = p_lease_token
          AND execution.lease_expires_at > clock_timestamp()
    ) THEN
        RAISE EXCEPTION 'Cross-fit execution requires its active lease'
            USING ERRCODE = '40001';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_cross_fit_execution(
    p_experiment_id uuid, p_protocol_config_version_id uuid,
    p_coverage_gate_status text, p_coverage_evidence_hash char(64),
    p_source_revision_watermark_hash char(64), p_question_readiness jsonb,
    p_minimum_effective_folds integer, p_minimum_effective_days integer,
    p_minimum_event_count bigint
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE new_id uuid := gen_random_uuid();
DECLARE experiment_dataset_id uuid;
BEGIN
    SELECT dataset_version_id INTO STRICT experiment_dataset_id
    FROM strategy_training.training_experiments
    WHERE experiment_id = p_experiment_id;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
        WHERE binding.experiment_id = p_experiment_id
          AND binding.config_type = 'CROSS_FIT_PROTOCOL'
          AND binding.config_version_id = p_protocol_config_version_id
    ) THEN
        RAISE EXCEPTION 'Cross-fit protocol must be frozen on the experiment'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_executions (
        cross_fit_execution_id, experiment_id, dataset_version_id,
        protocol_config_version_id, coverage_evidence_hash,
        source_revision_watermark_hash, coverage_gate_status,
        question_readiness, minimum_effective_folds,
        minimum_effective_days, minimum_event_count
    ) VALUES (
        new_id, p_experiment_id, experiment_dataset_id,
        p_protocol_config_version_id, p_coverage_evidence_hash,
        p_source_revision_watermark_hash, p_coverage_gate_status,
        p_question_readiness, p_minimum_effective_folds,
        p_minimum_effective_days, p_minimum_event_count
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.claim_cross_fit_execution(
    p_cross_fit_execution_id uuid, p_worker_identity text, p_lease_seconds integer
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE new_token uuid := gen_random_uuid();
BEGIN
    IF p_worker_identity IS NULL OR btrim(p_worker_identity) = '' OR p_lease_seconds <= 0 THEN
        RAISE EXCEPTION 'worker identity and positive lease duration are required'
            USING ERRCODE = '22023';
    END IF;
    UPDATE strategy_training.training_cross_fit_executions
    SET lease_token = new_token, leased_by = p_worker_identity,
        lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds)
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND state NOT IN ('FORMAL_CORPUS_READY', 'INSUFFICIENT_POWER', 'FAILED')
      AND (lease_token IS NULL OR lease_expires_at <= clock_timestamp());
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cross-fit execution is not claimable' USING ERRCODE = '40001';
    END IF;
    RETURN new_token;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.start_cross_fit_execution(
    p_cross_fit_execution_id uuid, p_lease_token uuid
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE dataset_record strategy_training.training_dataset_versions%ROWTYPE;
DECLARE protocol_record strategy_training.training_config_versions%ROWTYPE;
DECLARE question text;
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    SELECT * INTO STRICT dataset_record FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = execution_record.dataset_version_id FOR SHARE;
    SELECT * INTO STRICT protocol_record FROM strategy_training.training_config_versions
    WHERE config_version_id = execution_record.protocol_config_version_id FOR SHARE;
    IF execution_record.state <> 'PLANNED'
       OR execution_record.coverage_gate_status <> 'ACCEPTED'
       OR dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR dataset_record.root_fingerprint IS NULL
       OR execution_record.source_revision_watermark_hash <> encode(
            public.digest(dataset_record.source_revision_watermark::text, 'sha256'), 'hex'
       )
       OR execution_record.coverage_evidence_hash <> (
            SELECT encode(public.digest(string_agg(report.evidence_hash, ''
                ORDER BY report.dependency_name), 'sha256'), 'hex')
            FROM strategy_training.training_data_quality_reports report
            WHERE report.dataset_version_id = execution_record.dataset_version_id
              AND report.is_required
       )
       OR protocol_record.status <> 'READY'
       OR protocol_record.config_type <> 'CROSS_FIT_PROTOCOL'
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_experiment_config_bindings binding
           WHERE binding.experiment_id = execution_record.experiment_id
             AND binding.config_type = 'CROSS_FIT_PROTOCOL'
             AND binding.config_version_id = execution_record.protocol_config_version_id
       )
       OR EXISTS (
           SELECT 1 FROM strategy_training.training_data_quality_reports report
           WHERE report.dataset_version_id = execution_record.dataset_version_id
             AND report.is_required AND report.status <> 'PASS'
       )
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_data_quality_reports report
           WHERE report.dataset_version_id = execution_record.dataset_version_id
             AND report.is_required AND report.status = 'PASS'
       ) THEN
        RAISE EXCEPTION 'Cross-fit start requires accepted backfill and READY covered TRAIN data'
            USING ERRCODE = '23514';
    END IF;
    FOREACH question IN ARRAY ARRAY['Q-019','Q-029','Q-030','Q-036','Q-039'] LOOP
        IF execution_record.question_readiness ->> question IS DISTINCT FROM 'READY'
           OR protocol_record.config_json #>> ARRAY['question_readiness', question]
                IS DISTINCT FROM 'READY' THEN
            RAISE EXCEPTION 'Cross-fit decision % is not READY', question
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    UPDATE strategy_training.training_cross_fit_executions
    SET state = 'RUNNING', started_at = clock_timestamp()
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_cross_fit_fold_execution(
    p_cross_fit_execution_id uuid, p_lease_token uuid, p_outer_fold_number integer,
    p_raw_train_start_at timestamptz, p_raw_train_end_at timestamptz,
    p_effective_train_start_at timestamptz, p_effective_train_end_at timestamptz,
    p_prediction_start_at timestamptz, p_prediction_end_at timestamptz,
    p_warmup_start_at timestamptz, p_purge_start_at timestamptz,
    p_purge_end_at timestamptz, p_embargo_start_at timestamptz,
    p_embargo_end_at timestamptz, p_model_version_id uuid,
    p_optimizer_run_id uuid, p_raw_training_sample_count bigint,
    p_effective_training_sample_count bigint, p_prediction_sample_count bigint,
    p_warmup_excluded_count bigint, p_purge_excluded_count bigint,
    p_embargo_excluded_count bigint, p_trial_budget integer,
    p_wall_clock_budget_seconds integer, p_repeat_count integer,
    p_random_seed bigint, p_fold_protocol_hash char(64)
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE fold_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF execution_record.state <> 'RUNNING'
       OR p_outer_fold_number <> 1 + (
           SELECT count(*) FROM strategy_training.training_cross_fit_fold_executions
           WHERE cross_fit_execution_id = p_cross_fit_execution_id
       )
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_optimizer_runs optimizer
           WHERE optimizer.optimizer_run_id = p_optimizer_run_id
             AND optimizer.experiment_id = execution_record.experiment_id
             AND optimizer.state = 'SUCCEEDED'
             AND optimizer.trial_budget = p_trial_budget
             AND optimizer.random_seed = p_random_seed
       )
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_model_versions model
           JOIN strategy_training.training_iterations iteration
             ON iteration.iteration_id = model.source_iteration_id
           WHERE model.model_version_id = p_model_version_id
             AND model.model_type = 'MODEL_A'
             AND iteration.experiment_id = execution_record.experiment_id
       ) THEN
        RAISE EXCEPTION 'fold fact requires sequential same-experiment from-scratch search'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_folds (
        cross_fit_fold_id, experiment_id, outer_fold_number,
        raw_train_start_at, raw_train_end_at, effective_train_start_at,
        effective_train_end_at, prediction_start_at, prediction_end_at,
        warmup_start_at, purge_start_at, purge_end_at,
        embargo_start_at, embargo_end_at, excluded_count,
        fold_model_version_id, fold_random_seed, inner_validation_count,
        status, qualification_report
    ) VALUES (
        fold_id, execution_record.experiment_id, p_outer_fold_number,
        p_raw_train_start_at, p_raw_train_end_at, p_effective_train_start_at,
        p_effective_train_end_at, p_prediction_start_at, p_prediction_end_at,
        p_warmup_start_at, p_purge_start_at, p_purge_end_at,
        p_embargo_start_at, p_embargo_end_at,
        p_warmup_excluded_count + p_purge_excluded_count + p_embargo_excluded_count,
        p_model_version_id, p_random_seed, 0, 'SUCCEEDED',
        jsonb_build_object('raw_training_sample_count', p_raw_training_sample_count,
            'effective_training_sample_count', p_effective_training_sample_count,
            'prediction_sample_count', p_prediction_sample_count)
    );
    INSERT INTO strategy_training.training_cross_fit_fold_searches (
        cross_fit_fold_id, inner_optimizer_run_id, training_entry_source,
        inner_validation_count, search_budget, random_seed
    ) VALUES (
        fold_id, p_optimizer_run_id, 'CROSS_FIT_MODEL_A_CANDIDATE',
        0, p_trial_budget, p_random_seed
    );
    INSERT INTO strategy_training.training_cross_fit_fold_executions (
        cross_fit_fold_id, cross_fit_execution_id, optimizer_run_id,
        raw_training_sample_count, effective_training_sample_count,
        prediction_sample_count, warmup_excluded_count, purge_excluded_count,
        embargo_excluded_count, trial_budget, wall_clock_budget_seconds,
        repeat_count, random_seed, from_scratch, inner_validation_count,
        fold_protocol_hash
    ) VALUES (
        fold_id, p_cross_fit_execution_id, p_optimizer_run_id,
        p_raw_training_sample_count, p_effective_training_sample_count,
        p_prediction_sample_count, p_warmup_excluded_count, p_purge_excluded_count,
        p_embargo_excluded_count, p_trial_budget, p_wall_clock_budget_seconds,
        p_repeat_count, p_random_seed, true, 0, p_fold_protocol_hash
    );
    RETURN fold_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_leased_cross_fit_entry_event(
    p_cross_fit_execution_id uuid, p_lease_token uuid, p_cross_fit_fold_id uuid,
    p_entry_event_id char(64), p_dataset_version_id uuid,
    p_generating_iteration_id uuid, p_instrument_id bigint, p_symbol text,
    p_signal_time timestamptz, p_entry_time timestamptz, p_direction text,
    p_trigger_score numeric, p_coverage_percent numeric,
    p_theoretical_signal_price numeric, p_entry_price numeric,
    p_pool_evaluation_id uuid, p_ticker_pool_rule_version_id uuid,
    p_factor_registry_version_id uuid, p_scan_parameters_version_id uuid,
    p_signal_payload_hash char(64)
)
RETURNS char(64)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_executions execution
        JOIN strategy_training.training_cross_fit_fold_executions fold_execution
          ON fold_execution.cross_fit_execution_id = execution.cross_fit_execution_id
         AND fold_execution.cross_fit_fold_id = p_cross_fit_fold_id
        JOIN strategy_training.training_cross_fit_folds fold
          ON fold.cross_fit_fold_id = fold_execution.cross_fit_fold_id
        JOIN strategy_training.training_iterations iteration
          ON iteration.iteration_id = p_generating_iteration_id
         AND iteration.experiment_id = execution.experiment_id
        WHERE execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND execution.state = 'RUNNING'
          AND execution.dataset_version_id = p_dataset_version_id
          AND p_signal_time >= fold.prediction_start_at
          AND p_signal_time < fold.prediction_end_at
          AND fold.status = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'candidate event is outside its leased outer-fold prediction'
            USING ERRCODE = '23514';
    END IF;
    RETURN strategy_training.create_cross_fit_entry_event(
        p_entry_event_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, p_symbol, 'CROSS_FIT_MODEL_A_CANDIDATE', 'GO_NO_GO',
        p_signal_time, p_entry_time, p_direction, p_trigger_score,
        p_coverage_percent, p_theoretical_signal_price, p_entry_price,
        p_pool_evaluation_id, p_ticker_pool_rule_version_id,
        p_factor_registry_version_id, p_scan_parameters_version_id,
        p_signal_payload_hash
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_cross_fit_fold_control_search(
    p_cross_fit_execution_id uuid, p_lease_token uuid,
    p_cross_fit_fold_id uuid, p_optimizer_run_id uuid,
    p_trial_budget integer, p_random_seed bigint
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE execution_experiment_id uuid;
DECLARE primary_kind text;
DECLARE control_kind text;
DECLARE primary_budget integer;
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT execution.experiment_id, primary_optimizer.optimizer_kind,
           fold_search.search_budget
    INTO STRICT execution_experiment_id, primary_kind, primary_budget
    FROM strategy_training.training_cross_fit_executions execution
    JOIN strategy_training.training_cross_fit_fold_executions fold_execution
      ON fold_execution.cross_fit_execution_id = execution.cross_fit_execution_id
     AND fold_execution.cross_fit_fold_id = p_cross_fit_fold_id
    JOIN strategy_training.training_optimizer_runs primary_optimizer
      ON primary_optimizer.optimizer_run_id = fold_execution.optimizer_run_id
    JOIN strategy_training.training_cross_fit_fold_searches fold_search
      ON fold_search.cross_fit_fold_id = fold_execution.cross_fit_fold_id
     AND fold_search.inner_optimizer_run_id = fold_execution.optimizer_run_id
    WHERE execution.cross_fit_execution_id = p_cross_fit_execution_id
      AND execution.state = 'RUNNING';
    SELECT optimizer_kind INTO STRICT control_kind
    FROM strategy_training.training_optimizer_runs
    WHERE optimizer_run_id = p_optimizer_run_id
      AND experiment_id = execution_experiment_id
      AND state = 'SUCCEEDED'
      AND trial_budget = p_trial_budget
      AND random_seed = p_random_seed;
    IF control_kind = primary_kind OR p_trial_budget <> primary_budget THEN
        RAISE EXCEPTION 'fold control must be the other same-budget optimizer'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_fold_searches (
        cross_fit_fold_id, inner_optimizer_run_id, training_entry_source,
        inner_validation_count, search_budget, random_seed
    ) VALUES (
        p_cross_fit_fold_id, p_optimizer_run_id,
        'CROSS_FIT_MODEL_A_CANDIDATE', 0, p_trial_budget, p_random_seed
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_cross_fit_power(
    p_cross_fit_execution_id uuid, p_lease_token uuid, p_effective_fold_count integer,
    p_effective_day_count integer, p_event_count bigint, p_corpus_hash char(64)
)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF execution_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'power can only be recorded for RUNNING Cross-fit'
            USING ERRCODE = '23514';
    END IF;
    IF p_effective_fold_count <> (
        SELECT count(*)
        FROM strategy_training.training_cross_fit_fold_executions fold_execution
        JOIN strategy_training.training_cross_fit_folds fold
          ON fold.cross_fit_fold_id = fold_execution.cross_fit_fold_id
        WHERE fold_execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND fold.status = 'SUCCEEDED'
          AND fold_execution.effective_training_sample_count > 0
          AND fold_execution.prediction_sample_count > 0
    ) THEN
        RAISE EXCEPTION 'effective fold count does not match persisted fold facts'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM strategy_training.training_cross_fit_fold_executions fold_execution
        JOIN strategy_training.training_cross_fit_fold_searches fold_search
          ON fold_search.cross_fit_fold_id = fold_execution.cross_fit_fold_id
        JOIN strategy_training.training_optimizer_runs optimizer
          ON optimizer.optimizer_run_id = fold_search.inner_optimizer_run_id
        WHERE fold_execution.cross_fit_execution_id = p_cross_fit_execution_id
        GROUP BY fold_execution.cross_fit_fold_id
        HAVING count(DISTINCT optimizer.optimizer_kind) <> 2
            OR min(fold_search.search_budget) <> max(fold_search.search_budget)
            OR bool_or(fold_search.inner_validation_count <> 0)
    ) OR EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_fold_executions fold_execution
        WHERE fold_execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND NOT EXISTS (
              SELECT 1 FROM strategy_training.training_cross_fit_fold_searches fold_search
              WHERE fold_search.cross_fit_fold_id = fold_execution.cross_fit_fold_id
          )
    ) THEN
        RAISE EXCEPTION 'every fold requires same-budget TPE and RANDOM searches'
            USING ERRCODE = '23514';
    END IF;
    IF p_effective_fold_count < execution_record.minimum_effective_folds
       OR p_effective_day_count < execution_record.minimum_effective_days
       OR p_event_count < execution_record.minimum_event_count THEN
        UPDATE strategy_training.training_cross_fit_executions
        SET state = 'INSUFFICIENT_POWER', failure_code = 'INSUFFICIENT_POWER',
            completed_at = clock_timestamp()
        WHERE cross_fit_execution_id = p_cross_fit_execution_id;
        RETURN 'INSUFFICIENT_POWER';
    END IF;
    INSERT INTO strategy_training.training_cross_fit_corpora (
        cross_fit_execution_id, source, corpus_use, event_count,
        effective_fold_count, effective_day_count, corpus_hash
    ) VALUES (
        p_cross_fit_execution_id, 'CROSS_FIT_MODEL_A_CANDIDATE', 'GO_NO_GO',
        p_event_count, p_effective_fold_count, p_effective_day_count, p_corpus_hash
    );
    INSERT INTO strategy_training.training_cross_fit_corpus_events (
        cross_fit_corpus_id, entry_event_id, declared_source, declared_use
    )
    SELECT corpus.cross_fit_corpus_id, event.entry_event_id,
           'CROSS_FIT_MODEL_A_CANDIDATE', 'GO_NO_GO'
    FROM strategy_training.training_cross_fit_corpora corpus
    JOIN strategy_training.training_entry_events event
      ON event.dataset_version_id = execution_record.dataset_version_id
     AND event.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
     AND event.entry_use = 'GO_NO_GO'
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = event.generating_iteration_id
     AND iteration.experiment_id = execution_record.experiment_id
    WHERE corpus.cross_fit_execution_id = p_cross_fit_execution_id
      AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE';
    IF (SELECT count(*) FROM strategy_training.training_cross_fit_corpus_events member
        JOIN strategy_training.training_cross_fit_corpora corpus
          ON corpus.cross_fit_corpus_id = member.cross_fit_corpus_id
        WHERE corpus.cross_fit_execution_id = p_cross_fit_execution_id
          AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE') <> p_event_count THEN
        RAISE EXCEPTION 'candidate corpus event count does not match persisted events'
            USING ERRCODE = '23514';
    END IF;
    IF p_corpus_hash <> (
        SELECT encode(public.digest(string_agg(member.entry_event_id, ''
            ORDER BY member.entry_event_id), 'sha256'), 'hex')
        FROM strategy_training.training_cross_fit_corpus_events member
        JOIN strategy_training.training_cross_fit_corpora corpus
          ON corpus.cross_fit_corpus_id = member.cross_fit_corpus_id
        WHERE corpus.cross_fit_execution_id = p_cross_fit_execution_id
          AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
    ) THEN
        RAISE EXCEPTION 'candidate corpus hash does not match persisted events'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_cross_fit_executions SET state = 'CANDIDATE_READY'
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    RETURN 'CANDIDATE_READY';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.apply_cross_fit_go_no_go(
    p_cross_fit_execution_id uuid, p_lease_token uuid, p_go_no_go_evaluation_id uuid
)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE gate_record strategy_training.training_go_no_go_evaluations%ROWTYPE;
DECLARE corpus_record strategy_training.training_cross_fit_corpora%ROWTYPE;
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT gate_record FROM strategy_training.training_go_no_go_evaluations
    WHERE go_no_go_evaluation_id = p_go_no_go_evaluation_id;
    SELECT * INTO STRICT corpus_record
    FROM strategy_training.training_cross_fit_corpora
    WHERE cross_fit_execution_id = p_cross_fit_execution_id
      AND source = 'CROSS_FIT_MODEL_A_CANDIDATE';
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_executions execution
        WHERE execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND execution.experiment_id = gate_record.experiment_id
          AND execution.state = 'CANDIDATE_READY'
          AND gate_record.temporary_only
          AND gate_record.created_at >= corpus_record.created_at
          AND gate_record.effective_fold_count = corpus_record.effective_fold_count
          AND gate_record.effective_day_count = corpus_record.effective_day_count
          AND gate_record.effective_fold_count = (
              SELECT count(DISTINCT metric.cross_fit_fold_id)
              FROM strategy_training.training_go_no_go_fold_metrics metric
              WHERE metric.go_no_go_evaluation_id = gate_record.go_no_go_evaluation_id
          )
          AND gate_record.effective_day_count = (
              SELECT count(DISTINCT metric.prediction_day)
              FROM strategy_training.training_go_no_go_fold_metrics metric
              WHERE metric.go_no_go_evaluation_id = gate_record.go_no_go_evaluation_id
          )
    ) THEN
        RAISE EXCEPTION 'go/no-go requires the execution candidate corpus'
            USING ERRCODE = '23514';
    END IF;
    IF gate_record.decision = 'PASS' THEN
        UPDATE strategy_training.training_cross_fit_executions
        SET state = 'GO_NO_GO_PASSED'
        WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    ELSE
        UPDATE strategy_training.training_cross_fit_executions
        SET state = CASE WHEN gate_record.decision = 'INSUFFICIENT_POWER'
                         THEN 'INSUFFICIENT_POWER' ELSE 'FAILED' END,
            failure_code = CASE WHEN gate_record.decision = 'INSUFFICIENT_POWER'
                                THEN 'INSUFFICIENT_POWER' ELSE 'GO_NO_GO_FAILED' END,
            completed_at = clock_timestamp()
        WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    END IF;
    RETURN gate_record.decision;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_cross_fit_go_no_go_metric(
    p_cross_fit_execution_id uuid, p_lease_token uuid,
    p_go_no_go_evaluation_id uuid, p_cross_fit_fold_id uuid,
    p_prediction_day date, p_symbol text, p_tpe_value numeric,
    p_random_value numeric
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_cross_fit_executions execution
        JOIN strategy_training.training_go_no_go_evaluations gate
          ON gate.experiment_id = execution.experiment_id
        JOIN strategy_training.training_cross_fit_fold_executions fold_execution
          ON fold_execution.cross_fit_execution_id = execution.cross_fit_execution_id
         AND fold_execution.cross_fit_fold_id = p_cross_fit_fold_id
        WHERE execution.cross_fit_execution_id = p_cross_fit_execution_id
          AND execution.state = 'CANDIDATE_READY'
          AND gate.go_no_go_evaluation_id = p_go_no_go_evaluation_id
          AND gate.temporary_only
    ) THEN
        RAISE EXCEPTION 'go/no-go metric is outside its leased execution'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_go_no_go_fold_metrics (
        go_no_go_evaluation_id, cross_fit_fold_id, prediction_day,
        symbol, tpe_value, random_value
    ) VALUES (
        p_go_no_go_evaluation_id, p_cross_fit_fold_id, p_prediction_day,
        upper(p_symbol), p_tpe_value, p_random_value
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_cross_fit_go_no_go(
    p_cross_fit_execution_id uuid, p_lease_token uuid,
    p_tpe_optimizer_run_id uuid, p_random_optimizer_run_id uuid,
    p_alpha numeric, p_minimum_effective_days integer,
    p_minimum_effective_folds integer, p_bootstrap_replicates integer,
    p_random_seed bigint, p_tpe_mean numeric, p_random_mean numeric,
    p_excess_mean numeric, p_p_value numeric, p_effective_day_count integer,
    p_effective_fold_count integer, p_decision text
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE execution_record strategy_training.training_cross_fit_executions%ROWTYPE;
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT * INTO STRICT execution_record
    FROM strategy_training.training_cross_fit_executions
    WHERE cross_fit_execution_id = p_cross_fit_execution_id FOR UPDATE;
    IF execution_record.state <> 'CANDIDATE_READY'
       OR NOT EXISTS (
           SELECT 1 FROM strategy_training.training_cross_fit_corpora corpus
           WHERE corpus.cross_fit_execution_id = p_cross_fit_execution_id
             AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
             AND corpus.effective_day_count = p_effective_day_count
             AND corpus.effective_fold_count = p_effective_fold_count
       ) THEN
        RAISE EXCEPTION 'go/no-go facts require this execution candidate corpus'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_go_no_go_evaluations (
        go_no_go_evaluation_id, experiment_id, candidate_source,
        tpe_optimizer_run_id, random_optimizer_run_id, alpha,
        minimum_effective_days, minimum_effective_folds, bootstrap_replicates,
        random_seed, tpe_mean, random_mean, excess_mean, p_value,
        effective_day_count, effective_fold_count, decision, temporary_only
    ) VALUES (
        new_id, execution_record.experiment_id, 'CROSS_FIT_MODEL_A_CANDIDATE',
        p_tpe_optimizer_run_id, p_random_optimizer_run_id, p_alpha,
        p_minimum_effective_days, p_minimum_effective_folds, p_bootstrap_replicates,
        p_random_seed, p_tpe_mean, p_random_mean, p_excess_mean, p_p_value,
        p_effective_day_count, p_effective_fold_count, p_decision, true
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.promote_cross_fit_corpus(
    p_cross_fit_execution_id uuid, p_lease_token uuid
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE candidate_record strategy_training.training_cross_fit_corpora%ROWTYPE;
DECLARE new_id uuid := gen_random_uuid();
BEGIN
    PERFORM strategy_training.assert_cross_fit_execution_lease(
        p_cross_fit_execution_id, p_lease_token
    );
    SELECT corpus.* INTO STRICT candidate_record
    FROM strategy_training.training_cross_fit_corpora corpus
    JOIN strategy_training.training_cross_fit_executions execution
      ON execution.cross_fit_execution_id = corpus.cross_fit_execution_id
    WHERE corpus.cross_fit_execution_id = p_cross_fit_execution_id
      AND corpus.source = 'CROSS_FIT_MODEL_A_CANDIDATE'
      AND execution.state = 'GO_NO_GO_PASSED' FOR UPDATE OF execution;
    INSERT INTO strategy_training.training_cross_fit_corpora (
        cross_fit_corpus_id, cross_fit_execution_id, source, corpus_use,
        source_corpus_id, event_count, effective_fold_count,
        effective_day_count, corpus_hash
    ) VALUES (
        new_id, p_cross_fit_execution_id, 'CROSS_FIT_MODEL_A', 'MODEL_B_TRAIN',
        candidate_record.cross_fit_corpus_id, candidate_record.event_count,
        candidate_record.effective_fold_count, candidate_record.effective_day_count,
        candidate_record.corpus_hash
    );
    INSERT INTO strategy_training.training_cross_fit_corpus_events (
        cross_fit_corpus_id, entry_event_id, declared_source, declared_use
    )
    SELECT new_id, member.entry_event_id, 'CROSS_FIT_MODEL_A', 'MODEL_B_TRAIN'
    FROM strategy_training.training_cross_fit_corpus_events member
    WHERE member.cross_fit_corpus_id = candidate_record.cross_fit_corpus_id;
    UPDATE strategy_training.training_cross_fit_executions
    SET state = 'FORMAL_CORPUS_READY', completed_at = clock_timestamp()
    WHERE cross_fit_execution_id = p_cross_fit_execution_id;
    RETURN new_id;
END
$$;

ALTER TABLE strategy_training.training_cross_fit_executions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_fold_executions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_corpora OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_corpus_events OWNER TO tb2_training_owner;
ALTER VIEW strategy_training.formal_model_b_cross_fit_entries OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_cross_fit_optimizer_links() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_cross_fit_corpus_event() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.assert_cross_fit_execution_lease(uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_cross_fit_execution(uuid, uuid, text, char(64), char(64), jsonb, integer, integer, bigint) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.claim_cross_fit_execution(uuid, text, integer) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.start_cross_fit_execution(uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_fold_execution(uuid, uuid, integer, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, uuid, uuid, bigint, bigint, bigint, bigint, bigint, bigint, integer, integer, integer, bigint, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_leased_cross_fit_entry_event(uuid, uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz, text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_fold_control_search(uuid, uuid, uuid, uuid, integer, bigint) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_power(uuid, uuid, integer, integer, bigint, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_go_no_go(uuid, uuid, uuid, uuid, numeric, integer, integer, integer, bigint, numeric, numeric, numeric, numeric, integer, integer, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_cross_fit_go_no_go_metric(uuid, uuid, uuid, uuid, date, text, numeric, numeric) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.apply_cross_fit_go_no_go(uuid, uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.promote_cross_fit_corpus(uuid, uuid) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_executions,
    strategy_training.training_cross_fit_fold_executions,
    strategy_training.training_cross_fit_corpora,
    strategy_training.training_cross_fit_corpus_events FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON strategy_training.training_cross_fit_folds,
    strategy_training.training_cross_fit_fold_searches,
    strategy_training.training_go_no_go_evaluations,
    strategy_training.training_go_no_go_fold_metrics FROM tb2_training_evaluator;
REVOKE EXECUTE ON FUNCTION strategy_training.create_cross_fit_entry_event(
    char(64), uuid, uuid, bigint, text, text, text, timestamptz, timestamptz,
    text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
) FROM tb2_training_evaluator;
GRANT SELECT ON strategy_training.training_cross_fit_executions,
    strategy_training.training_cross_fit_fold_executions,
    strategy_training.training_cross_fit_folds,
    strategy_training.training_cross_fit_fold_searches,
    strategy_training.training_go_no_go_evaluations,
    strategy_training.training_go_no_go_fold_metrics TO tb2_training_evaluator;
GRANT SELECT ON strategy_training.training_cross_fit_corpora,
    strategy_training.training_cross_fit_corpus_events,
    strategy_training.formal_model_b_cross_fit_entries TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.create_cross_fit_execution(uuid, uuid, text, char(64), char(64), jsonb, integer, integer, bigint),
    strategy_training.claim_cross_fit_execution(uuid, text, integer),
    strategy_training.start_cross_fit_execution(uuid, uuid),
    strategy_training.record_cross_fit_fold_execution(uuid, uuid, integer, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, uuid, uuid, bigint, bigint, bigint, bigint, bigint, bigint, integer, integer, integer, bigint, char(64)),
    strategy_training.create_leased_cross_fit_entry_event(uuid, uuid, uuid, char(64), uuid, uuid, bigint, text, timestamptz, timestamptz, text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)),
    strategy_training.record_cross_fit_fold_control_search(uuid, uuid, uuid, uuid, integer, bigint),
    strategy_training.record_cross_fit_power(uuid, uuid, integer, integer, bigint, char(64)),
    strategy_training.record_cross_fit_go_no_go(uuid, uuid, uuid, uuid, numeric, integer, integer, integer, bigint, numeric, numeric, numeric, numeric, integer, integer, text),
    strategy_training.record_cross_fit_go_no_go_metric(uuid, uuid, uuid, uuid, date, text, numeric, numeric),
    strategy_training.apply_cross_fit_go_no_go(uuid, uuid, uuid),
    strategy_training.promote_cross_fit_corpus(uuid, uuid) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '054_training_cross_fit_execution',
    encode(digest('auto_trade_v2_054_training_cross_fit_execution_v1', 'sha256'), 'hex'),
    'Add fail-closed M6 Cross-fit execution, power, corpus promotion and formal model-B gates'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
