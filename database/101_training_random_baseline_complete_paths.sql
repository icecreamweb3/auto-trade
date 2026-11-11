\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

ALTER TABLE strategy_training.training_random_baseline_reference_sets
    ADD COLUMN candidate_path_policy varchar(64) NOT NULL
        DEFAULT 'LEGACY_UNFILTERED'
        CHECK (candidate_path_policy IN (
            'LEGACY_UNFILTERED', 'COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF'
        )),
    ADD COLUMN source_reference_set_id uuid
        REFERENCES strategy_training.training_random_baseline_reference_sets;

ALTER TABLE strategy_training.training_random_baseline_reference_sets
    ADD CONSTRAINT training_random_baseline_reference_path_lineage_check
    CHECK (
        (candidate_path_policy = 'LEGACY_UNFILTERED'
            AND source_reference_set_id IS NULL)
        OR
        (candidate_path_policy = 'COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF'
            AND source_reference_set_id IS NOT NULL
            AND source_reference_set_id <> reference_set_id)
    );

CREATE UNIQUE INDEX ux_training_random_baseline_complete_path_source
ON strategy_training.training_random_baseline_reference_sets (source_reference_set_id)
WHERE source_reference_set_id IS NOT NULL;

CREATE TABLE strategy_training.training_random_baseline_reference_candidate_paths (
    reference_set_id       uuid NOT NULL
                           REFERENCES strategy_training.training_random_baseline_reference_sets,
    candidate_id           char(64) NOT NULL
                           REFERENCES strategy_training.training_random_baseline_candidates,
    expected_bar_count     integer NOT NULL CHECK (expected_bar_count > 0),
    observed_bar_count     integer NOT NULL CHECK (observed_bar_count >= 0),
    first_observed_at      timestamptz,
    endpoint_observed_at   timestamptz,
    is_complete            boolean NOT NULL,
    evidence_hash          char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (reference_set_id, candidate_id),
    CHECK (
        (observed_bar_count = 0
            AND first_observed_at IS NULL AND endpoint_observed_at IS NULL)
        OR
        (observed_bar_count > 0
            AND first_observed_at IS NOT NULL AND endpoint_observed_at IS NOT NULL)
    ),
    CHECK (NOT is_complete OR observed_bar_count = expected_bar_count)
);

