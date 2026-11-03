\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_random_baseline_signal_strata (
    entry_event_id                    char(64) PRIMARY KEY
                                      REFERENCES strategy_training.training_entry_events,
    random_baseline_config_version_id uuid NOT NULL
                                      REFERENCES strategy_training.training_config_versions,
    pool_identity                     text NOT NULL,
    time_bucket                       text NOT NULL,
    volatility_bucket                 text NOT NULL,
    liquidity_bucket                  text NOT NULL,
    btc_regime                        text NOT NULL,
    volatility_window_start_at        timestamptz NOT NULL,
    liquidity_window_start_at         timestamptz NOT NULL,
    btc_regime_window_start_at        timestamptz NOT NULL,
    evidence_json                     jsonb NOT NULL,
    evidence_hash                     char(64) NOT NULL,
    created_at                        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(pool_identity) <> '' AND btrim(time_bucket) <> ''),
    CHECK (btrim(volatility_bucket) <> '' AND btrim(liquidity_bucket) <> ''),
    CHECK (btrim(btc_regime) <> ''),
    CHECK (jsonb_typeof(evidence_json) = 'object' AND evidence_json <> '{}'::jsonb),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (evidence_hash = encode(public.digest(evidence_json::text, 'sha256'), 'hex'))
);

CREATE TABLE strategy_training.training_random_baseline_candidates (
    candidate_id                      char(64) PRIMARY KEY,
    dataset_version_id                uuid NOT NULL
                                      REFERENCES strategy_training.training_dataset_versions,
    generating_iteration_id           uuid NOT NULL
                                      REFERENCES strategy_training.training_iterations,
    instrument_id                     bigint NOT NULL REFERENCES core.instruments,
    observed_at                       timestamptz NOT NULL,
    entry_time                        timestamptz NOT NULL,
    direction                         varchar(8) NOT NULL CHECK (direction IN ('LONG', 'SHORT')),
    pool_evaluation_id                uuid NOT NULL
                                      REFERENCES strategy_training.training_historical_pool_evaluations,
    random_baseline_config_version_id uuid NOT NULL
                                      REFERENCES strategy_training.training_config_versions,
    trigger_score                     numeric(18, 8) NOT NULL,
    signal_score_threshold            numeric(18, 8) NOT NULL,
    pool_identity                     text NOT NULL,
    time_bucket                       text NOT NULL,
    volatility_bucket                 text NOT NULL,
    liquidity_bucket                  text NOT NULL,
    btc_regime                        text NOT NULL,
    volatility_window_start_at        timestamptz NOT NULL,
    liquidity_window_start_at         timestamptz NOT NULL,
    btc_regime_window_start_at        timestamptz NOT NULL,
    evidence_json                     jsonb NOT NULL,
    evidence_hash                     char(64) NOT NULL,
    created_at                        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (candidate_id ~ '^[0-9a-f]{64}$'),
    CHECK (trigger_score < signal_score_threshold),
    CHECK (entry_time > observed_at),
    CHECK (volatility_window_start_at < observed_at),
    CHECK (liquidity_window_start_at < observed_at),
    CHECK (btc_regime_window_start_at < observed_at),
    CHECK (btrim(pool_identity) <> '' AND btrim(time_bucket) <> ''),
    CHECK (btrim(volatility_bucket) <> '' AND btrim(liquidity_bucket) <> ''),
    CHECK (btrim(btc_regime) <> ''),
    CHECK (jsonb_typeof(evidence_json) = 'object' AND evidence_json <> '{}'::jsonb),
    CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    CHECK (evidence_hash = encode(public.digest(evidence_json::text, 'sha256'), 'hex')),
    UNIQUE (generating_iteration_id, instrument_id, observed_at, direction)
);

CREATE INDEX ix_training_random_baseline_candidate_frame
ON strategy_training.training_random_baseline_candidates (
    generating_iteration_id, random_baseline_config_version_id,
    instrument_id, pool_identity, time_bucket,
    volatility_bucket, liquidity_bucket, btc_regime, observed_at
);

