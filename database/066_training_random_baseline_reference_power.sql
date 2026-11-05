\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_random_baseline_reference_sets (
    reference_set_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id           uuid NOT NULL REFERENCES strategy_training.training_dataset_versions,
    reference_iteration_id       uuid NOT NULL UNIQUE REFERENCES strategy_training.training_iterations,
    source_config_version_id     uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    reference_signal_set_hash    char(64) NOT NULL CHECK (reference_signal_set_hash ~ '^[0-9a-f]{64}$'),
    reference_candidate_set_hash char(64) NOT NULL CHECK (reference_candidate_set_hash ~ '^[0-9a-f]{64}$'),
    signal_count                 integer NOT NULL CHECK (signal_count > 0),
    candidate_count              integer NOT NULL CHECK (candidate_count > 0),
    time_bucket_hours            integer NOT NULL CHECK (time_bucket_hours > 0 AND 24 % time_bucket_hours = 0),
    exclusion_window_seconds     integer NOT NULL CHECK (exclusion_window_seconds > 0),
    maximum_frame_candidates     integer NOT NULL CHECK (maximum_frame_candidates > 0),
    random_seed                  bigint NOT NULL,
    status                       varchar(16) NOT NULL CHECK (status = 'READY'),
    approval_basis               text NOT NULL CHECK (
        approval_basis = 'FEASIBILITY_AND_COVERAGE_ONLY_NO_OUTCOME_METRICS'
    ),
    created_by                   text NOT NULL CHECK (btrim(created_by) <> ''),
    created_at                   timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (dataset_version_id, reference_signal_set_hash, reference_candidate_set_hash)
);

CREATE TABLE strategy_training.training_random_baseline_reference_support (
    reference_set_id         uuid NOT NULL REFERENCES strategy_training.training_random_baseline_reference_sets,
    instrument_id            bigint NOT NULL REFERENCES core.instruments,
    pool_identity            text NOT NULL,
    time_bucket              text NOT NULL,
    volatility_bucket        text NOT NULL,
    liquidity_bucket         text NOT NULL,
    btc_regime               text NOT NULL,
    eligible_candidate_count integer NOT NULL CHECK (eligible_candidate_count > 0),
    candidate_ids            jsonb NOT NULL CHECK (
        jsonb_typeof(candidate_ids) = 'array'
        AND jsonb_array_length(candidate_ids) = eligible_candidate_count
    ),
    candidate_frame_hash     char(64) NOT NULL CHECK (candidate_frame_hash ~ '^[0-9a-f]{64}$'),
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (
        reference_set_id, instrument_id, pool_identity, time_bucket,
        volatility_bucket, liquidity_bucket, btc_regime
    )
);

CREATE TABLE strategy_training.training_random_baseline_frame_exclusions (
    entry_event_id                    char(64) PRIMARY KEY REFERENCES strategy_training.training_entry_events,
    random_baseline_config_version_id uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    reference_set_id                  uuid NOT NULL REFERENCES strategy_training.training_random_baseline_reference_sets,
    reason_code                       varchar(64) NOT NULL CHECK (reason_code = 'RANDOM_BASELINE_FRAME_INSUFFICIENT'),
    observed_frame_size               integer NOT NULL CHECK (observed_frame_size >= 0),
    minimum_frame_size                integer NOT NULL CHECK (minimum_frame_size > 0),
    matching_stratum                  jsonb NOT NULL CHECK (jsonb_typeof(matching_stratum) = 'object'),
    evidence_hash                     char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at                        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (observed_frame_size < minimum_frame_size)
);

CREATE TABLE strategy_training.training_random_baseline_coverage_reports (
    iteration_id                  uuid PRIMARY KEY REFERENCES strategy_training.training_iterations,
    random_baseline_config_version_id uuid NOT NULL REFERENCES strategy_training.training_config_versions,
    reference_set_id              uuid NOT NULL REFERENCES strategy_training.training_random_baseline_reference_sets,
    total_signal_count            integer NOT NULL CHECK (total_signal_count > 0),
    evaluable_signal_count        integer NOT NULL CHECK (evaluable_signal_count >= 0),
    excluded_signal_count         integer NOT NULL CHECK (excluded_signal_count >= 0),
    overall_coverage_ratio        numeric(18,12) NOT NULL CHECK (overall_coverage_ratio BETWEEN 0 AND 1),
    effective_day_count           integer NOT NULL CHECK (effective_day_count >= 0),
    valid_fold_count              integer NOT NULL CHECK (valid_fold_count >= 0),
    power_status                  varchar(24) NOT NULL CHECK (power_status IN ('READY', 'INSUFFICIENT_POWER')),
    fold_metrics                  jsonb NOT NULL CHECK (jsonb_typeof(fold_metrics) = 'array'),
    distribution_comparison      jsonb NOT NULL CHECK (jsonb_typeof(distribution_comparison) = 'object'),
    report_hash                   char(64) NOT NULL CHECK (report_hash ~ '^[0-9a-f]{64}$'),
    created_at                    timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (total_signal_count = evaluable_signal_count + excluded_signal_count)
);

