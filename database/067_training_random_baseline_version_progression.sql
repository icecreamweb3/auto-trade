\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- RANDOM_BASELINE 0.1.2 introduced the frozen-reference policy.  Later
-- immutable versions may point at a newly sealed reference set, but the
-- retired 0.1.0/0.1.1 contracts remain audit-only.
CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_v012()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE reference_record strategy_training.training_random_baseline_reference_sets%ROWTYPE;
BEGIN
    IF NEW.config_type <> 'RANDOM_BASELINE' OR NEW.status <> 'READY'
       OR NEW.semver::text IN ('0.1.0', '0.1.1') THEN RETURN NEW; END IF;
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
        RAISE EXCEPTION 'RANDOM_BASELINE approved-reference version differs from the frozen policy'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT reference_record
    FROM strategy_training.training_random_baseline_reference_sets
    WHERE reference_set_id = (NEW.config_json ->> 'reference_set_id')::uuid
      AND status = 'READY';
    IF reference_record.time_bucket_hours <> 24
       OR reference_record.exclusion_window_seconds <> 86400
       OR reference_record.maximum_frame_candidates <> 500
       OR reference_record.random_seed <> 42 THEN
        RAISE EXCEPTION 'RANDOM_BASELINE config/reference policy mismatch'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

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
     AND config.semver::text NOT IN ('0.1.0', '0.1.1')
     AND config.status = 'READY'
     AND config.config_json ? 'reference_set_id';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RANDOM_BASELINE 0.1.0/0.1.1 are audit-only; candidate scan requires an approved-reference version'
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
    SELECT * INTO STRICT task_record
    FROM strategy_training.training_tasks WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'random-baseline context requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations iteration
        JOIN strategy_training.training_experiment_config_bindings binding
          ON binding.experiment_id = iteration.experiment_id
         AND binding.config_type = 'RANDOM_BASELINE'
        JOIN strategy_training.training_config_versions config
          ON config.config_version_id = binding.config_version_id
         AND config.semver::text NOT IN ('0.1.0', '0.1.1')
         AND config.status = 'READY'
         AND config.config_json ? 'reference_set_id'
        WHERE iteration.iteration_id = task_record.iteration_id
    ) THEN
        RAISE EXCEPTION 'RANDOM_BASELINE 0.1.0/0.1.1 are audit-only; evaluation requires an approved-reference version'
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
                 WHERE reference_set.reference_set_id =
                       (config.config_json ->> 'reference_set_id')::uuid
                 ORDER BY signal.signal_time)
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_random_baseline_signal_strata stratum USING (entry_event_id)
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = entry.generating_iteration_id
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id
     AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config
      ON config.config_version_id = binding.config_version_id AND config.status = 'READY'
    WHERE entry.entry_event_id = p_entry_event_id
      AND entry.generating_iteration_id = task_record.iteration_id
      AND entry.status = 'COMPLETE';
END
$$;

ALTER FUNCTION strategy_training.guard_training_random_baseline_v012()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_model_a_candidate_scan_random_config(uuid, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_baseline_evaluation_context(uuid, uuid, char(64))
OWNER TO tb2_training_owner;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '067_training_random_baseline_version_progression',
    encode(public.digest(
        'auto_trade_v2_067_training_random_baseline_version_progression_v1',
        'sha256'
    ), 'hex'),
    'Allow new immutable random-baseline reference versions while retaining 0.1.0/0.1.1 as audit-only'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
