\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_entry_events (
    entry_event_id                 char(64) PRIMARY KEY,
    dataset_version_id             uuid NOT NULL
                                   REFERENCES strategy_training.training_dataset_versions,
    generating_iteration_id        uuid NOT NULL
                                   REFERENCES strategy_training.training_iterations,
    instrument_id                  bigint NOT NULL REFERENCES core.instruments,
    symbol                         text NOT NULL,
    source                         varchar(48) NOT NULL
                                   CHECK (source IN ('FIXED_BASELINE_MODEL_A')),
    signal_time                    timestamptz NOT NULL,
    entry_time                     timestamptz NOT NULL,
    direction                      varchar(8) NOT NULL CHECK (direction IN ('LONG', 'SHORT')),
    trigger_score                  numeric(18, 8) NOT NULL,
    coverage_percent               numeric(18, 8) NOT NULL
                                   CHECK (coverage_percent BETWEEN 0 AND 100),
    theoretical_signal_price       numeric NOT NULL
                                   CHECK (theoretical_signal_price > 0),
    entry_price                    numeric NOT NULL CHECK (entry_price > 0),
    pool_evaluation_id             uuid NOT NULL
                                   REFERENCES strategy_training.training_historical_pool_evaluations,
    ticker_pool_rule_version_id    uuid NOT NULL
                                   REFERENCES strategy_training.training_config_versions,
    factor_registry_version_id     uuid NOT NULL
                                   REFERENCES strategy_training.training_config_versions,
    scan_parameters_version_id     uuid NOT NULL
                                   REFERENCES strategy_training.training_config_versions,
    signal_payload_hash            char(64) NOT NULL,
    status                         varchar(16) NOT NULL DEFAULT 'BUILDING'
                                   CHECK (status IN ('BUILDING', 'COMPLETE', 'INVALID')),
    created_at                     timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at                   timestamptz,
    invalid_reason                 text,
    CHECK (btrim(symbol) <> '' AND symbol = upper(symbol)),
    CHECK (entry_time > signal_time),
    CHECK (signal_payload_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (status = 'BUILDING' AND completed_at IS NULL AND invalid_reason IS NULL)
        OR (status = 'COMPLETE' AND completed_at IS NOT NULL AND invalid_reason IS NULL)
        OR (status = 'INVALID' AND completed_at IS NOT NULL
                               AND invalid_reason IS NOT NULL
                               AND btrim(invalid_reason) <> '')
    ),
    UNIQUE (
        dataset_version_id, generating_iteration_id, symbol,
        signal_time, entry_time, direction
    )
);

CREATE INDEX ix_training_entry_events_dataset_time
ON strategy_training.training_entry_events (
    dataset_version_id, signal_time, symbol, status
);

CREATE TABLE strategy_training.training_feature_snapshots (
    feature_snapshot_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_event_id             char(64) NOT NULL
                               REFERENCES strategy_training.training_entry_events,
    factor_registry_version_id uuid NOT NULL
                               REFERENCES strategy_training.training_config_versions,
    factor_name                text NOT NULL,
    passed                     boolean NOT NULL,
    available                  boolean NOT NULL,
    value_json                 jsonb,
    threshold                  text NOT NULL,
    reason                     text,
    metrics_json               jsonb NOT NULL,
    score                      numeric(18, 8) NOT NULL CHECK (score >= 0),
    weight                     numeric(18, 8) NOT NULL CHECK (weight >= 0),
    contribution               numeric(18, 8) NOT NULL CHECK (contribution >= 0),
    input_fingerprint          char(64) NOT NULL,
    snapshot_hash              char(64) NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(factor_name) <> ''),
    CHECK (btrim(threshold) <> ''),
    CHECK (available OR value_json IS NULL),
    CHECK (available OR (reason IS NOT NULL AND btrim(reason) <> '')),
    CHECK (jsonb_typeof(metrics_json) = 'object'),
    CHECK (input_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (snapshot_hash ~ '^[0-9a-f]{64}$'),
    UNIQUE (entry_event_id, factor_name)
);

