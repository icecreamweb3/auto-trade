\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- The persisted inclusion probability is numeric(18, 12).  Compare against
-- the expected ratio at that same scale so non-terminating ratios such as 5/15
-- are accepted canonically instead of being rejected before the column cast.
CREATE OR REPLACE FUNCTION strategy_training.record_training_random_baseline(
    p_matched_entry_event_id char(64),
    p_random_baseline_config_version_id uuid,
    p_matching_stratum jsonb,
    p_selected_candidate_ids jsonb,
    p_sampling_frame_size integer,
    p_inclusion_probability numeric,
    p_random_seed bigint,
    p_sampling_frame_hash char(64),
    p_overlap_excluded_count integer
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
DECLARE
    new_id uuid := gen_random_uuid();
    config_record strategy_training.training_config_versions%ROWTYPE;
    bound_experiment_id uuid;
    selected_count integer;
    expected_inclusion_probability numeric(18, 12);
BEGIN
    SELECT * INTO STRICT config_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_random_baseline_config_version_id;
    IF config_record.config_type <> 'RANDOM_BASELINE'
       OR config_record.status <> 'READY'
       OR NOT config_record.config_json ?& ARRAY[
           'sample_count', 'minimum_frame_size', 'exclusion_window_seconds',
           'matching_fields'
       ] THEN
        RAISE EXCEPTION 'random baseline requires an explicit READY config'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.experiment_id INTO STRICT bound_experiment_id
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = entry.generating_iteration_id
    WHERE entry.entry_event_id = p_matched_entry_event_id
      AND entry.status = 'COMPLETE';
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_experiment_config_bindings
        WHERE training_experiment_config_bindings.experiment_id = bound_experiment_id
          AND config_type = 'RANDOM_BASELINE'
          AND config_version_id = p_random_baseline_config_version_id
    ) THEN
        RAISE EXCEPTION 'random-baseline config is not frozen on the experiment'
            USING ERRCODE = '23514';
    END IF;
    selected_count := jsonb_array_length(p_selected_candidate_ids);
    expected_inclusion_probability := round(
        selected_count::numeric / p_sampling_frame_size,
        12
    );
    IF p_sampling_frame_size <
           (config_record.config_json ->> 'minimum_frame_size')::integer
       OR selected_count > (config_record.config_json ->> 'sample_count')::integer
       OR p_inclusion_probability <> expected_inclusion_probability
       OR (SELECT count(*) FROM jsonb_array_elements_text(p_selected_candidate_ids)) <>
          (SELECT count(DISTINCT value)
           FROM jsonb_array_elements_text(p_selected_candidate_ids)
                AS selected_candidate(value)) THEN
        RAISE EXCEPTION 'random-baseline frame/probability violates its READY config'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_random_entry_baselines (
        random_baseline_id, matched_entry_event_id,
        random_baseline_config_version_id, matching_stratum,
        selected_candidate_ids, sampling_frame_size, inclusion_probability,
        random_seed, sampling_frame_hash, overlap_excluded_count
    ) VALUES (
        new_id, p_matched_entry_event_id,
        p_random_baseline_config_version_id, p_matching_stratum,
        p_selected_candidate_ids, p_sampling_frame_size,
        expected_inclusion_probability,
        p_random_seed, p_sampling_frame_hash, p_overlap_excluded_count
    );
    RETURN new_id;
END
$$;

ALTER FUNCTION strategy_training.record_training_random_baseline(
    char(64), uuid, jsonb, jsonb, integer, numeric, bigint, char(64), integer
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.record_training_random_baseline(
    char(64), uuid, jsonb, jsonb, integer, numeric, bigint, char(64), integer
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.record_training_random_baseline(
    char(64), uuid, jsonb, jsonb, integer, numeric, bigint, char(64), integer
) TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '070_training_random_baseline_probability_precision',
    encode(public.digest(
        'auto_trade_v2_070_training_random_baseline_probability_precision_v1',
        'sha256'
    ), 'hex'),
    'Align random-baseline inclusion probability checks with numeric(18,12) storage precision'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
