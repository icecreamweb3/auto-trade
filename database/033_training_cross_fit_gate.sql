\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_entry_events
    ADD COLUMN entry_use varchar(32) NOT NULL DEFAULT 'MODEL_B_PROTOTYPE';

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
    ADD CONSTRAINT training_entry_events_entry_use_check CHECK (entry_use IN (
        'MODEL_B_PROTOTYPE', 'GO_NO_GO', 'MODEL_B_TRAIN', 'VALIDATION',
        'END_TO_END_TEST', 'ORACLE_BENCHMARK'
    ));

ALTER TABLE strategy_training.training_entry_events
    DROP CONSTRAINT IF EXISTS training_entry_events_source_use_check;
ALTER TABLE strategy_training.training_entry_events
    ADD CONSTRAINT training_entry_events_source_use_check CHECK (
        (source = 'FIXED_BASELINE_MODEL_A' AND entry_use = 'MODEL_B_PROTOTYPE')
        OR (source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND entry_use = 'GO_NO_GO')
        OR (source = 'CROSS_FIT_MODEL_A' AND entry_use = 'MODEL_B_TRAIN')
        OR (source = 'LOCKED_MODEL_A_VALIDATION_SIGNAL' AND entry_use = 'VALIDATION')
        OR (source = 'MODEL_A_SIGNAL' AND entry_use = 'END_TO_END_TEST')
        OR (source IN ('ORACLE_ENTRY_BENCHMARK', 'ADVERSE_OR_RANGE_CONTROL', 'IN_SAMPLE_MODEL_A')
            AND entry_use = 'ORACLE_BENCHMARK')
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
        RAISE EXCEPTION 'entry signal/entry time is outside the governed interval'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.state, iteration.candidate_source, experiment.dataset_version_id
    INTO STRICT iteration_state, iteration_source, experiment_dataset_id
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = NEW.generating_iteration_id;
    IF iteration_state <> 'RUNNING' OR experiment_dataset_id <> NEW.dataset_version_id
       OR (NEW.source = 'FIXED_BASELINE_MODEL_A' AND iteration_source <> 'FIXED_BASELINE')
       OR (NEW.source <> 'FIXED_BASELINE_MODEL_A'
           AND iteration_source NOT IN ('OPTUNA_TPE', 'RANDOM_SEARCH', 'MANUAL_APPROVED')) THEN
        RAISE EXCEPTION 'entry generator is not the running governed TRAIN iteration'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT pool_record
    FROM strategy_training.training_historical_pool_evaluations
    WHERE pool_evaluation_id = NEW.pool_evaluation_id;
    IF pool_record.dataset_version_id <> NEW.dataset_version_id
       OR pool_record.instrument_id <> NEW.instrument_id
       OR pool_record.symbol <> NEW.symbol
       OR NOT pool_record.is_eligible
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
    SELECT config_type, status
    INTO STRICT scan_config_type, scan_config_status
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

CREATE TABLE strategy_training.training_cross_fit_folds (
    cross_fit_fold_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id              uuid NOT NULL REFERENCES strategy_training.training_experiments,
    outer_fold_number          integer NOT NULL CHECK (outer_fold_number > 0),
    raw_train_start_at         timestamptz NOT NULL,
    raw_train_end_at           timestamptz NOT NULL,
    effective_train_start_at   timestamptz NOT NULL,
    effective_train_end_at     timestamptz NOT NULL,
    prediction_start_at        timestamptz NOT NULL,
    prediction_end_at          timestamptz NOT NULL,
    warmup_start_at            timestamptz NOT NULL,
    purge_start_at             timestamptz NOT NULL,
    purge_end_at               timestamptz NOT NULL,
    embargo_start_at           timestamptz NOT NULL,
    embargo_end_at             timestamptz NOT NULL,
    excluded_count             bigint NOT NULL DEFAULT 0 CHECK (excluded_count >= 0),
    fold_model_version_id      uuid,
    fold_random_seed           bigint NOT NULL,
    inner_validation_count     integer NOT NULL DEFAULT 0 CHECK (inner_validation_count = 0),
    status                     varchar(24) NOT NULL DEFAULT 'PLANNED'
                               CHECK (status IN ('PLANNED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'INSUFFICIENT_POWER')),
    qualification_report       jsonb NOT NULL DEFAULT '{}'::jsonb,
    failure_reason             text,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (raw_train_start_at < raw_train_end_at),
    CHECK (effective_train_start_at < effective_train_end_at),
    CHECK (prediction_start_at < prediction_end_at),
    CHECK (raw_train_start_at <= effective_train_start_at),
    CHECK (effective_train_end_at <= purge_start_at),
    CHECK (purge_start_at <= purge_end_at AND purge_end_at <= embargo_start_at),
    CHECK (embargo_start_at <= embargo_end_at AND embargo_end_at <= prediction_start_at),
    CHECK (jsonb_typeof(qualification_report) = 'object'),
    CHECK ((status IN ('FAILED', 'INSUFFICIENT_POWER')) = (failure_reason IS NOT NULL))
);

CREATE UNIQUE INDEX ux_training_cross_fit_fold_number
ON strategy_training.training_cross_fit_folds (experiment_id, outer_fold_number);

CREATE TABLE strategy_training.training_cross_fit_fold_searches (
    cross_fit_fold_id          uuid NOT NULL REFERENCES strategy_training.training_cross_fit_folds,
    inner_optimizer_run_id    uuid NOT NULL REFERENCES strategy_training.training_optimizer_runs,
    training_entry_source     varchar(48) NOT NULL DEFAULT 'CROSS_FIT_MODEL_A_CANDIDATE',
    inner_validation_count    integer NOT NULL DEFAULT 0 CHECK (inner_validation_count = 0),
    search_budget              integer NOT NULL CHECK (search_budget > 0),
    random_seed                bigint NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (cross_fit_fold_id, inner_optimizer_run_id),
    CHECK (training_entry_source IN ('CROSS_FIT_MODEL_A_CANDIDATE', 'CROSS_FIT_MODEL_A'))
);

CREATE TABLE strategy_training.training_go_no_go_evaluations (
    go_no_go_evaluation_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id              uuid NOT NULL REFERENCES strategy_training.training_experiments,
    candidate_source           varchar(48) NOT NULL DEFAULT 'CROSS_FIT_MODEL_A_CANDIDATE',
    tpe_optimizer_run_id       uuid NOT NULL REFERENCES strategy_training.training_optimizer_runs,
    random_optimizer_run_id    uuid NOT NULL REFERENCES strategy_training.training_optimizer_runs,
    alpha                      numeric(18,12) NOT NULL CHECK (alpha > 0 AND alpha < 1),
    minimum_effective_days     integer NOT NULL CHECK (minimum_effective_days > 0),
    minimum_effective_folds    integer NOT NULL CHECK (minimum_effective_folds > 0),
    bootstrap_replicates       integer NOT NULL CHECK (bootstrap_replicates > 0),
    random_seed                bigint NOT NULL,
    tpe_mean                   numeric NOT NULL,
    random_mean                numeric NOT NULL,
    excess_mean                numeric NOT NULL,
    p_value                    numeric NOT NULL CHECK (p_value >= 0 AND p_value <= 1),
    effective_day_count        integer NOT NULL CHECK (effective_day_count >= 0),
    effective_fold_count       integer NOT NULL CHECK (effective_fold_count >= 0),
    decision                   varchar(24) NOT NULL CHECK (decision IN ('PASS', 'FAIL', 'INSUFFICIENT_POWER')),
    temporary_only             boolean NOT NULL DEFAULT true,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (candidate_source = 'CROSS_FIT_MODEL_A_CANDIDATE'),
    CHECK (decision = 'INSUFFICIENT_POWER' OR effective_day_count >= minimum_effective_days),
    CHECK (decision = 'INSUFFICIENT_POWER' OR effective_fold_count >= minimum_effective_folds)
);

CREATE TABLE strategy_training.training_go_no_go_fold_metrics (
    go_no_go_evaluation_id     uuid NOT NULL REFERENCES strategy_training.training_go_no_go_evaluations,
    cross_fit_fold_id          uuid NOT NULL REFERENCES strategy_training.training_cross_fit_folds,
    prediction_day             date NOT NULL,
    symbol                     text NOT NULL,
    tpe_value                  numeric NOT NULL,
    random_value               numeric NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (go_no_go_evaluation_id, cross_fit_fold_id, prediction_day, symbol),
    CHECK (btrim(symbol) <> '' AND symbol = upper(symbol))
);

CREATE OR REPLACE FUNCTION strategy_training.create_cross_fit_entry_event(
    p_entry_event_id char(64), p_dataset_version_id uuid,
    p_generating_iteration_id uuid, p_instrument_id bigint, p_symbol text,
    p_source text, p_entry_use text, p_signal_time timestamptz,
    p_entry_time timestamptz, p_direction text, p_trigger_score numeric,
    p_coverage_percent numeric, p_theoretical_signal_price numeric,
    p_entry_price numeric, p_pool_evaluation_id uuid,
    p_ticker_pool_rule_version_id uuid, p_factor_registry_version_id uuid,
    p_scan_parameters_version_id uuid, p_signal_payload_hash char(64)
)
RETURNS char(64)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
BEGIN
    IF p_source NOT IN ('CROSS_FIT_MODEL_A_CANDIDATE', 'CROSS_FIT_MODEL_A')
       OR p_entry_use NOT IN ('GO_NO_GO', 'MODEL_B_TRAIN') THEN
        RAISE EXCEPTION 'cross-fit entry source/use pair is not allowed' USING ERRCODE = '23514';
    END IF;
    IF (p_source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND p_entry_use <> 'GO_NO_GO')
       OR (p_source = 'CROSS_FIT_MODEL_A' AND p_entry_use <> 'MODEL_B_TRAIN') THEN
        RAISE EXCEPTION 'cross-fit candidate source is restricted to its governed use'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_entry_events (
        entry_event_id, dataset_version_id, generating_iteration_id,
        instrument_id, symbol, source, entry_use, signal_time, entry_time, direction,
        trigger_score, coverage_percent, theoretical_signal_price, entry_price,
        pool_evaluation_id, ticker_pool_rule_version_id, factor_registry_version_id,
        scan_parameters_version_id, signal_payload_hash
    ) VALUES (
        p_entry_event_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, upper(p_symbol), p_source, p_entry_use, p_signal_time,
        p_entry_time, p_direction, p_trigger_score, p_coverage_percent,
        p_theoretical_signal_price, p_entry_price, p_pool_evaluation_id,
        p_ticker_pool_rule_version_id, p_factor_registry_version_id,
        p_scan_parameters_version_id, p_signal_payload_hash
    );
    RETURN p_entry_event_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_cross_fit_entry_use()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.source = 'CROSS_FIT_MODEL_A_CANDIDATE' AND NEW.entry_use <> 'GO_NO_GO' THEN
        RAISE EXCEPTION 'temporary Cross-fit candidate events are gate-only' USING ERRCODE = '23514';
    END IF;
    IF NEW.source = 'CROSS_FIT_MODEL_A' AND NEW.entry_use <> 'MODEL_B_TRAIN' THEN
        RAISE EXCEPTION 'formal Cross-fit events are MODEL_B_TRAIN-only' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_entry_event_cross_fit_use
BEFORE INSERT OR UPDATE ON strategy_training.training_entry_events
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_cross_fit_entry_use();

ALTER TABLE strategy_training.training_cross_fit_folds OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_cross_fit_fold_searches OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_go_no_go_evaluations OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_go_no_go_fold_metrics OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_cross_fit_entry_use() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_cross_fit_entry_event(
    char(64), uuid, uuid, bigint, text, text, text, timestamptz, timestamptz,
    text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_cross_fit_folds,
    strategy_training.training_cross_fit_fold_searches,
    strategy_training.training_go_no_go_evaluations,
    strategy_training.training_go_no_go_fold_metrics FROM PUBLIC;
GRANT SELECT, INSERT ON strategy_training.training_cross_fit_folds,
    strategy_training.training_cross_fit_fold_searches,
    strategy_training.training_go_no_go_evaluations,
    strategy_training.training_go_no_go_fold_metrics TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.create_cross_fit_entry_event(
    char(64), uuid, uuid, bigint, text, text, text, timestamptz, timestamptz,
    text, numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '033_training_cross_fit_gate',
    encode(digest('auto_trade_v2_033_training_cross_fit_gate_v1', 'sha256'), 'hex'),
    'Add Cross-fit fold facts, temporary go-no-go evidence and source-use guards'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