ALTER TABLE strategy_training.training_random_entry_baselines
    ADD COLUMN reference_set_id uuid
        REFERENCES strategy_training.training_random_baseline_reference_sets,
    ADD COLUMN sampling_mode varchar(40) NOT NULL DEFAULT 'SEEDED_SAMPLE_WITHOUT_REPLACEMENT'
        CHECK (sampling_mode IN ('SEEDED_SAMPLE_WITHOUT_REPLACEMENT', 'FULL_FRAME_CENSUS'));

CREATE INDEX ix_training_entry_events_iteration_instrument_signal_time
ON strategy_training.training_entry_events (
    generating_iteration_id, instrument_id, signal_time
)
WHERE status = 'COMPLETE';

CREATE OR REPLACE FUNCTION strategy_training.seal_training_random_baseline_reference_set(
    p_reference_iteration_id uuid,
    p_time_bucket_hours integer,
    p_exclusion_window_seconds integer,
    p_maximum_frame_candidates integer,
    p_random_seed bigint,
    p_created_by text
)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    iteration_record strategy_training.training_iterations%ROWTYPE;
    batch_record strategy_training.training_iteration_entry_batches%ROWTYPE;
    reference_set_id_value uuid := gen_random_uuid();
    dataset_version_id_value uuid;
    source_config_version_id_value uuid;
    signal_hash char(64);
    candidate_hash char(64);
    signal_count_value integer;
    candidate_count_value integer;
