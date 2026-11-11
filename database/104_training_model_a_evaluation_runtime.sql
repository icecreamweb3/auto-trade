\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Evidence is read by matched entry while the table primary key starts with
-- candidate_id.  Keep the append-only primary key and add the reverse access
-- path used by evaluation retries and L0 aggregation.
CREATE INDEX IF NOT EXISTS ix_training_random_candidate_outcomes_matched_entry
ON strategy_training.training_random_baseline_candidate_outcomes (
    matched_entry_event_id,
    candidate_id
)
INCLUDE (path_fingerprint, is_complete);

-- Validate the active lease without copying the large task_payload (which may
-- contain tens of thousands of entry IDs) into a PL/pgSQL %ROWTYPE for every
-- entry in the task.
CREATE OR REPLACE FUNCTION strategy_training.training_model_a_evaluation_context(
    p_task_id uuid,
    p_lease_token uuid,
    p_entry_event_id char(64)
)
RETURNS TABLE (
    partition text,
    partition_start_at timestamptz,
    partition_end_at timestamptz,
    entry_time timestamptz,
    entry_price numeric,
    direction text,
    label_window_end_at timestamptz,
    interval_seconds integer,
    holding_rule_version_id uuid,
    opportunity_definition_version_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $function$
DECLARE
    iteration_id_value uuid;
BEGIN
    SELECT task.iteration_id
    INTO iteration_id_value
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id
      AND task.state = 'RUNNING'
      AND task.executor_kind = 'EVALUATOR'
      AND task.task_type = 'MODEL_A_EVALUATION'
      AND task.lease_token IS NOT DISTINCT FROM p_lease_token
      AND task.lease_expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MODEL_A evaluation requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;

    RETURN QUERY
    SELECT dataset.partition::text,
           dataset.partition_start_at,
           dataset.partition_end_at,
           entry.entry_time,
           entry.entry_price,
           entry.direction::text,
           entry.entry_time + dataset.label_horizon_duration,
           dataset.interval_seconds,
           dataset.holding_rule_version_id,
           binding.config_version_id
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = entry.dataset_version_id
     AND dataset.status = 'READY'
     AND dataset.partition = 'TRAIN'
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = entry.generating_iteration_id
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'OPPORTUNITY_DEFINITION'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'OPPORTUNITY_DEFINITION'
     AND config.status = 'READY'
    WHERE entry.entry_event_id = p_entry_event_id
      AND entry.generating_iteration_id = iteration_id_value
      AND entry.status = 'COMPLETE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'entry event does not belong to the leased task iteration'
            USING ERRCODE = '23514';
    END IF;
END
$function$;

-- The approved reference support has already applied the governed +/-24h
-- exclusion.  The Python evaluator intentionally does not apply signal_times
-- again, so avoid rebuilding that unused array for every entry and every frame
-- lookup while preserving the existing function signature.
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
AS $function$
DECLARE
    iteration_id_value uuid;
BEGIN
    SELECT task.iteration_id
    INTO iteration_id_value
    FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id
      AND task.state = 'RUNNING'
      AND task.executor_kind = 'EVALUATOR'
      AND task.task_type = 'MODEL_A_EVALUATION'
      AND task.lease_token IS NOT DISTINCT FROM p_lease_token
      AND task.lease_expires_at > clock_timestamp();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'random-baseline context requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;

    IF NOT EXISTS (
        SELECT 1
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
        WHERE iteration.iteration_id = iteration_id_value
    ) THEN
        RAISE EXCEPTION 'evaluation requires an approved random-baseline reference version'
            USING ERRCODE = '23514';
    END IF;

    RETURN QUERY
    SELECT config.config_version_id,
           (config.config_json ->> 'sample_count')::integer,
           (config.config_json ->> 'minimum_frame_size')::integer,
           (config.config_json ->> 'exclusion_window_seconds')::integer,
           (config.config_json ->> 'random_seed')::bigint,
           entry.instrument_id,
           stratum.pool_identity,
           'UTC-' || lpad(((extract(hour FROM entry.signal_time AT TIME ZONE 'UTC')::integer
                / (config.config_json ->> 'time_bucket_hours')::integer)
                * (config.config_json ->> 'time_bucket_hours')::integer)::text, 2, '0') || '-' ||
           lpad((((extract(hour FROM entry.signal_time AT TIME ZONE 'UTC')::integer
                / (config.config_json ->> 'time_bucket_hours')::integer)
                * (config.config_json ->> 'time_bucket_hours')::integer)
                + (config.config_json ->> 'time_bucket_hours')::integer - 1)::text, 2, '0'),
           stratum.volatility_bucket,
           stratum.liquidity_bucket,
           stratum.btc_regime,
           ARRAY[]::timestamptz[]
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_random_baseline_signal_strata stratum
      USING (entry_event_id)
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = entry.generating_iteration_id
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id
     AND config.config_type = 'RANDOM_BASELINE'
     AND config.semver::text NOT IN ('0.1.0', '0.1.1')
     AND config.status = 'READY'
     AND config.config_json ? 'reference_set_id'
    WHERE entry.entry_event_id = p_entry_event_id
      AND entry.generating_iteration_id = iteration_id_value
      AND entry.status = 'COMPLETE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'entry has no governed random-baseline evaluation context'
            USING ERRCODE = '23514';
    END IF;
END
$function$;

ALTER FUNCTION strategy_training.training_model_a_evaluation_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_baseline_evaluation_context(
    uuid, uuid, char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.training_model_a_evaluation_context(uuid, uuid, char(64)),
    strategy_training.training_random_baseline_evaluation_context(uuid, uuid, char(64))
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_a_evaluation_context(uuid, uuid, char(64)),
    strategy_training.training_random_baseline_evaluation_context(uuid, uuid, char(64))
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '104_training_model_a_evaluation_runtime',
    encode(public.digest(
        'auto_trade_v2_104_training_model_a_evaluation_runtime_v1',
        'sha256'
    ), 'hex'),
    'Remove Model-A evaluation N+1 overhead while preserving governed facts'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
