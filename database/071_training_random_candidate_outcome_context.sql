\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- A random candidate is already frozen in reference_support.  Validate its
-- membership directly instead of rebuilding and expanding the complete frame
-- for every context read and every outcome insert.  Selecting only the task
-- iteration also avoids copying the large evaluation task_payload into a
-- PL/pgSQL row variable on every candidate.
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
DECLARE
    iteration_id_value uuid;
    entry_record strategy_training.training_entry_events%ROWTYPE;
    stratum_record strategy_training.training_random_baseline_signal_strata%ROWTYPE;
    candidate_record strategy_training.training_random_baseline_candidates%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    config_json_value jsonb;
    governed_time_bucket text;
    entry_price_value numeric;
BEGIN
    SELECT task.iteration_id INTO iteration_id_value
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id
      AND task.state = 'RUNNING'
      AND task.executor_kind = 'EVALUATOR'
      AND task.task_type = 'MODEL_A_EVALUATION'
      AND task.lease_token IS NOT DISTINCT FROM p_lease_token
      AND task.lease_expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'random outcome context requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;

    SELECT * INTO entry_record
    FROM strategy_training.training_entry_events entry
    WHERE entry.entry_event_id = p_matched_entry_event_id
      AND entry.generating_iteration_id = iteration_id_value
      AND entry.status = 'COMPLETE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'matched entry does not belong to the leased evaluation'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO stratum_record
    FROM strategy_training.training_random_baseline_signal_strata stratum
    WHERE stratum.entry_event_id = p_matched_entry_event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'matched entry has no frozen random-baseline stratum'
            USING ERRCODE = '23514';
    END IF;

    SELECT config.config_json INTO config_json_value
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'RANDOM_BASELINE'
     AND config.semver::text NOT IN ('0.1.0', '0.1.1')
     AND config.status = 'READY'
     AND config.config_json ? 'reference_set_id'
    WHERE iteration.iteration_id = iteration_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'evaluation has no approved random-baseline reference binding'
            USING ERRCODE = '23514';
    END IF;

    governed_time_bucket :=
        'UTC-' || lpad(((extract(hour FROM entry_record.signal_time AT TIME ZONE 'UTC')::integer
            / (config_json_value ->> 'time_bucket_hours')::integer)
            * (config_json_value ->> 'time_bucket_hours')::integer)::text, 2, '0') || '-' ||
        lpad((((extract(hour FROM entry_record.signal_time AT TIME ZONE 'UTC')::integer
            / (config_json_value ->> 'time_bucket_hours')::integer)
            * (config_json_value ->> 'time_bucket_hours')::integer)
            + (config_json_value ->> 'time_bucket_hours')::integer - 1)::text, 2, '0');

    SELECT * INTO candidate_record
    FROM strategy_training.training_random_baseline_candidates candidate
    WHERE candidate.candidate_id = p_candidate_id
      AND candidate.instrument_id = entry_record.instrument_id
      AND EXISTS (
          SELECT 1
          FROM strategy_training.training_random_baseline_reference_support support
          WHERE support.reference_set_id =
                    (config_json_value ->> 'reference_set_id')::uuid
            AND support.instrument_id = entry_record.instrument_id
            AND support.pool_identity = stratum_record.pool_identity
            AND support.time_bucket = governed_time_bucket
            AND support.volatility_bucket = stratum_record.volatility_bucket
            AND support.liquidity_bucket = stratum_record.liquidity_bucket
            AND support.btc_regime = stratum_record.btc_regime
            AND support.candidate_ids ? p_candidate_id::text
      );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'candidate is outside the frozen reference support'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO dataset_record
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = candidate_record.dataset_version_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'random candidate has no governed dataset'
            USING ERRCODE = '23514';
    END IF;

    SELECT bar.open_price INTO entry_price_value
    FROM market.klines bar
    WHERE bar.instrument_id = candidate_record.instrument_id
      AND bar.price_type = 'TRADE'
      AND bar.interval_seconds = dataset_record.interval_seconds
      AND bar.open_time = candidate_record.entry_time
      AND bar.is_closed
      AND bar.quality_status = 'VALID'
      AND bar.effective_at <= dataset_record.source_as_of_at
    ORDER BY bar.revision_no DESC, bar.effective_at DESC, bar.collected_at DESC
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'random candidate has no visible entry-price bar'
            USING ERRCODE = '23514';
    END IF;

    IF dataset_record.status <> 'READY'
       OR dataset_record.partition <> 'TRAIN'
       OR candidate_record.entry_time + dataset_record.label_horizon_duration
          > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'random outcome requires a complete READY TRAIN label window'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY SELECT
        dataset_record.partition::text,
        dataset_record.partition_start_at,
        dataset_record.partition_end_at,
        candidate_record.entry_time,
        entry_price_value,
        candidate_record.direction::text,
        candidate_record.entry_time + dataset_record.label_horizon_duration,
        dataset_record.interval_seconds,
        dataset_record.holding_rule_version_id;
END
$$;

ALTER FUNCTION strategy_training.training_random_candidate_outcome_context(
    uuid, uuid, char(64), char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.training_random_candidate_outcome_context(
    uuid, uuid, char(64), char(64)
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.training_random_candidate_outcome_context(
    uuid, uuid, char(64), char(64)
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '071_training_random_candidate_outcome_context',
    encode(public.digest(
        'auto_trade_v2_071_training_random_candidate_outcome_context_v1',
        'sha256'
    ), 'hex'),
    'Validate random outcome candidates by direct frozen reference membership'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