BEGIN
    IF p_time_bucket_hours <= 0 OR 24 % p_time_bucket_hours <> 0
       OR p_exclusion_window_seconds <= 0 OR p_maximum_frame_candidates <= 0
       OR btrim(p_created_by) = '' THEN
        RAISE EXCEPTION 'invalid frozen random-baseline reference policy' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT iteration_record
    FROM strategy_training.training_iterations WHERE iteration_id = p_reference_iteration_id;
    SELECT * INTO STRICT batch_record
    FROM strategy_training.training_iteration_entry_batches WHERE iteration_id = p_reference_iteration_id;
    IF iteration_record.candidate_source <> 'FIXED_BASELINE' OR NOT EXISTS (
        SELECT 1 FROM strategy_training.training_tasks task
        WHERE task.iteration_id = p_reference_iteration_id
          AND task.task_type = 'MODEL_A_CANDIDATE_SCAN' AND task.state = 'SUCCEEDED'
    ) THEN
        RAISE EXCEPTION 'reference support requires a completed fixed-baseline scan' USING ERRCODE = '23514';
    END IF;
    SELECT min(entry.dataset_version_id::text)::uuid, count(*)::integer,
           encode(public.digest(string_agg(entry.entry_event_id::text, E'\n' ORDER BY entry.entry_event_id), 'sha256'), 'hex')
    INTO dataset_version_id_value, signal_count_value, signal_hash
    FROM strategy_training.training_entry_events entry
    WHERE entry.generating_iteration_id = p_reference_iteration_id AND entry.status = 'COMPLETE';
    SELECT min(candidate.random_baseline_config_version_id::text)::uuid, count(*)::integer,
           encode(public.digest(string_agg(candidate.candidate_id::text, E'\n' ORDER BY candidate.candidate_id), 'sha256'), 'hex')
    INTO source_config_version_id_value, candidate_count_value, candidate_hash
    FROM strategy_training.training_random_baseline_candidates candidate
    WHERE candidate.generating_iteration_id = p_reference_iteration_id;
    IF signal_count_value = 0 OR candidate_count_value = 0
       OR dataset_version_id_value IS NULL OR source_config_version_id_value IS NULL THEN
        RAISE EXCEPTION 'reference scan has no immutable signal/candidate corpus' USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_random_baseline_reference_sets (
        reference_set_id, dataset_version_id, reference_iteration_id,
        source_config_version_id, reference_signal_set_hash,
        reference_candidate_set_hash, signal_count, candidate_count,
        time_bucket_hours, exclusion_window_seconds, maximum_frame_candidates,
        random_seed, status, approval_basis, created_by
    ) VALUES (
        reference_set_id_value, dataset_version_id_value, p_reference_iteration_id,
        source_config_version_id_value, signal_hash, candidate_hash,
        signal_count_value, candidate_count_value, p_time_bucket_hours,
        p_exclusion_window_seconds, p_maximum_frame_candidates, p_random_seed,
        'READY', 'FEASIBILITY_AND_COVERAGE_ONLY_NO_OUTCOME_METRICS', p_created_by
    );

    INSERT INTO strategy_training.training_random_baseline_reference_support (
        reference_set_id, instrument_id, pool_identity, time_bucket,
        volatility_bucket, liquidity_bucket, btc_regime,
        eligible_candidate_count, candidate_ids, candidate_frame_hash
    )
    WITH eligible AS MATERIALIZED (
        SELECT candidate.*,
               'UTC-' || lpad(((extract(hour FROM candidate.observed_at AT TIME ZONE 'UTC')::integer
                    / p_time_bucket_hours) * p_time_bucket_hours)::text, 2, '0') || '-' ||
               lpad((((extract(hour FROM candidate.observed_at AT TIME ZONE 'UTC')::integer
                    / p_time_bucket_hours) * p_time_bucket_hours) + p_time_bucket_hours - 1)::text, 2, '0') AS governed_time_bucket,
               encode(public.digest(format('%s:%s', p_random_seed, candidate.candidate_id), 'sha256'), 'hex') AS seeded_rank
        FROM strategy_training.training_random_baseline_candidates candidate
        WHERE candidate.generating_iteration_id = p_reference_iteration_id
          AND NOT EXISTS (
              SELECT 1 FROM strategy_training.training_entry_events signal
              WHERE signal.generating_iteration_id = p_reference_iteration_id
                AND signal.instrument_id = candidate.instrument_id
                AND signal.status = 'COMPLETE'
                AND abs(extract(epoch FROM candidate.observed_at - signal.signal_time)) <= p_exclusion_window_seconds
          )
    ), ranked AS (
        SELECT eligible.*, row_number() OVER (
            PARTITION BY instrument_id, pool_identity, governed_time_bucket,
                         volatility_bucket, liquidity_bucket, btc_regime
            ORDER BY seeded_rank, candidate_id
        ) AS frame_rank
        FROM eligible
    ), capped AS (
        SELECT * FROM ranked WHERE frame_rank <= p_maximum_frame_candidates
    )
    SELECT reference_set_id_value, instrument_id, pool_identity, governed_time_bucket,
           volatility_bucket, liquidity_bucket, btc_regime, count(*)::integer,
           jsonb_agg(to_jsonb(candidate_id::text) ORDER BY candidate_id),
           encode(public.digest(string_agg(candidate_id::text || '|' ||
               to_char(observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               E'\n' ORDER BY candidate_id), 'sha256'), 'hex')
    FROM capped
    GROUP BY instrument_id, pool_identity, governed_time_bucket,
             volatility_bucket, liquidity_bucket, btc_regime;
    RETURN reference_set_id_value;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_v012()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE reference_record strategy_training.training_random_baseline_reference_sets%ROWTYPE;
BEGIN
    IF NEW.config_type <> 'RANDOM_BASELINE' OR NEW.status <> 'READY'
       OR NEW.semver::text <> '0.1.2' THEN RETURN NEW; END IF;
    IF NEW.config_json ->> 'candidate_selection_method' <> 'SEEDED_SHA256_PER_STRATUM'
       OR NEW.config_json ->> 'insufficient_frame_policy' <> 'EXCLUDE_AND_REPORT'
       OR NEW.config_json ->> 'approval_basis' <> 'FEASIBILITY_AND_COVERAGE_ONLY_NO_OUTCOME_METRICS'
       OR (NEW.config_json ->> 'time_bucket_hours')::integer <> 24
       OR (NEW.config_json ->> 'sample_count')::integer <> 5
       OR (NEW.config_json ->> 'minimum_frame_size')::integer <> 5
       OR (NEW.config_json ->> 'maximum_frame_candidates')::integer <> 500
       OR (NEW.config_json ->> 'exclusion_window_seconds')::integer <> 86400
       OR (NEW.config_json ->> 'random_seed')::bigint <> 42
       OR (NEW.config_json ->> 'minimum_overall_coverage_ratio')::numeric <> 0.5
       OR (NEW.config_json ->> 'minimum_fold_coverage_ratio')::numeric <> 0.4
       OR (NEW.config_json ->> 'minimum_evaluable_events_per_fold')::integer <> 100
       OR (NEW.config_json ->> 'minimum_valid_fold_count')::integer <> 15
       OR (NEW.config_json ->> 'minimum_effective_day_count')::integer <> 30
       OR (NEW.config_json ->> 'fold_duration_days')::integer <> 2
       OR jsonb_typeof(NEW.config_json -> 'reference_set_id') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'RANDOM_BASELINE 0.1.2 differs from the approved frozen policy' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT reference_record
    FROM strategy_training.training_random_baseline_reference_sets
    WHERE reference_set_id = (NEW.config_json ->> 'reference_set_id')::uuid AND status = 'READY';
    IF reference_record.time_bucket_hours <> 24
       OR reference_record.exclusion_window_seconds <> 86400
       OR reference_record.maximum_frame_candidates <> 500
       OR reference_record.random_seed <> 42 THEN
        RAISE EXCEPTION 'RANDOM_BASELINE config/reference policy mismatch' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_random_baseline_v012
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_random_baseline_v012();

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_random_config(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (random_baseline_config_version_id uuid, config_json jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    RETURN QUERY
    WITH context AS (
        SELECT * FROM strategy_training.training_model_a_candidate_scan_context(
            p_task_id, p_lease_token
        )
    )
    SELECT config.config_version_id, config.config_json
    FROM context
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = context.iteration_id
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'RANDOM_BASELINE'
     AND config.semver::text = '0.1.2'
     AND config.status = 'READY'
     AND config.config_json ? 'reference_set_id';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RANDOM_BASELINE 0.1.0/0.1.1 are retained for audit only; candidate scan requires READY 0.1.2'
            USING ERRCODE = '23514';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_baseline_evaluation_context(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64)
)
RETURNS TABLE (
    random_baseline_config_version_id uuid, sample_count integer,
    minimum_frame_size integer, exclusion_window_seconds integer, random_seed bigint,
    instrument_id bigint, pool_identity text, time_bucket text,
    volatility_bucket text, liquidity_bucket text, btc_regime text,
    signal_times timestamptz[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'random-baseline context requires its active evaluator lease' USING ERRCODE = '40001';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
         AND binding.config_type = 'RANDOM_BASELINE'
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
         AND config.semver::text = '0.1.2' AND config.status = 'READY'
         AND config.config_json ? 'reference_set_id'
        WHERE iteration.iteration_id = task_record.iteration_id
    ) THEN
        RAISE EXCEPTION 'RANDOM_BASELINE 0.1.0/0.1.1 are retained for audit only; evaluation requires READY 0.1.2'
            USING ERRCODE = '23514';
    END IF;
    RETURN QUERY
    SELECT config.config_version_id, (config.config_json ->> 'sample_count')::integer,
           (config.config_json ->> 'minimum_frame_size')::integer,
           (config.config_json ->> 'exclusion_window_seconds')::integer,
           (config.config_json ->> 'random_seed')::bigint, entry.instrument_id,
           stratum.pool_identity,
           'UTC-' || lpad(((extract(hour FROM entry.signal_time AT TIME ZONE 'UTC')::integer
                / (config.config_json ->> 'time_bucket_hours')::integer)
                * (config.config_json ->> 'time_bucket_hours')::integer)::text, 2, '0') || '-' ||
           lpad((((extract(hour FROM entry.signal_time AT TIME ZONE 'UTC')::integer
                / (config.config_json ->> 'time_bucket_hours')::integer)
                * (config.config_json ->> 'time_bucket_hours')::integer)
                + (config.config_json ->> 'time_bucket_hours')::integer - 1)::text, 2, '0'),
           stratum.volatility_bucket, stratum.liquidity_bucket, stratum.btc_regime,
           ARRAY(SELECT signal.signal_time
                 FROM strategy_training.training_random_baseline_reference_sets reference_set
                 JOIN strategy_training.training_entry_events signal
                   ON signal.generating_iteration_id = reference_set.reference_iteration_id
                  AND signal.instrument_id = entry.instrument_id AND signal.status = 'COMPLETE'
                 WHERE reference_set.reference_set_id = (config.config_json ->> 'reference_set_id')::uuid
                 ORDER BY signal.signal_time)
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_random_baseline_signal_strata stratum USING (entry_event_id)
    JOIN strategy_training.training_iterations iteration ON iteration.iteration_id = entry.generating_iteration_id
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id AND config.status = 'READY'
    WHERE entry.entry_event_id = p_entry_event_id
      AND entry.generating_iteration_id = task_record.iteration_id AND entry.status = 'COMPLETE';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_baseline_candidate_frame(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64)
)
RETURNS TABLE (
    candidate_id char(64), observed_at timestamptz, instrument_id bigint,
    pool_identity text, time_bucket text, volatility_bucket text,
    liquidity_bucket text, btc_regime text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    WITH context AS MATERIALIZED (
        SELECT * FROM strategy_training.training_random_baseline_evaluation_context(
            p_task_id, p_lease_token, p_entry_event_id
        )
    ), config AS (
        SELECT version.config_json FROM context
        JOIN strategy_training.training_config_versions version
          ON version.config_version_id = context.random_baseline_config_version_id
    ), support AS (
        SELECT frame.* FROM context CROSS JOIN config
        JOIN strategy_training.training_random_baseline_reference_support frame
          ON frame.reference_set_id = (config.config_json ->> 'reference_set_id')::uuid
         AND frame.instrument_id = context.instrument_id
         AND frame.pool_identity = context.pool_identity
         AND frame.time_bucket = context.time_bucket
         AND frame.volatility_bucket = context.volatility_bucket
         AND frame.liquidity_bucket = context.liquidity_bucket
         AND frame.btc_regime = context.btc_regime
    )
    SELECT candidate.candidate_id, candidate.observed_at, candidate.instrument_id,
           support.pool_identity, support.time_bucket, support.volatility_bucket,
           support.liquidity_bucket, support.btc_regime
    FROM support
    CROSS JOIN LATERAL jsonb_array_elements_text(support.candidate_ids) selected(candidate_id)
    JOIN strategy_training.training_random_baseline_candidates candidate
      ON candidate.candidate_id = selected.candidate_id::char(64)
    ORDER BY candidate.candidate_id
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_candidate_outcome_context(
    p_task_id uuid, p_lease_token uuid, p_matched_entry_event_id char(64),
    p_candidate_id char(64)
)
RETURNS TABLE (
    partition text, partition_start_at timestamptz, partition_end_at timestamptz,
    entry_time timestamptz, entry_price numeric, direction text,
    label_window_end_at timestamptz, interval_seconds integer,
    holding_rule_version_id uuid
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core
AS $$
DECLARE candidate_record strategy_training.training_random_baseline_candidates%ROWTYPE;
        dataset_record strategy_training.training_dataset_versions%ROWTYPE;
        entry_price_value numeric;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_random_baseline_candidate_frame(
            p_task_id, p_lease_token, p_matched_entry_event_id
        ) frame WHERE frame.candidate_id = p_candidate_id
    ) THEN
        RAISE EXCEPTION 'candidate is outside the frozen reference support' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT candidate_record
    FROM strategy_training.training_random_baseline_candidates WHERE candidate_id = p_candidate_id;
    SELECT * INTO STRICT dataset_record FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = candidate_record.dataset_version_id;
    SELECT bar.open_price INTO STRICT entry_price_value FROM market.klines bar
    WHERE bar.instrument_id = candidate_record.instrument_id AND bar.price_type = 'TRADE'
      AND bar.interval_seconds = dataset_record.interval_seconds
      AND bar.open_time = candidate_record.entry_time AND bar.is_closed
      AND bar.quality_status = 'VALID' AND bar.effective_at <= dataset_record.source_as_of_at
    ORDER BY bar.revision_no DESC, bar.effective_at DESC, bar.collected_at DESC LIMIT 1;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR candidate_record.entry_time + dataset_record.label_horizon_duration > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'random outcome requires a complete READY TRAIN label window' USING ERRCODE = '23514';
    END IF;
    RETURN QUERY SELECT dataset_record.partition::text, dataset_record.partition_start_at,
        dataset_record.partition_end_at, candidate_record.entry_time, entry_price_value,
        candidate_record.direction::text,
        candidate_record.entry_time + dataset_record.label_horizon_duration,
        dataset_record.interval_seconds, dataset_record.holding_rule_version_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_trusted_frame()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE entry_record strategy_training.training_entry_events%ROWTYPE;
        stratum_record strategy_training.training_random_baseline_signal_strata%ROWTYPE;
        config_json_value jsonb; sample_count_value integer; random_seed_value bigint;
        reference_set_id_value uuid; expected_stratum jsonb; expected_frame_size integer;
        expected_frame_hash char(64); expected_selected_ids jsonb;
BEGIN
    SELECT * INTO STRICT entry_record FROM strategy_training.training_entry_events
    WHERE entry_event_id = NEW.matched_entry_event_id;
    SELECT * INTO STRICT stratum_record FROM strategy_training.training_random_baseline_signal_strata
    WHERE entry_event_id = NEW.matched_entry_event_id;
    SELECT config_json INTO STRICT config_json_value FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.random_baseline_config_version_id
      AND config_type = 'RANDOM_BASELINE' AND status = 'READY';
    sample_count_value := (config_json_value ->> 'sample_count')::integer;
    random_seed_value := (config_json_value ->> 'random_seed')::bigint;
    reference_set_id_value := (config_json_value ->> 'reference_set_id')::uuid;
    expected_stratum := jsonb_build_object(
        'instrument_id', entry_record.instrument_id,
        'pool_identity', stratum_record.pool_identity,
        'time_bucket', 'UTC-00-23',
        'volatility_bucket', stratum_record.volatility_bucket,
        'liquidity_bucket', stratum_record.liquidity_bucket,
        'btc_regime', stratum_record.btc_regime
    );
    WITH support AS (
        SELECT frame.* FROM strategy_training.training_random_baseline_reference_support frame
        WHERE frame.reference_set_id = reference_set_id_value
          AND frame.instrument_id = entry_record.instrument_id
          AND frame.pool_identity = stratum_record.pool_identity
          AND frame.time_bucket = 'UTC-00-23'
          AND frame.volatility_bucket = stratum_record.volatility_bucket
          AND frame.liquidity_bucket = stratum_record.liquidity_bucket
          AND frame.btc_regime = stratum_record.btc_regime
    ), candidates AS (
        SELECT candidate.* FROM support
        CROSS JOIN LATERAL jsonb_array_elements_text(support.candidate_ids) item(candidate_id)
        JOIN strategy_training.training_random_baseline_candidates candidate
          ON candidate.candidate_id = item.candidate_id::char(64)
    ), ranked AS (
        SELECT candidates.*, encode(public.digest(format('%s:%s:%s', random_seed_value,
               NEW.matched_entry_event_id, candidate_id), 'sha256'), 'hex') AS sampling_rank
        FROM candidates
    ), selected AS (
        SELECT * FROM ranked ORDER BY sampling_rank, candidate_id LIMIT sample_count_value
    )
    SELECT (SELECT count(*) FROM candidates),
           (SELECT encode(public.digest(string_agg(candidate_id::text || '|' ||
               to_char(observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               E'\n' ORDER BY candidate_id), 'sha256'), 'hex') FROM candidates),
           (SELECT jsonb_agg(to_jsonb(candidate_id::text) ORDER BY sampling_rank, candidate_id) FROM selected)
    INTO expected_frame_size, expected_frame_hash, expected_selected_ids;
    IF expected_frame_size = 0 OR NEW.matching_stratum <> expected_stratum
       OR NEW.random_seed <> random_seed_value OR NEW.sampling_frame_size <> expected_frame_size
       OR NEW.overlap_excluded_count <> 0 OR NEW.sampling_frame_hash <> expected_frame_hash
       OR NEW.selected_candidate_ids <> expected_selected_ids THEN
        RAISE EXCEPTION 'random-baseline result does not match frozen reference support' USING ERRCODE = '23514';
    END IF;
    NEW.reference_set_id := reference_set_id_value;
    NEW.sampling_mode := CASE WHEN expected_frame_size = sample_count_value
        THEN 'FULL_FRAME_CENSUS' ELSE 'SEEDED_SAMPLE_WITHOUT_REPLACEMENT' END;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_random_baseline_frame_exclusion(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64)
)
RETURNS char(64)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE context_record record; frame_size_value integer; config_json_value jsonb;
        stratum_value jsonb; evidence_hash_value char(64);
BEGIN
    SELECT * INTO STRICT context_record FROM strategy_training.training_random_baseline_evaluation_context(
        p_task_id, p_lease_token, p_entry_event_id
    );
    SELECT count(*)::integer INTO frame_size_value
    FROM strategy_training.training_random_baseline_candidate_frame(p_task_id, p_lease_token, p_entry_event_id);
    IF frame_size_value >= context_record.minimum_frame_size THEN
        RAISE EXCEPTION 'sufficient random-baseline frame cannot be excluded' USING ERRCODE = '23514';
    END IF;
    SELECT config_json INTO STRICT config_json_value FROM strategy_training.training_config_versions
    WHERE config_version_id = context_record.random_baseline_config_version_id;
    stratum_value := jsonb_build_object(
        'instrument_id', context_record.instrument_id, 'pool_identity', context_record.pool_identity,
        'time_bucket', context_record.time_bucket, 'volatility_bucket', context_record.volatility_bucket,
        'liquidity_bucket', context_record.liquidity_bucket, 'btc_regime', context_record.btc_regime
    );
    evidence_hash_value := encode(public.digest(jsonb_build_object(
        'entry_event_id', p_entry_event_id, 'frame_size', frame_size_value,
        'minimum_frame_size', context_record.minimum_frame_size,
        'reason_code', 'RANDOM_BASELINE_FRAME_INSUFFICIENT', 'stratum', stratum_value
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_random_baseline_frame_exclusions (
        entry_event_id, random_baseline_config_version_id, reference_set_id,
        reason_code, observed_frame_size, minimum_frame_size, matching_stratum, evidence_hash
    ) VALUES (
        p_entry_event_id, context_record.random_baseline_config_version_id,
        (config_json_value ->> 'reference_set_id')::uuid,
        'RANDOM_BASELINE_FRAME_INSUFFICIENT', frame_size_value,
        context_record.minimum_frame_size, stratum_value, evidence_hash_value
    ) ON CONFLICT (entry_event_id) DO NOTHING;
    RETURN evidence_hash_value;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_random_baseline_coverage(
    p_task_id uuid, p_lease_token uuid
)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE; config_record record;
        total_value integer; evaluable_value integer; excluded_value integer;
        days_value integer; valid_folds_value integer; coverage_value numeric;
        folds_value jsonb; distributions_value jsonb; status_value text; hash_value char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'coverage finalization requires its active evaluator lease' USING ERRCODE = '40001';
    END IF;
    SELECT config.config_version_id, config.config_json INTO STRICT config_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config ON config.config_version_id = binding.config_version_id
    WHERE iteration.iteration_id = task_record.iteration_id;
    WITH entries AS MATERIALIZED (
        SELECT entry.entry_event_id, entry.signal_time, entry.symbol,
               stratum.volatility_bucket, stratum.liquidity_bucket,
               baseline.matched_entry_event_id IS NOT NULL AS evaluable
        FROM strategy_training.training_entry_events entry
        JOIN strategy_training.training_random_baseline_signal_strata stratum USING (entry_event_id)
        LEFT JOIN strategy_training.training_random_entry_baselines baseline
          ON baseline.matched_entry_event_id = entry.entry_event_id
        LEFT JOIN strategy_training.training_random_baseline_frame_exclusions exclusion
          ON exclusion.entry_event_id = entry.entry_event_id
        WHERE entry.generating_iteration_id = task_record.iteration_id AND entry.status = 'COMPLETE'
          AND (baseline.matched_entry_event_id IS NOT NULL OR exclusion.entry_event_id IS NOT NULL)
    ), anchor AS (SELECT min(signal_time::date) AS first_day FROM entries), folded AS (
        SELECT floor((signal_time::date - first_day)::numeric /
                     (config_record.config_json ->> 'fold_duration_days')::integer)::integer AS fold_no,
               count(*)::integer AS total_count,
               count(*) FILTER (WHERE evaluable)::integer AS evaluable_count
        FROM entries CROSS JOIN anchor GROUP BY 1
    )
    SELECT count(*)::integer, count(*) FILTER (WHERE evaluable)::integer,
           count(*) FILTER (WHERE NOT evaluable)::integer,
           count(DISTINCT signal_time::date) FILTER (WHERE evaluable)::integer,
           COALESCE((SELECT count(*) FROM folded
             WHERE evaluable_count >= (config_record.config_json ->> 'minimum_evaluable_events_per_fold')::integer
               AND evaluable_count::numeric / total_count >=
                   (config_record.config_json ->> 'minimum_fold_coverage_ratio')::numeric), 0)::integer,
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
               'fold_no', fold_no, 'total_count', total_count,
               'evaluable_count', evaluable_count,
               'coverage_ratio', evaluable_count::numeric / total_count,
               'valid', evaluable_count >= (config_record.config_json ->> 'minimum_evaluable_events_per_fold')::integer
                    AND evaluable_count::numeric / total_count >=
                        (config_record.config_json ->> 'minimum_fold_coverage_ratio')::numeric
             ) ORDER BY fold_no) FROM folded), '[]'::jsonb),
           jsonb_build_object(
             'by_date', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT signal_time::date::text AS key, jsonb_build_object(
                     'date', signal_time::date, 'evaluable', count(*) FILTER (WHERE evaluable),
                     'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data FROM entries GROUP BY 1) grouped),
             'by_symbol', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT symbol AS key, jsonb_build_object('symbol', symbol,
                     'evaluable', count(*) FILTER (WHERE evaluable), 'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY symbol) grouped),
             'by_volatility_bucket', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT volatility_bucket AS key, jsonb_build_object('volatility_bucket', volatility_bucket,
                     'evaluable', count(*) FILTER (WHERE evaluable), 'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY volatility_bucket) grouped),
             'by_liquidity_bucket', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT liquidity_bucket AS key, jsonb_build_object('liquidity_bucket', liquidity_bucket,
                     'evaluable', count(*) FILTER (WHERE evaluable), 'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY liquidity_bucket) grouped)
           )
    INTO total_value, evaluable_value, excluded_value, days_value,
         valid_folds_value, folds_value, distributions_value FROM entries;
    IF total_value = 0 OR total_value <> (
        SELECT entry_event_count FROM strategy_training.training_iteration_entry_batches
        WHERE iteration_id = task_record.iteration_id
    ) THEN
        RAISE EXCEPTION 'coverage cannot finalize before every frozen entry is classified' USING ERRCODE = '55000';
    END IF;
    coverage_value := evaluable_value::numeric / total_value;
    status_value := CASE WHEN coverage_value >= (config_record.config_json ->> 'minimum_overall_coverage_ratio')::numeric
        AND days_value >= (config_record.config_json ->> 'minimum_effective_day_count')::integer
        AND valid_folds_value >= (config_record.config_json ->> 'minimum_valid_fold_count')::integer
        THEN 'READY' ELSE 'INSUFFICIENT_POWER' END;
    hash_value := encode(public.digest(jsonb_build_object(
        'distribution_comparison', distributions_value, 'effective_day_count', days_value,
        'evaluable_signal_count', evaluable_value, 'excluded_signal_count', excluded_value,
        'fold_metrics', folds_value, 'iteration_id', task_record.iteration_id,
        'overall_coverage_ratio', coverage_value, 'power_status', status_value,
        'reference_set_id', config_record.config_json ->> 'reference_set_id',
        'total_signal_count', total_value, 'valid_fold_count', valid_folds_value
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_random_baseline_coverage_reports (
        iteration_id, random_baseline_config_version_id, reference_set_id,
        total_signal_count, evaluable_signal_count, excluded_signal_count,
        overall_coverage_ratio, effective_day_count, valid_fold_count,
        power_status, fold_metrics, distribution_comparison, report_hash
    ) VALUES (
        task_record.iteration_id, config_record.config_version_id,
        (config_record.config_json ->> 'reference_set_id')::uuid,
        total_value, evaluable_value, excluded_value, coverage_value,
        days_value, valid_folds_value, status_value, folds_value,
        distributions_value, hash_value
    ) ON CONFLICT (iteration_id) DO NOTHING;
    RETURN status_value;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.advance_training_model_a_l0_tasks()
RETURNS TABLE (iteration_id uuid, action text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, public
AS $$
DECLARE candidate record; l0_task strategy_training.training_tasks%ROWTYPE;
BEGIN
    FOR candidate IN
        SELECT iteration.iteration_id, iteration.experiment_id,
               evaluation.task_id AS parent_task_id,
               coverage.power_status, coverage.report_hash
        FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_tasks evaluation
          ON evaluation.iteration_id = iteration.iteration_id
         AND evaluation.task_type = 'MODEL_A_EVALUATION'
         AND evaluation.state = 'SUCCEEDED'
        JOIN strategy_training.training_random_baseline_coverage_reports coverage
          ON coverage.iteration_id = iteration.iteration_id
        LEFT JOIN strategy_training.training_iteration_evidence_l0 evidence
          ON evidence.iteration_id = iteration.iteration_id
        WHERE iteration.state = 'RUNNING' AND evidence.iteration_id IS NULL
        ORDER BY iteration.created_at, iteration.iteration_id
    LOOP
        iteration_id := candidate.iteration_id;
        IF candidate.power_status = 'INSUFFICIENT_POWER' THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'CANCELLED',
                'INSUFFICIENT_POWER', candidate.report_hash,
                NULL, 'training-orchestrator',
                'random-baseline coverage gate has insufficient power; no model pass/fail decision',
                gen_random_uuid()
            );
            action := 'ITERATION_INSUFFICIENT_POWER'; RETURN NEXT; CONTINUE;
        END IF;
        SELECT * INTO l0_task FROM strategy_training.training_tasks task
        WHERE task.iteration_id = candidate.iteration_id
          AND task.task_type = 'MODEL_A_L0_AGGREGATION';
        IF NOT FOUND THEN
            PERFORM strategy_training.enqueue_training_task(
                candidate.experiment_id, candidate.iteration_id, NULL,
                candidate.parent_task_id, 'MODEL_A_L0_AGGREGATION', 'EVALUATOR',
                encode(public.digest(concat_ws('|', candidate.iteration_id::text,
                    'MODEL_A_L0_AGGREGATION'), 'sha256'), 'hex'),
                jsonb_build_object('task_type', 'MODEL_A_L0_AGGREGATION',
                    'payload_version', 1), 25
            );
            action := 'L0_ENQUEUED'; RETURN NEXT; CONTINUE;
        END IF;
        IF l0_task.state IN ('FAILED', 'CANCELLED') THEN
            PERFORM strategy_training.transition_training_iteration(
                candidate.iteration_id, 'RUNNING', 'FAILED',
                COALESCE(l0_task.failure_code, 'MODEL_A_L0_FAILED'),
                l0_task.result_hash, NULL, 'training-orchestrator',
                'model-A L0 task failed', gen_random_uuid()
            );
            action := 'ITERATION_FAILED'; RETURN NEXT; CONTINUE;
        END IF;
        action := 'WAITING_L0'; RETURN NEXT;
    END LOOP;
END
$$;

CREATE TRIGGER trg_training_random_baseline_reference_sets_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_reference_sets
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
CREATE TRIGGER trg_training_random_baseline_reference_support_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_reference_support
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
CREATE TRIGGER trg_training_random_baseline_frame_exclusions_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_frame_exclusions
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();
CREATE TRIGGER trg_training_random_baseline_coverage_reports_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_coverage_reports
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_random_baseline_reference_sets OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_random_baseline_reference_support OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_random_baseline_frame_exclusions OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_random_baseline_coverage_reports OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.seal_training_random_baseline_reference_set(uuid, integer, integer, integer, bigint, text) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_random_baseline_v012() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_random_config(uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_baseline_evaluation_context(uuid, uuid, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_baseline_candidate_frame(uuid, uuid, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_candidate_outcome_context(uuid, uuid, char(64), char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_random_baseline_trusted_frame() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_random_baseline_frame_exclusion(uuid, uuid, char(64)) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.finalize_training_random_baseline_coverage(uuid, uuid) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.advance_training_model_a_l0_tasks() OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_random_baseline_reference_sets,
    strategy_training.training_random_baseline_reference_support,
    strategy_training.training_random_baseline_frame_exclusions,
    strategy_training.training_random_baseline_coverage_reports FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.seal_training_random_baseline_reference_set(uuid, integer, integer, integer, bigint, text),
    strategy_training.training_random_baseline_evaluation_context(uuid, uuid, char(64)),
    strategy_training.training_random_baseline_candidate_frame(uuid, uuid, char(64)),
    strategy_training.training_random_candidate_outcome_context(uuid, uuid, char(64), char(64)),
    strategy_training.record_training_random_baseline_frame_exclusion(uuid, uuid, char(64)),
    strategy_training.finalize_training_random_baseline_coverage(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_model_a_candidate_scan_random_config(uuid, uuid) FROM PUBLIC;
GRANT SELECT ON strategy_training.training_random_baseline_reference_sets,
    strategy_training.training_random_baseline_reference_support,
    strategy_training.training_random_baseline_frame_exclusions,
    strategy_training.training_random_baseline_coverage_reports
TO tb2_training_rw, tb2_training_orchestrator, tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.seal_training_random_baseline_reference_set(
    uuid, integer, integer, integer, bigint, text
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.training_model_a_candidate_scan_random_config(
    uuid, uuid
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.training_random_baseline_evaluation_context(uuid, uuid, char(64)),
    strategy_training.training_random_baseline_candidate_frame(uuid, uuid, char(64)),
    strategy_training.training_random_candidate_outcome_context(uuid, uuid, char(64), char(64)),
    strategy_training.record_training_random_baseline_frame_exclusion(uuid, uuid, char(64)),
    strategy_training.finalize_training_random_baseline_coverage(uuid, uuid) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.advance_training_model_a_l0_tasks()
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '066_training_random_baseline_reference_power',
    encode(public.digest('auto_trade_v2_066_training_random_baseline_reference_power_v1', 'sha256'), 'hex'),
    'Freeze shared random-baseline support and classify coverage insufficiency without outcome-driven selection'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