CREATE OR REPLACE FUNCTION strategy_training.compute_training_random_baseline_candidate_id(
    p_dataset_version_id uuid,
    p_generating_iteration_id uuid,
    p_instrument_id bigint,
    p_observed_at timestamptz,
    p_direction text
)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT encode(public.digest(
        format(
            '{"dataset_version_id":"%s","direction":"%s","generating_iteration_id":"%s","instrument_id":%s,"observed_at":"%s"}',
            p_dataset_version_id::text,
            upper(p_direction),
            p_generating_iteration_id::text,
            p_instrument_id,
            to_char(p_observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ),
        'sha256'
    ), 'hex')::char(64)
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_random_baseline_signal_stratum(
    p_entry_event_id char(64),
    p_random_baseline_config_version_id uuid,
    p_volatility_bucket text,
    p_liquidity_bucket text,
    p_btc_regime text,
    p_volatility_window_start_at timestamptz,
    p_liquidity_window_start_at timestamptz,
    p_btc_regime_window_start_at timestamptz,
    p_evidence_json jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    entry_record strategy_training.training_entry_events%ROWTYPE;
    config_record strategy_training.training_config_versions%ROWTYPE;
    experiment_id_value uuid;
    pool_identity_value text;
    time_bucket_value text;
BEGIN
    SELECT * INTO STRICT entry_record
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = p_entry_event_id;
    IF entry_record.status <> 'COMPLETE' THEN
        RAISE EXCEPTION 'random-baseline signal stratum requires a complete entry event'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.experiment_id INTO STRICT experiment_id_value
    FROM strategy_training.training_iterations iteration
    WHERE iteration.iteration_id = entry_record.generating_iteration_id
      AND iteration.state = 'RUNNING';
    SELECT * INTO STRICT config_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_random_baseline_config_version_id;
    IF config_record.config_type <> 'RANDOM_BASELINE'
       OR config_record.status <> 'READY'
       OR jsonb_typeof(config_record.config_json -> 'random_seed') IS DISTINCT FROM 'number'
       OR (config_record.config_json ->> 'random_seed') !~ '^-?[0-9]+$'
       OR NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_experiment_config_bindings binding
            WHERE binding.experiment_id = experiment_id_value
              AND binding.config_type = 'RANDOM_BASELINE'
              AND binding.config_version_id = p_random_baseline_config_version_id
       ) THEN
        RAISE EXCEPTION 'signal stratum requires the frozen READY random-baseline config with random_seed'
            USING ERRCODE = '23514';
    END IF;
    IF p_volatility_window_start_at >= entry_record.signal_time
       OR p_liquidity_window_start_at >= entry_record.signal_time
       OR p_btc_regime_window_start_at >= entry_record.signal_time THEN
        RAISE EXCEPTION 'random-baseline strata must use pre-signal windows'
            USING ERRCODE = '23514';
    END IF;
    IF jsonb_typeof(p_evidence_json) IS DISTINCT FROM 'object'
       OR p_evidence_json = '{}'::jsonb THEN
        RAISE EXCEPTION 'random-baseline stratum requires non-empty evidence'
            USING ERRCODE = '23514';
    END IF;
    pool_identity_value := entry_record.ticker_pool_rule_version_id::text;
    time_bucket_value := 'UTC-' || to_char(entry_record.signal_time AT TIME ZONE 'UTC', 'HH24');
    INSERT INTO strategy_training.training_random_baseline_signal_strata (
        entry_event_id, random_baseline_config_version_id,
        pool_identity, time_bucket, volatility_bucket, liquidity_bucket, btc_regime,
        volatility_window_start_at, liquidity_window_start_at,
        btc_regime_window_start_at, evidence_json, evidence_hash
    ) VALUES (
        p_entry_event_id, p_random_baseline_config_version_id,
        pool_identity_value, time_bucket_value,
        p_volatility_bucket, p_liquidity_bucket, p_btc_regime,
        p_volatility_window_start_at, p_liquidity_window_start_at,
        p_btc_regime_window_start_at, p_evidence_json,
        encode(public.digest(p_evidence_json::text, 'sha256'), 'hex')
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_random_baseline_candidate(
    p_candidate_id char(64),
    p_dataset_version_id uuid,
    p_generating_iteration_id uuid,
    p_instrument_id bigint,
    p_observed_at timestamptz,
    p_direction text,
    p_pool_evaluation_id uuid,
    p_random_baseline_config_version_id uuid,
    p_trigger_score numeric,
    p_signal_score_threshold numeric,
    p_volatility_bucket text,
    p_liquidity_bucket text,
    p_btc_regime text,
    p_volatility_window_start_at timestamptz,
    p_liquidity_window_start_at timestamptz,
    p_btc_regime_window_start_at timestamptz,
    p_evidence_json jsonb
)
RETURNS char(64)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    pool_record strategy_training.training_historical_pool_evaluations%ROWTYPE;
    experiment_id_value uuid;
    pool_identity_value text;
    time_bucket_value text;
BEGIN
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = p_dataset_version_id;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR p_observed_at < dataset_record.eligible_start_at
       OR p_observed_at >= dataset_record.eligible_end_at THEN
        RAISE EXCEPTION 'random-baseline candidate requires a READY TRAIN dataset instant'
            USING ERRCODE = '23514';
    END IF;
    IF p_candidate_id <> strategy_training.compute_training_random_baseline_candidate_id(
        p_dataset_version_id, p_generating_iteration_id, p_instrument_id,
        p_observed_at, p_direction
    ) THEN
        RAISE EXCEPTION 'random-baseline candidate_id does not match its deterministic identity'
            USING ERRCODE = '23514';
    END IF;
    IF p_trigger_score >= p_signal_score_threshold THEN
        RAISE EXCEPTION 'random-baseline candidate must trigger but remain below the signal threshold'
            USING ERRCODE = '23514';
    END IF;
    IF p_volatility_window_start_at >= p_observed_at
       OR p_liquidity_window_start_at >= p_observed_at
       OR p_btc_regime_window_start_at >= p_observed_at THEN
        RAISE EXCEPTION 'random-baseline candidate strata must use pre-candidate windows'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.experiment_id INTO STRICT experiment_id_value
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiments experiment
      ON experiment.experiment_id = iteration.experiment_id
    WHERE iteration.iteration_id = p_generating_iteration_id
      AND iteration.state = 'RUNNING'
      AND iteration.candidate_source = 'FIXED_BASELINE'
      AND experiment.dataset_version_id = p_dataset_version_id;
    IF NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_experiment_config_bindings binding
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
         AND config.config_type = 'RANDOM_BASELINE'
         AND config.status = 'READY'
        WHERE binding.experiment_id = experiment_id_value
          AND binding.config_type = 'RANDOM_BASELINE'
          AND binding.config_version_id = p_random_baseline_config_version_id
          AND jsonb_typeof(config.config_json -> 'random_seed') = 'number'
          AND (config.config_json ->> 'random_seed') ~ '^-?[0-9]+$'
    ) THEN
        RAISE EXCEPTION 'candidate random-baseline config is not frozen and READY'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT pool_record
    FROM strategy_training.training_historical_pool_evaluations
    WHERE pool_evaluation_id = p_pool_evaluation_id;
    IF pool_record.dataset_version_id <> p_dataset_version_id
       OR pool_record.instrument_id <> p_instrument_id
       OR NOT pool_record.is_eligible
       OR pool_record.evaluation_at > p_observed_at THEN
        RAISE EXCEPTION 'candidate lacks contemporaneous eligible-pool evidence'
            USING ERRCODE = '23514';
    END IF;
    IF jsonb_typeof(p_evidence_json) IS DISTINCT FROM 'object'
       OR p_evidence_json = '{}'::jsonb THEN
        RAISE EXCEPTION 'random-baseline candidate requires non-empty evidence'
            USING ERRCODE = '23514';
    END IF;
    pool_identity_value := dataset_record.ticker_pool_rule_version_id::text;
    time_bucket_value := 'UTC-' || to_char(p_observed_at AT TIME ZONE 'UTC', 'HH24');
    INSERT INTO strategy_training.training_random_baseline_candidates (
        candidate_id, dataset_version_id, generating_iteration_id,
        instrument_id, observed_at, entry_time, direction, pool_evaluation_id,
        random_baseline_config_version_id, trigger_score, signal_score_threshold,
        pool_identity, time_bucket, volatility_bucket, liquidity_bucket, btc_regime,
        volatility_window_start_at, liquidity_window_start_at,
        btc_regime_window_start_at, evidence_json, evidence_hash
    ) VALUES (
        p_candidate_id, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, p_observed_at,
        p_observed_at + make_interval(secs => dataset_record.interval_seconds),
        upper(p_direction), p_pool_evaluation_id,
        p_random_baseline_config_version_id, p_trigger_score, p_signal_score_threshold,
        pool_identity_value, time_bucket_value,
        p_volatility_bucket, p_liquidity_bucket, p_btc_regime,
        p_volatility_window_start_at, p_liquidity_window_start_at,
        p_btc_regime_window_start_at, p_evidence_json,
        encode(public.digest(p_evidence_json::text, 'sha256'), 'hex')
    );
    RETURN p_candidate_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_baseline_evaluation_context(
    p_task_id uuid,
    p_lease_token uuid,
    p_entry_event_id char(64)
)
RETURNS TABLE (
    random_baseline_config_version_id uuid,
    sample_count integer,
    minimum_frame_size integer,
    exclusion_window_seconds integer,
    random_seed bigint,
    instrument_id bigint,
    pool_identity text,
    time_bucket text,
    volatility_bucket text,
    liquidity_bucket text,
    btc_regime text,
    signal_times timestamptz[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
BEGIN
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token <> p_lease_token
       OR task_record.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'random-baseline context requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    RETURN QUERY
    SELECT stratum.random_baseline_config_version_id,
           (config.config_json ->> 'sample_count')::integer,
           (config.config_json ->> 'minimum_frame_size')::integer,
           (config.config_json ->> 'exclusion_window_seconds')::integer,
           (config.config_json ->> 'random_seed')::bigint,
           entry.instrument_id,
           stratum.pool_identity, stratum.time_bucket,
           stratum.volatility_bucket, stratum.liquidity_bucket,
           stratum.btc_regime,
           ARRAY(
               SELECT sibling.signal_time
               FROM strategy_training.training_entry_events sibling
               WHERE sibling.dataset_version_id = entry.dataset_version_id
                 AND sibling.generating_iteration_id = entry.generating_iteration_id
                 AND sibling.instrument_id = entry.instrument_id
                 AND sibling.status = 'COMPLETE'
               ORDER BY sibling.signal_time
           )
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_random_baseline_signal_strata stratum
      ON stratum.entry_event_id = entry.entry_event_id
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = stratum.random_baseline_config_version_id
     AND config.config_type = 'RANDOM_BASELINE'
     AND config.status = 'READY'
    WHERE entry.entry_event_id = p_entry_event_id
      AND entry.generating_iteration_id = task_record.iteration_id
      AND entry.status = 'COMPLETE';
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_baseline_candidate_frame(
    p_task_id uuid,
    p_lease_token uuid,
    p_entry_event_id char(64)
)
RETURNS TABLE (
    candidate_id char(64),
    observed_at timestamptz,
    instrument_id bigint,
    pool_identity text,
    time_bucket text,
    volatility_bucket text,
    liquidity_bucket text,
    btc_regime text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    WITH context AS MATERIALIZED (
        SELECT *
        FROM strategy_training.training_random_baseline_evaluation_context(
            p_task_id, p_lease_token, p_entry_event_id
        )
    ), target AS (
        SELECT entry.dataset_version_id, entry.generating_iteration_id
        FROM strategy_training.training_entry_events entry
        WHERE entry.entry_event_id = p_entry_event_id
    )
    SELECT candidate.candidate_id, candidate.observed_at,
           candidate.instrument_id, candidate.pool_identity, candidate.time_bucket,
           candidate.volatility_bucket, candidate.liquidity_bucket,
           candidate.btc_regime
    FROM strategy_training.training_random_baseline_candidates candidate
    CROSS JOIN context
    CROSS JOIN target
    WHERE candidate.dataset_version_id = target.dataset_version_id
      AND candidate.generating_iteration_id = target.generating_iteration_id
      AND candidate.random_baseline_config_version_id = context.random_baseline_config_version_id
      AND candidate.instrument_id = context.instrument_id
      AND candidate.pool_identity = context.pool_identity
      AND candidate.time_bucket = context.time_bucket
      AND candidate.volatility_bucket = context.volatility_bucket
      AND candidate.liquidity_bucket = context.liquidity_bucket
      AND candidate.btc_regime = context.btc_regime
    ORDER BY candidate.candidate_id
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_trusted_frame()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    entry_record strategy_training.training_entry_events%ROWTYPE;
    stratum_record strategy_training.training_random_baseline_signal_strata%ROWTYPE;
    config_json_value jsonb;
    sample_count_value integer;
    exclusion_seconds integer;
    random_seed_value bigint;
    expected_stratum jsonb;
    expected_frame_size integer;
    expected_overlap_count integer;
    expected_frame_hash char(64);
    expected_selected_ids jsonb;
BEGIN
    SELECT * INTO STRICT entry_record
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = NEW.matched_entry_event_id;
    SELECT * INTO STRICT stratum_record
    FROM strategy_training.training_random_baseline_signal_strata
    WHERE entry_event_id = NEW.matched_entry_event_id;
    SELECT config_json INTO STRICT config_json_value
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.random_baseline_config_version_id
      AND config_type = 'RANDOM_BASELINE'
      AND status = 'READY';
    IF stratum_record.random_baseline_config_version_id <>
       NEW.random_baseline_config_version_id THEN
        RAISE EXCEPTION 'random-baseline result config differs from its trusted stratum'
            USING ERRCODE = '23514';
    END IF;
    sample_count_value := (config_json_value ->> 'sample_count')::integer;
    exclusion_seconds := (config_json_value ->> 'exclusion_window_seconds')::integer;
    random_seed_value := (config_json_value ->> 'random_seed')::bigint;
    expected_stratum := jsonb_build_object(
        'instrument_id', entry_record.instrument_id,
        'pool_identity', stratum_record.pool_identity,
        'time_bucket', stratum_record.time_bucket,
        'volatility_bucket', stratum_record.volatility_bucket,
        'liquidity_bucket', stratum_record.liquidity_bucket,
        'btc_regime', stratum_record.btc_regime
    );

    WITH matched AS (
        SELECT candidate.*
        FROM strategy_training.training_random_baseline_candidates candidate
        WHERE candidate.dataset_version_id = entry_record.dataset_version_id
          AND candidate.generating_iteration_id = entry_record.generating_iteration_id
          AND candidate.random_baseline_config_version_id =
              NEW.random_baseline_config_version_id
          AND candidate.instrument_id = entry_record.instrument_id
          AND candidate.pool_identity = stratum_record.pool_identity
          AND candidate.time_bucket = stratum_record.time_bucket
          AND candidate.volatility_bucket = stratum_record.volatility_bucket
          AND candidate.liquidity_bucket = stratum_record.liquidity_bucket
          AND candidate.btc_regime = stratum_record.btc_regime
    ), eligible AS (
        SELECT matched.*
        FROM matched
        WHERE NOT EXISTS (
            SELECT 1
            FROM strategy_training.training_entry_events signal
            WHERE signal.dataset_version_id = entry_record.dataset_version_id
              AND signal.generating_iteration_id = entry_record.generating_iteration_id
              AND signal.instrument_id = entry_record.instrument_id
              AND signal.status = 'COMPLETE'
              AND abs(extract(epoch FROM (matched.observed_at - signal.signal_time)))
                  <= exclusion_seconds
        )
    ), ranked AS (
        SELECT eligible.*,
               encode(public.digest(
                   format('%s:%s:%s', random_seed_value,
                          NEW.matched_entry_event_id, eligible.candidate_id),
                   'sha256'
               ), 'hex') AS sampling_rank
        FROM eligible
    ), selected AS (
        SELECT ranked.*
        FROM ranked
        ORDER BY sampling_rank, candidate_id
        LIMIT sample_count_value
    )
    SELECT
        (SELECT count(*) FROM eligible),
        (SELECT count(*) FROM matched) - (SELECT count(*) FROM eligible),
        (SELECT encode(public.digest(string_agg(
             candidate_id::text || '|' ||
             to_char(observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
             E'\n' ORDER BY candidate_id
         ), 'sha256'), 'hex') FROM eligible),
        (SELECT jsonb_agg(to_jsonb(candidate_id::text)
                          ORDER BY sampling_rank, candidate_id)
         FROM selected)
    INTO expected_frame_size, expected_overlap_count,
         expected_frame_hash, expected_selected_ids;

    IF expected_frame_size = 0
       OR NEW.matching_stratum <> expected_stratum
       OR NEW.random_seed <> random_seed_value
       OR NEW.sampling_frame_size <> expected_frame_size
       OR NEW.overlap_excluded_count <> expected_overlap_count
       OR NEW.sampling_frame_hash <> expected_frame_hash
       OR NEW.selected_candidate_ids <> expected_selected_ids THEN
        RAISE EXCEPTION 'random-baseline result does not match its trusted candidate frame'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_random_baseline_signal_strata_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_signal_strata
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_random_baseline_candidates_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_candidates
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_random_baseline_trusted_frame
BEFORE INSERT ON strategy_training.training_random_entry_baselines
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_random_baseline_trusted_frame();

ALTER TABLE strategy_training.training_random_baseline_signal_strata OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_random_baseline_candidates OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.compute_training_random_baseline_candidate_id(
    uuid, uuid, bigint, timestamptz, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_random_baseline_signal_stratum(
    char(64), uuid, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_random_baseline_candidate(
    char(64), uuid, uuid, bigint, timestamptz, text, uuid, uuid,
    numeric, numeric, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_baseline_evaluation_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_baseline_candidate_frame(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_random_baseline_trusted_frame()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_random_baseline_signal_strata,
    strategy_training.training_random_baseline_candidates FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.compute_training_random_baseline_candidate_id(
    uuid, uuid, bigint, timestamptz, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.record_training_random_baseline_signal_stratum(
    char(64), uuid, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.record_training_random_baseline_candidate(
    char(64), uuid, uuid, bigint, timestamptz, text, uuid, uuid,
    numeric, numeric, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_random_baseline_evaluation_context(
    uuid, uuid, char(64)
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.training_random_baseline_candidate_frame(
    uuid, uuid, char(64)
) FROM PUBLIC;
REVOKE ALL ON FUNCTION strategy_training.guard_training_random_baseline_trusted_frame()
FROM PUBLIC;

GRANT SELECT ON strategy_training.training_random_baseline_signal_strata,
    strategy_training.training_random_baseline_candidates TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.compute_training_random_baseline_candidate_id(
    uuid, uuid, bigint, timestamptz, text
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.record_training_random_baseline_signal_stratum(
    char(64), uuid, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.record_training_random_baseline_candidate(
    char(64), uuid, uuid, bigint, timestamptz, text, uuid, uuid,
    numeric, numeric, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) TO tb2_training_rw;
GRANT EXECUTE ON FUNCTION strategy_training.training_random_baseline_evaluation_context(
    uuid, uuid, char(64)
) TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION strategy_training.training_random_baseline_candidate_frame(
    uuid, uuid, char(64)
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '043_training_random_baseline_frame',
    encode(digest('auto_trade_v2_043_training_random_baseline_frame_v1', 'sha256'), 'hex'),
    'Add trusted low-score candidate frames and leased random-baseline evaluation contexts'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