CREATE TRIGGER trg_training_random_baseline_reference_candidate_paths_append_only
BEFORE UPDATE OR DELETE
ON strategy_training.training_random_baseline_reference_candidate_paths
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE OR REPLACE FUNCTION strategy_training.rebuild_training_random_baseline_reference_complete_paths(
    p_source_reference_set_id uuid,
    p_created_by text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $function$
DECLARE
    source_record strategy_training.training_random_baseline_reference_sets%ROWTYPE;
    new_reference_set_id uuid := gen_random_uuid();
    existing_reference_set_id uuid;
    complete_candidate_count integer;
    complete_candidate_hash char(64);
BEGIN
    IF btrim(p_created_by) = '' THEN
        RAISE EXCEPTION 'reference rebuild actor must not be blank'
            USING ERRCODE = '23514';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('random_baseline_complete_path:' || p_source_reference_set_id::text, 0)
    );

    SELECT * INTO STRICT source_record
    FROM strategy_training.training_random_baseline_reference_sets
    WHERE reference_set_id = p_source_reference_set_id
      AND status = 'READY';

    IF source_record.candidate_path_policy <> 'LEGACY_UNFILTERED' THEN
        RAISE EXCEPTION 'complete-path rebuild requires a legacy source reference set'
            USING ERRCODE = '23514';
    END IF;

    SELECT reference_set_id INTO existing_reference_set_id
    FROM strategy_training.training_random_baseline_reference_sets
    WHERE source_reference_set_id = p_source_reference_set_id;
    IF FOUND THEN
        RETURN existing_reference_set_id;
    END IF;

    DROP TABLE IF EXISTS pg_temp.training_random_candidate_path_facts;
    CREATE TEMP TABLE training_random_candidate_path_facts (
        candidate_id char(64) PRIMARY KEY,
        expected_bar_count integer NOT NULL,
        observed_bar_count integer NOT NULL,
        first_observed_at timestamptz,
        endpoint_observed_at timestamptz,
        is_complete boolean NOT NULL,
        evidence_hash char(64) NOT NULL
    ) ON COMMIT DROP;

    INSERT INTO training_random_candidate_path_facts (
        candidate_id, expected_bar_count, observed_bar_count,
        first_observed_at, endpoint_observed_at, is_complete, evidence_hash
    )
    WITH source_candidates AS MATERIALIZED (
        SELECT DISTINCT candidate.candidate_id, candidate.instrument_id,
               candidate.entry_time, candidate.dataset_version_id,
               dataset.interval_seconds, dataset.label_horizon_duration,
               dataset.source_as_of_at
        FROM strategy_training.training_random_baseline_reference_support support
        CROSS JOIN LATERAL jsonb_array_elements_text(support.candidate_ids) selected(candidate_id)
        JOIN strategy_training.training_random_baseline_candidates candidate
          ON candidate.candidate_id = selected.candidate_id::char(64)
        JOIN strategy_training.training_dataset_versions dataset
          ON dataset.dataset_version_id = candidate.dataset_version_id
         AND dataset.dataset_version_id = source_record.dataset_version_id
         AND dataset.status = 'READY'
        WHERE support.reference_set_id = p_source_reference_set_id
    ), measured AS (
        SELECT candidate.*,
               (extract(epoch FROM candidate.label_horizon_duration)
                    / candidate.interval_seconds)::integer AS expected_count,
               COALESCE(path.observed_count, 0)::integer AS observed_count,
               path.first_observed_at,
               path.endpoint_observed_at
        FROM source_candidates candidate
        LEFT JOIN LATERAL (
            SELECT count(*)::integer AS observed_count,
                   min(selected.close_time) AS first_observed_at,
                   max(selected.close_time) AS endpoint_observed_at
            FROM (
                SELECT DISTINCT ON (bar.open_time) bar.open_time, bar.close_time
                FROM market.klines bar
                WHERE bar.instrument_id = candidate.instrument_id
                  AND bar.price_type = 'TRADE'
                  AND bar.interval_seconds = candidate.interval_seconds
                  AND bar.open_time >= candidate.entry_time
                  AND bar.open_time < candidate.entry_time
                                         + candidate.label_horizon_duration
                  AND bar.close_time <= candidate.entry_time
                                          + candidate.label_horizon_duration
                  AND bar.effective_at <= candidate.source_as_of_at
                  AND bar.is_closed
                  AND bar.quality_status = 'VALID'
                ORDER BY bar.open_time, bar.revision_no DESC,
                         bar.effective_at DESC, bar.collected_at DESC
            ) selected
        ) path ON true
    ), classified AS (
        SELECT measured.*,
               measured.observed_count = measured.expected_count
               AND measured.first_observed_at = measured.entry_time
                    + make_interval(secs => measured.interval_seconds)
               AND measured.endpoint_observed_at = measured.entry_time
                    + measured.label_horizon_duration AS complete
        FROM measured
    )
    SELECT candidate_id, expected_count, observed_count,
           first_observed_at, endpoint_observed_at, complete,
           encode(public.digest(jsonb_build_object(
               'candidate_id', candidate_id,
               'dataset_version_id', dataset_version_id,
               'endpoint_observed_at', endpoint_observed_at,
               'expected_bar_count', expected_count,
               'first_observed_at', first_observed_at,
               'is_complete', complete,
               'observed_bar_count', observed_count,
               'source_as_of_at', source_as_of_at
           )::text, 'sha256'), 'hex')
    FROM classified;

    SELECT count(*)::integer,
           encode(public.digest(string_agg(candidate_id::text, E'\n' ORDER BY candidate_id),
                                'sha256'), 'hex')
    INTO complete_candidate_count, complete_candidate_hash
    FROM training_random_candidate_path_facts
    WHERE is_complete;

    IF complete_candidate_count = 0 OR complete_candidate_hash IS NULL THEN
        RAISE EXCEPTION 'complete-path rebuild produced no eligible candidates'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO strategy_training.training_random_baseline_reference_sets (
        reference_set_id, dataset_version_id, reference_iteration_id,
        source_config_version_id, reference_signal_set_hash,
        reference_candidate_set_hash, signal_count, candidate_count,
        time_bucket_hours, exclusion_window_seconds, maximum_frame_candidates,
        random_seed, status, approval_basis, created_by,
        candidate_path_policy, source_reference_set_id
    ) VALUES (
        new_reference_set_id, source_record.dataset_version_id,
        source_record.reference_iteration_id, source_record.source_config_version_id,
        source_record.reference_signal_set_hash, complete_candidate_hash,
        source_record.signal_count, complete_candidate_count,
        source_record.time_bucket_hours, source_record.exclusion_window_seconds,
        source_record.maximum_frame_candidates, source_record.random_seed,
        'READY', 'FEASIBILITY_AND_COVERAGE_ONLY_NO_OUTCOME_METRICS', p_created_by,
        'COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF', p_source_reference_set_id
    );

    INSERT INTO strategy_training.training_random_baseline_reference_candidate_paths (
        reference_set_id, candidate_id, expected_bar_count, observed_bar_count,
        first_observed_at, endpoint_observed_at, is_complete, evidence_hash
    )
    SELECT new_reference_set_id, candidate_id, expected_bar_count, observed_bar_count,
           first_observed_at, endpoint_observed_at, is_complete, evidence_hash
    FROM training_random_candidate_path_facts;

    INSERT INTO strategy_training.training_random_baseline_reference_support (
        reference_set_id, instrument_id, pool_identity, time_bucket,
        volatility_bucket, liquidity_bucket, btc_regime,
        eligible_candidate_count, candidate_ids, candidate_frame_hash
    )
    SELECT new_reference_set_id, support.instrument_id, support.pool_identity,
           support.time_bucket, support.volatility_bucket, support.liquidity_bucket,
           support.btc_regime, count(*)::integer,
           jsonb_agg(to_jsonb(candidate.candidate_id::text) ORDER BY candidate.candidate_id),
           encode(public.digest(string_agg(candidate.candidate_id::text || '|' ||
               to_char(candidate.observed_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               E'\n' ORDER BY candidate.candidate_id), 'sha256'), 'hex')
    FROM strategy_training.training_random_baseline_reference_support support
    CROSS JOIN LATERAL jsonb_array_elements_text(support.candidate_ids) selected(candidate_id)
    JOIN training_random_candidate_path_facts path
      ON path.candidate_id = selected.candidate_id::char(64)
     AND path.is_complete
    JOIN strategy_training.training_random_baseline_candidates candidate
      ON candidate.candidate_id = path.candidate_id
    WHERE support.reference_set_id = p_source_reference_set_id
    GROUP BY support.instrument_id, support.pool_identity, support.time_bucket,
             support.volatility_bucket, support.liquidity_bucket, support.btc_regime;

    RETURN new_reference_set_id;
END
$function$;

-- Preserve the old implementation for immutable audit reconstruction, but do
-- not expose it to application roles.  The public sealing entry point now
-- returns only a complete-path reference set.
ALTER FUNCTION strategy_training.seal_training_random_baseline_reference_set(
    uuid, integer, integer, integer, bigint, text
) RENAME TO seal_training_random_baseline_reference_set_legacy;

CREATE FUNCTION strategy_training.seal_training_random_baseline_reference_set(
    p_reference_iteration_id uuid,
    p_time_bucket_hours integer,
    p_exclusion_window_seconds integer,
    p_maximum_frame_candidates integer,
    p_random_seed bigint,
    p_created_by text
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE legacy_reference_set_id uuid;
BEGIN
    legacy_reference_set_id :=
        strategy_training.seal_training_random_baseline_reference_set_legacy(
            p_reference_iteration_id, p_time_bucket_hours,
            p_exclusion_window_seconds, p_maximum_frame_candidates,
            p_random_seed, p_created_by
        );
    RETURN strategy_training.rebuild_training_random_baseline_reference_complete_paths(
        legacy_reference_set_id, p_created_by
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_complete_path_config()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF NEW.config_type = 'RANDOM_BASELINE'
       AND NEW.status = 'READY'
       AND NEW.semver::text NOT IN ('0.1.0', '0.1.1')
       AND NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_random_baseline_reference_sets reference_set
           WHERE reference_set.reference_set_id =
                    (NEW.config_json ->> 'reference_set_id')::uuid
             AND reference_set.status = 'READY'
             AND reference_set.candidate_path_policy =
                    'COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF'
       ) THEN
        RAISE EXCEPTION 'READY RANDOM_BASELINE requires a complete-path reference set'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_random_baseline_complete_path_config
BEFORE INSERT OR UPDATE ON strategy_training.training_config_versions
FOR EACH ROW EXECUTE FUNCTION
    strategy_training.guard_training_random_baseline_complete_path_config();

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_complete_path_binding()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF NEW.config_type = 'RANDOM_BASELINE'
       AND NOT EXISTS (
           SELECT 1
           FROM strategy_training.training_config_versions config
           JOIN strategy_training.training_random_baseline_reference_sets reference_set
             ON reference_set.reference_set_id =
                    (config.config_json ->> 'reference_set_id')::uuid
           WHERE config.config_version_id = NEW.config_version_id
             AND config.status = 'READY'
             AND reference_set.status = 'READY'
             AND reference_set.candidate_path_policy =
                    'COMPLETE_LABEL_WINDOW_AT_SOURCE_AS_OF'
       ) THEN
        RAISE EXCEPTION 'new RANDOM_BASELINE binding requires a complete-path reference set'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_random_baseline_complete_path_binding
BEFORE INSERT OR UPDATE ON strategy_training.training_experiment_config_bindings
FOR EACH ROW EXECUTE FUNCTION
    strategy_training.guard_training_random_baseline_complete_path_binding();

ALTER TABLE strategy_training.training_random_baseline_reference_candidate_paths
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.rebuild_training_random_baseline_reference_complete_paths(
    uuid, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.seal_training_random_baseline_reference_set_legacy(
    uuid, integer, integer, integer, bigint, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.seal_training_random_baseline_reference_set(
    uuid, integer, integer, integer, bigint, text
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_random_baseline_complete_path_config()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_random_baseline_complete_path_binding()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_random_baseline_reference_candidate_paths
FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.rebuild_training_random_baseline_reference_complete_paths(uuid, text),
    strategy_training.seal_training_random_baseline_reference_set_legacy(
        uuid, integer, integer, integer, bigint, text
    ),
    strategy_training.seal_training_random_baseline_reference_set(
        uuid, integer, integer, integer, bigint, text
    )
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION
    strategy_training.seal_training_random_baseline_reference_set_legacy(
        uuid, integer, integer, integer, bigint, text
    )
FROM tb2_training_rw;

GRANT SELECT ON strategy_training.training_random_baseline_reference_candidate_paths
TO tb2_training_rw, tb2_training_orchestrator, tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.rebuild_training_random_baseline_reference_complete_paths(uuid, text),
    strategy_training.seal_training_random_baseline_reference_set(
        uuid, integer, integer, integer, bigint, text
    )
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '101_training_random_baseline_complete_paths',
    encode(public.digest(
        'auto_trade_v2_101_training_random_baseline_complete_paths_v1',
        'sha256'
    ), 'hex'),
    'Exclude incomplete 24-hour candidate paths before freezing random-baseline support'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
