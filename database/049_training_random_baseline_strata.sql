\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_strata_config()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE
    strata jsonb;
    boundaries jsonb;
    boundary_name text;
    values_array numeric[];
BEGIN
    IF NEW.config_type <> 'RANDOM_BASELINE' OR NEW.status <> 'READY'
       OR (TG_OP = 'UPDATE' AND OLD.status = 'READY') THEN
        RETURN NEW;
    END IF;
    strata := NEW.config_json -> 'stratification';
    IF jsonb_typeof(NEW.config_json -> 'maximum_frame_candidates') IS DISTINCT FROM 'number'
       OR (NEW.config_json ->> 'maximum_frame_candidates')::numeric <= 0
       OR (NEW.config_json ->> 'maximum_frame_candidates')::numeric % 1 <> 0
       OR jsonb_typeof(strata) IS DISTINCT FROM 'object'
       OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(strata) key)
          IS DISTINCT FROM ARRAY[
              'benchmark_symbol', 'btc_regime_measure', 'btc_regime_window_bars',
              'btc_return_boundaries_percent', 'liquidity_boundaries_quote_volume',
              'liquidity_measure', 'liquidity_window_bars',
              'volatility_boundaries_percent', 'volatility_measure',
              'volatility_window_bars'
          ]::text[]
       OR strata ->> 'volatility_measure' <> 'CLOSE_RETURN_STDDEV_PERCENT'
       OR strata ->> 'liquidity_measure' <> 'MEAN_QUOTE_VOLUME'
       OR strata ->> 'btc_regime_measure' <> 'CLOSE_RETURN_PERCENT'
       OR jsonb_typeof(strata -> 'benchmark_symbol') IS DISTINCT FROM 'string'
       OR btrim(strata ->> 'benchmark_symbol') = ''
       OR upper(strata ->> 'benchmark_symbol') <> strata ->> 'benchmark_symbol' THEN
        RAISE EXCEPTION 'READY RANDOM_BASELINE requires exact governed stratification'
            USING ERRCODE = '23514';
    END IF;
    FOREACH boundary_name IN ARRAY ARRAY[
        'volatility_window_bars', 'liquidity_window_bars', 'btc_regime_window_bars'
    ] LOOP
        IF jsonb_typeof(strata -> boundary_name) IS DISTINCT FROM 'number'
           OR (strata ->> boundary_name)::numeric <= 0
           OR (strata ->> boundary_name)::numeric % 1 <> 0 THEN
            RAISE EXCEPTION 'RANDOM_BASELINE % must be a positive integer', boundary_name
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    FOREACH boundary_name IN ARRAY ARRAY[
        'volatility_boundaries_percent', 'liquidity_boundaries_quote_volume',
        'btc_return_boundaries_percent'
    ] LOOP
        boundaries := strata -> boundary_name;
        IF jsonb_typeof(boundaries) IS DISTINCT FROM 'array'
           OR jsonb_array_length(boundaries) = 0
           OR EXISTS (
                SELECT 1 FROM jsonb_array_elements(boundaries) item(value)
                WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'number'
           ) THEN
            RAISE EXCEPTION 'RANDOM_BASELINE % must be a non-empty numeric array',
                boundary_name USING ERRCODE = '23514';
        END IF;
        SELECT array_agg(value::numeric ORDER BY ordinal)
        INTO values_array
        FROM jsonb_array_elements_text(boundaries) WITH ORDINALITY item(value, ordinal);
        IF EXISTS (
            SELECT 1 FROM generate_subscripts(values_array, 1) position
            WHERE position > 1
              AND values_array[position] <= values_array[position - 1]
        ) THEN
            RAISE EXCEPTION 'RANDOM_BASELINE % must be strictly ascending', boundary_name
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_random_baseline_strata_config
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_random_baseline_strata_config();

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_random_config(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (random_baseline_config_version_id uuid, config_json jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
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
     AND config.config_type = 'RANDOM_BASELINE' AND config.status = 'READY'
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_benchmark_bars(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (open_time timestamptz, close_price numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $$
    WITH context AS (
        SELECT scan.*, dataset.warmup_start_at, dataset.source_as_of_at,
               config.config_json -> 'stratification' ->> 'benchmark_symbol' AS benchmark_symbol
        FROM strategy_training.training_model_a_candidate_scan_context(
            p_task_id, p_lease_token
        ) scan
        JOIN strategy_training.training_dataset_versions dataset
          ON dataset.dataset_version_id = scan.dataset_version_id
        JOIN strategy_training.training_model_a_candidate_scan_random_config(
            p_task_id, p_lease_token
        ) config ON true
    ), benchmark AS (
        SELECT instrument.instrument_id
        FROM context
        JOIN core.instruments instrument
          ON instrument.exchange = 'BINANCE'
         AND instrument.market = 'USD_M_FUTURES'
         AND instrument.symbol = context.benchmark_symbol
    )
    SELECT DISTINCT ON (bar.open_time) bar.open_time, bar.close_price
    FROM context
    JOIN benchmark ON true
    JOIN market.klines bar ON bar.instrument_id = benchmark.instrument_id
     AND bar.price_type = 'TRADE' AND bar.interval_seconds = 300
     AND bar.is_closed AND bar.quality_status = 'VALID'
     AND bar.open_time >= context.warmup_start_at
     AND bar.open_time < context.eligible_end_at
     AND bar.effective_at <= context.source_as_of_at
    ORDER BY bar.open_time, bar.revision_no DESC
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_candidate_signal_stratum(
    p_task_id uuid, p_lease_token uuid, p_entry_event_id char(64),
    p_random_baseline_config_version_id uuid,
    p_volatility_bucket text, p_liquidity_bucket text, p_btc_regime text,
    p_volatility_window_start_at timestamptz,
    p_liquidity_window_start_at timestamptz,
    p_btc_regime_window_start_at timestamptz, p_evidence_json jsonb
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
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
       OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_entry_events entry
            WHERE entry.entry_event_id = p_entry_event_id
              AND entry.generating_iteration_id = task_record.iteration_id
       ) THEN
        RAISE EXCEPTION 'signal stratum write requires its active scan lease'
            USING ERRCODE = '40001';
    END IF;
    PERFORM strategy_training.record_training_random_baseline_signal_stratum(
        p_entry_event_id, p_random_baseline_config_version_id,
        p_volatility_bucket, p_liquidity_bucket, p_btc_regime,
        p_volatility_window_start_at, p_liquidity_window_start_at,
        p_btc_regime_window_start_at, p_evidence_json
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_candidate_random_baseline(
    p_task_id uuid, p_lease_token uuid, p_dataset_version_id uuid,
    p_generating_iteration_id uuid, p_instrument_id bigint,
    p_observed_at timestamptz, p_direction text, p_pool_evaluation_id uuid,
    p_random_baseline_config_version_id uuid, p_trigger_score numeric,
    p_signal_score_threshold numeric, p_volatility_bucket text,
    p_liquidity_bucket text, p_btc_regime text,
    p_volatility_window_start_at timestamptz,
    p_liquidity_window_start_at timestamptz,
    p_btc_regime_window_start_at timestamptz, p_evidence_json jsonb
)
RETURNS char(64) LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    task_record strategy_training.training_tasks%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    pool_record strategy_training.training_historical_pool_evaluations%ROWTYPE;
    candidate_id_value char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'MODEL_A_CANDIDATE_SCAN'
       OR task_record.executor_kind <> 'WORKER'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR task_record.iteration_id IS DISTINCT FROM p_generating_iteration_id THEN
        RAISE EXCEPTION 'random candidate write requires its active scan lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = p_dataset_version_id;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR p_observed_at < dataset_record.eligible_start_at
       OR p_observed_at >= dataset_record.eligible_end_at
       OR p_direction <> 'LONG' OR p_trigger_score >= p_signal_score_threshold
       OR jsonb_typeof(p_evidence_json) IS DISTINCT FROM 'object'
       OR p_evidence_json = '{}'::jsonb
       OR p_volatility_window_start_at >= p_observed_at
       OR p_liquidity_window_start_at >= p_observed_at
       OR p_btc_regime_window_start_at >= p_observed_at THEN
        RAISE EXCEPTION 'random candidate violates its governed TRAIN frame'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_model_a_candidate_scan_random_config(
            p_task_id, p_lease_token
        ) config
        WHERE config.random_baseline_config_version_id =
              p_random_baseline_config_version_id
    ) THEN
        RAISE EXCEPTION 'random candidate config is not frozen on its experiment'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT pool_record
    FROM strategy_training.training_historical_pool_evaluations
    WHERE pool_evaluation_id = p_pool_evaluation_id;
    IF pool_record.dataset_version_id <> p_dataset_version_id
       OR pool_record.instrument_id <> p_instrument_id
       OR NOT pool_record.is_eligible
       OR pool_record.evaluation_at > p_observed_at THEN
        RAISE EXCEPTION 'random candidate lacks contemporaneous pool evidence'
            USING ERRCODE = '23514';
    END IF;
    candidate_id_value := strategy_training.compute_training_random_baseline_candidate_id(
        p_dataset_version_id, p_generating_iteration_id, p_instrument_id,
        p_observed_at, p_direction
    );
    INSERT INTO strategy_training.training_random_baseline_candidates (
        candidate_id, dataset_version_id, generating_iteration_id,
        instrument_id, observed_at, entry_time, direction, pool_evaluation_id,
        random_baseline_config_version_id, trigger_score, signal_score_threshold,
        pool_identity, time_bucket, volatility_bucket, liquidity_bucket, btc_regime,
        volatility_window_start_at, liquidity_window_start_at,
        btc_regime_window_start_at, evidence_json, evidence_hash
    ) VALUES (
        candidate_id_value, p_dataset_version_id, p_generating_iteration_id,
        p_instrument_id, p_observed_at,
        p_observed_at + make_interval(secs => dataset_record.interval_seconds),
        p_direction, p_pool_evaluation_id, p_random_baseline_config_version_id,
        p_trigger_score, p_signal_score_threshold,
        dataset_record.ticker_pool_rule_version_id::text,
        'UTC-' || to_char(p_observed_at AT TIME ZONE 'UTC', 'HH24'),
        p_volatility_bucket, p_liquidity_bucket, p_btc_regime,
        p_volatility_window_start_at, p_liquidity_window_start_at,
        p_btc_regime_window_start_at, p_evidence_json,
        encode(public.digest(p_evidence_json::text, 'sha256'), 'hex')
    );
    RETURN candidate_id_value;
END
$$;

ALTER FUNCTION strategy_training.guard_training_random_baseline_strata_config()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_random_config(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_benchmark_bars(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_candidate_signal_stratum(
    uuid, uuid, char(64), uuid, text, text, text,
    timestamptz, timestamptz, timestamptz, jsonb
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_candidate_random_baseline(
    uuid, uuid, uuid, uuid, bigint, timestamptz, text, uuid, uuid,
    numeric, numeric, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.guard_training_random_baseline_strata_config(),
    strategy_training.training_model_a_candidate_scan_random_config(uuid, uuid),
    strategy_training.training_model_a_candidate_scan_benchmark_bars(uuid, uuid),
    strategy_training.record_training_candidate_signal_stratum(
        uuid, uuid, char(64), uuid, text, text, text,
        timestamptz, timestamptz, timestamptz, jsonb
    ),
    strategy_training.record_training_candidate_random_baseline(
        uuid, uuid, uuid, uuid, bigint, timestamptz, text, uuid, uuid,
        numeric, numeric, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
    )
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_a_candidate_scan_random_config(uuid, uuid),
    strategy_training.training_model_a_candidate_scan_benchmark_bars(uuid, uuid),
    strategy_training.record_training_candidate_signal_stratum(
        uuid, uuid, char(64), uuid, text, text, text,
        timestamptz, timestamptz, timestamptz, jsonb
    ),
    strategy_training.record_training_candidate_random_baseline(
        uuid, uuid, uuid, uuid, bigint, timestamptz, text, uuid, uuid,
        numeric, numeric, text, text, text, timestamptz, timestamptz, timestamptz, jsonb
    )
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '049_training_random_baseline_strata',
    encode(digest('auto_trade_v2_049_training_random_baseline_strata_v1', 'sha256'), 'hex'),
    'Add config-driven signal strata and low-score random-baseline candidate frames'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