CREATE OR REPLACE FUNCTION strategy_training.compute_training_entry_event_id(
    p_dataset_version_id uuid,
    p_generating_iteration_id uuid,
    p_symbol text,
    p_signal_time timestamptz,
    p_entry_time timestamptz,
    p_direction text
)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT encode(public.digest(
        format(
            '{"dataset_version_id":"%s","direction":"%s","entry_time":"%s","generating_version_id":"%s","signal_time":"%s","symbol":"%s"}',
            p_dataset_version_id::text,
            p_direction,
            to_char(p_entry_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            p_generating_iteration_id::text,
            to_char(p_signal_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            upper(p_symbol)
        ),
        'sha256'
    ), 'hex')::char(64)
$$;

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
    WHERE dataset_version_id = NEW.dataset_version_id
    FOR SHARE;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN' THEN
        RAISE EXCEPTION 'model-A discovery entries require a READY TRAIN dataset'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.signal_time < dataset_record.eligible_start_at
       OR NEW.signal_time >= dataset_record.eligible_end_at
       OR NEW.entry_time <> NEW.signal_time
            + make_interval(secs => dataset_record.interval_seconds) THEN
        RAISE EXCEPTION 'entry signal/entry time is outside the governed interval'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.entry_event_id <> strategy_training.compute_training_entry_event_id(
        NEW.dataset_version_id, NEW.generating_iteration_id, NEW.symbol,
        NEW.signal_time, NEW.entry_time, NEW.direction
    ) THEN
        RAISE EXCEPTION 'entry_event_id does not match its deterministic identity'
            USING ERRCODE = '23514';
    END IF;

    SELECT iteration.state, iteration.candidate_source, experiment.dataset_version_id
    INTO STRICT iteration_state, iteration_source, experiment_dataset_id
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = NEW.generating_iteration_id;
    IF iteration_state <> 'RUNNING' OR iteration_source <> 'FIXED_BASELINE'
       OR experiment_dataset_id <> NEW.dataset_version_id
       OR NEW.source <> 'FIXED_BASELINE_MODEL_A' THEN
        RAISE EXCEPTION 'entry generator is not the running fixed TRAIN baseline'
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
        SELECT 1
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
        WHERE iteration.iteration_id = NEW.generating_iteration_id
          AND binding.config_type = 'FACTOR_REGISTRY'
          AND binding.config_version_id = NEW.factor_registry_version_id
    ) OR NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_iterations iteration
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

CREATE OR REPLACE FUNCTION strategy_training.guard_training_entry_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'training entry events cannot be deleted' USING ERRCODE = '55000';
    END IF;
    IF OLD.status <> 'BUILDING' THEN
        RAISE EXCEPTION '% entry event is immutable', OLD.status USING ERRCODE = '55000';
    END IF;
    IF NEW.status NOT IN ('COMPLETE', 'INVALID')
       OR (to_jsonb(NEW) - ARRAY['status', 'completed_at', 'invalid_reason'])
          <> (to_jsonb(OLD) - ARRAY['status', 'completed_at', 'invalid_reason']) THEN
        RAISE EXCEPTION 'entry event permits only terminal status transition'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_feature_snapshot_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    entry_status text;
    entry_registry_id uuid;
    registry_json jsonb;
BEGIN
    SELECT status, factor_registry_version_id
    INTO STRICT entry_status, entry_registry_id
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = NEW.entry_event_id
    FOR UPDATE;
    IF entry_status <> 'BUILDING' OR NEW.factor_registry_version_id <> entry_registry_id THEN
        RAISE EXCEPTION 'feature snapshot requires its BUILDING entry registry'
            USING ERRCODE = '23514';
    END IF;
    SELECT config_json INTO STRICT registry_json
    FROM strategy_training.training_config_versions
    WHERE config_version_id = entry_registry_id AND status = 'READY';
    IF NOT (registry_json -> 'factors' ? NEW.factor_name) THEN
        RAISE EXCEPTION 'factor % is absent from the READY registry', NEW.factor_name
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.create_training_entry_event(
    p_entry_event_id char(64),
    p_dataset_version_id uuid,
    p_generating_iteration_id uuid,
    p_instrument_id bigint,
    p_symbol text,
    p_signal_time timestamptz,
    p_entry_time timestamptz,
    p_direction text,
    p_trigger_score numeric,
    p_coverage_percent numeric,
    p_theoretical_signal_price numeric,
    p_entry_price numeric,
    p_pool_evaluation_id uuid,
    p_ticker_pool_rule_version_id uuid,
    p_factor_registry_version_id uuid,
    p_scan_parameters_version_id uuid,
    p_signal_payload_hash char(64)
)
RETURNS char(64)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
BEGIN
    INSERT INTO strategy_training.training_entry_events (
        entry_event_id, dataset_version_id, generating_iteration_id,
        instrument_id, symbol, source, signal_time, entry_time, direction,
        trigger_score, coverage_percent, theoretical_signal_price,
        entry_price, pool_evaluation_id,
        ticker_pool_rule_version_id, factor_registry_version_id,
        scan_parameters_version_id, signal_payload_hash
    ) VALUES (
        p_entry_event_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, upper(p_symbol), 'FIXED_BASELINE_MODEL_A',
        p_signal_time, p_entry_time, p_direction, p_trigger_score,
        p_coverage_percent, p_theoretical_signal_price,
        p_entry_price, p_pool_evaluation_id,
        p_ticker_pool_rule_version_id, p_factor_registry_version_id,
        p_scan_parameters_version_id, p_signal_payload_hash
    );
    RETURN p_entry_event_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_feature_snapshot(
    p_entry_event_id char(64),
    p_factor_registry_version_id uuid,
    p_factor_name text,
    p_passed boolean,
    p_available boolean,
    p_value_json jsonb,
    p_threshold text,
    p_reason text,
    p_metrics_json jsonb,
    p_score numeric,
    p_weight numeric,
    p_contribution numeric,
    p_input_fingerprint char(64)
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    computed_hash char(64);
BEGIN
    computed_hash := encode(public.digest(jsonb_build_object(
        'entry_event_id', p_entry_event_id,
        'factor_name', p_factor_name,
        'passed', p_passed,
        'available', p_available,
        'value', p_value_json,
        'threshold', p_threshold,
        'reason', p_reason,
        'metrics', p_metrics_json,
        'score', p_score,
        'weight', p_weight,
        'contribution', p_contribution,
        'input_fingerprint', p_input_fingerprint
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_feature_snapshots (
        feature_snapshot_id, entry_event_id, factor_registry_version_id,
        factor_name, passed, available, value_json, threshold, reason,
        metrics_json, score, weight, contribution, input_fingerprint, snapshot_hash
    ) VALUES (
        new_id, p_entry_event_id, p_factor_registry_version_id,
        p_factor_name, p_passed, p_available, p_value_json, p_threshold, p_reason,
        p_metrics_json, p_score, p_weight, p_contribution,
        p_input_fingerprint, computed_hash
    );
    RETURN new_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_entry_event(
    p_entry_event_id char(64)
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    entry_record strategy_training.training_entry_events%ROWTYPE;
    registry_factors jsonb;
BEGIN
    SELECT * INTO STRICT entry_record
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id
    FOR UPDATE;
    IF entry_record.status <> 'BUILDING' THEN
        RAISE EXCEPTION 'entry event can finalize only from BUILDING'
            USING ERRCODE = '55000';
    END IF;
    SELECT config_json -> 'factors' INTO STRICT registry_factors
    FROM strategy_training.training_config_versions
    WHERE config_version_id = entry_record.factor_registry_version_id
      AND status = 'READY';
    IF EXISTS (
        SELECT value
        FROM jsonb_array_elements_text(registry_factors) AS registry_factor(value)
        EXCEPT
        SELECT factor_name FROM strategy_training.training_feature_snapshots
        WHERE entry_event_id = p_entry_event_id
    ) OR EXISTS (
        SELECT factor_name FROM strategy_training.training_feature_snapshots
        WHERE entry_event_id = p_entry_event_id
        EXCEPT
        SELECT value
        FROM jsonb_array_elements_text(registry_factors) AS registry_factor(value)
    ) THEN
        RAISE EXCEPTION 'entry event factor snapshots do not exactly match its registry'
            USING ERRCODE = '23514';
    END IF;
    UPDATE strategy_training.training_entry_events
    SET status = 'COMPLETE', completed_at = clock_timestamp()
    WHERE entry_event_id = p_entry_event_id;
END
$$;

CREATE TRIGGER trg_training_entry_event_insert_guard
BEFORE INSERT ON strategy_training.training_entry_events
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_entry_event_insert();

CREATE TRIGGER trg_training_entry_event_mutation_guard
BEFORE UPDATE OR DELETE ON strategy_training.training_entry_events
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_entry_event_mutation();

CREATE TRIGGER trg_training_feature_snapshot_insert_guard
BEFORE INSERT ON strategy_training.training_feature_snapshots
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_feature_snapshot_insert();

CREATE TRIGGER trg_training_feature_snapshot_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_feature_snapshots
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_entry_events OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_feature_snapshots OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.compute_training_entry_event_id(
    uuid, uuid, text, timestamptz, timestamptz, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_entry_event_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_entry_event_mutation()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_feature_snapshot_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.create_training_entry_event(
    char(64), uuid, uuid, bigint, text, timestamptz, timestamptz, text,
    numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_feature_snapshot(
    char(64), uuid, text, boolean, boolean, jsonb, text, text, jsonb,
    numeric, numeric, numeric, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_entry_event(char(64))
OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON strategy_training.training_entry_events,
    strategy_training.training_feature_snapshots
TO tb2_training_rw, tb2_training_evaluator;

GRANT EXECUTE ON FUNCTION
    strategy_training.create_training_entry_event(
        char(64), uuid, uuid, bigint, text, timestamptz, timestamptz, text,
        numeric, numeric, numeric, numeric, uuid, uuid, uuid, uuid, char(64)
    ),
    strategy_training.record_training_feature_snapshot(
        char(64), uuid, text, boolean, boolean, jsonb, text, text, jsonb,
        numeric, numeric, numeric, char(64)
    ),
    strategy_training.finalize_training_entry_event(char(64))
TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '026_training_model_a_features',
    encode(digest('auto_trade_v2_026_training_model_a_features_v1', 'sha256'), 'hex'),
    'Add governed fixed model-A entry events and complete factor snapshots'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
