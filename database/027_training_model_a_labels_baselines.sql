\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_entry_outcomes (
    entry_event_id          char(64) PRIMARY KEY
                            REFERENCES strategy_training.training_entry_events,
    holding_rule_version_id uuid NOT NULL
                            REFERENCES strategy_training.training_config_versions,
    label_window_end_at     timestamptz NOT NULL,
    interval_seconds        integer NOT NULL CHECK (interval_seconds > 0),
    expected_bar_count      integer NOT NULL CHECK (expected_bar_count > 0),
    observed_bar_count      integer NOT NULL CHECK (observed_bar_count >= 0),
    missing_bar_count       integer NOT NULL CHECK (missing_bar_count >= 0),
    is_complete             boolean NOT NULL,
    incomplete_reason       text,
    mfe_percent             numeric,
    mae_percent             numeric,
    return_percent          numeric,
    mfe_reached_at          timestamptz,
    mae_reached_at          timestamptz,
    endpoint_observed_at    timestamptz,
    path_fingerprint        char(64) NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (observed_bar_count + missing_bar_count = expected_bar_count),
    CHECK (path_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK (
        (is_complete AND missing_bar_count = 0 AND incomplete_reason IS NULL
                     AND mfe_percent IS NOT NULL AND mfe_percent >= 0
                     AND mae_percent IS NOT NULL AND mae_percent >= 0
                     AND return_percent IS NOT NULL
                     AND mfe_reached_at IS NOT NULL AND mae_reached_at IS NOT NULL
                     AND endpoint_observed_at = label_window_end_at)
        OR (NOT is_complete AND incomplete_reason IS NOT NULL
                            AND btrim(incomplete_reason) <> ''
                            AND mfe_percent IS NULL AND mae_percent IS NULL
                            AND return_percent IS NULL
                            AND mfe_reached_at IS NULL AND mae_reached_at IS NULL)
    )
);

CREATE TABLE strategy_training.training_opportunity_events (
    entry_event_id                    char(64) PRIMARY KEY
                                      REFERENCES strategy_training.training_entry_events,
    opportunity_definition_version_id uuid NOT NULL
                                      REFERENCES strategy_training.training_config_versions,
    is_opportunity                    boolean NOT NULL,
    reason_codes                      jsonb NOT NULL,
    truth_fingerprint                 char(64) NOT NULL,
    created_at                        timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(reason_codes) = 'array'),
    CHECK (truth_fingerprint ~ '^[0-9a-f]{64}$'),
    CHECK ((is_opportunity AND reason_codes = '[]'::jsonb) OR NOT is_opportunity)
);

CREATE TABLE strategy_training.training_random_entry_baselines (
    random_baseline_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    matched_entry_event_id          char(64) NOT NULL UNIQUE
                                    REFERENCES strategy_training.training_entry_events,
    random_baseline_config_version_id uuid NOT NULL
                                    REFERENCES strategy_training.training_config_versions,
    matching_stratum                jsonb NOT NULL,
    selected_candidate_ids          jsonb NOT NULL,
    sampling_frame_size             integer NOT NULL CHECK (sampling_frame_size > 0),
    inclusion_probability           numeric(18, 12) NOT NULL
                                    CHECK (inclusion_probability > 0
                                           AND inclusion_probability <= 1),
    random_seed                     bigint NOT NULL,
    sampling_frame_hash             char(64) NOT NULL,
    overlap_excluded_count          integer NOT NULL CHECK (overlap_excluded_count >= 0),
    created_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(matching_stratum) = 'object'
           AND matching_stratum <> '{}'::jsonb),
    CHECK (jsonb_typeof(selected_candidate_ids) = 'array'
           AND jsonb_array_length(selected_candidate_ids) > 0),
    CHECK (sampling_frame_hash ~ '^[0-9a-f]{64}$')
);

CREATE OR REPLACE FUNCTION strategy_training.training_entry_outcome_bars(
    p_entry_event_id char(64)
)
RETURNS TABLE (
    observed_at timestamptz,
    high_price numeric,
    low_price numeric,
    close_price numeric,
    revision_no integer,
    payload_hash char(64)
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core
AS $$
    WITH contract AS (
        SELECT entry.instrument_id, entry.entry_time,
               entry.entry_time + dataset.label_horizon_duration AS label_end,
               dataset.interval_seconds, dataset.source_as_of_at
        FROM strategy_training.training_entry_events entry
        JOIN strategy_training.training_dataset_versions dataset
          ON dataset.dataset_version_id = entry.dataset_version_id
        WHERE entry.entry_event_id = p_entry_event_id
          AND entry.status = 'COMPLETE' AND dataset.status = 'READY'
    ), ranked AS (
        SELECT kline.close_time AS selected_observed_at,
               kline.high_price AS selected_high_price,
               kline.low_price AS selected_low_price,
               kline.close_price AS selected_close_price,
               kline.revision_no AS selected_revision_no,
               kline.payload_hash AS selected_payload_hash,
               row_number() OVER (
                   PARTITION BY kline.open_time
                   ORDER BY kline.revision_no DESC, kline.effective_at DESC,
                            kline.collected_at DESC
               ) AS revision_rank
        FROM contract
        JOIN market.klines kline
          ON kline.instrument_id = contract.instrument_id
         AND kline.price_type = 'TRADE'
         AND kline.interval_seconds = contract.interval_seconds
         AND kline.open_time >= contract.entry_time
         AND kline.close_time <= contract.label_end
         AND kline.effective_at <= contract.source_as_of_at
        WHERE kline.is_closed AND kline.quality_status = 'VALID'
    )
    SELECT selected_observed_at, selected_high_price, selected_low_price,
           selected_close_price, selected_revision_no, selected_payload_hash
    FROM ranked WHERE revision_rank = 1
    ORDER BY selected_observed_at
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_entry_outcome_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    entry_record strategy_training.training_entry_events%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    computed_expected integer;
BEGIN
    SELECT * INTO STRICT entry_record
    FROM strategy_training.training_entry_events
    WHERE entry_event_id = NEW.entry_event_id;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = entry_record.dataset_version_id;
    IF entry_record.status <> 'COMPLETE' OR dataset_record.status <> 'READY' THEN
        RAISE EXCEPTION 'labels require a COMPLETE entry on a READY dataset'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.holding_rule_version_id <> dataset_record.holding_rule_version_id
       OR NEW.interval_seconds <> dataset_record.interval_seconds
       OR NEW.label_window_end_at <> entry_record.entry_time
            + dataset_record.label_horizon_duration
       OR NEW.label_window_end_at > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'label window/version does not match its dataset contract'
            USING ERRCODE = '23514';
    END IF;
    computed_expected := extract(epoch FROM
        (NEW.label_window_end_at - entry_record.entry_time)
    )::integer / NEW.interval_seconds;
    IF NEW.expected_bar_count <> computed_expected THEN
        RAISE EXCEPTION 'label expected_bar_count does not match the governed window'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.mfe_reached_at IS NOT NULL AND (
        NEW.mfe_reached_at < entry_record.entry_time
        OR NEW.mfe_reached_at > NEW.label_window_end_at
    ) OR NEW.mae_reached_at IS NOT NULL AND (
        NEW.mae_reached_at < entry_record.entry_time
        OR NEW.mae_reached_at > NEW.label_window_end_at
    ) THEN
        RAISE EXCEPTION 'label extreme time lies outside the label window'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_entry_outcome(
    p_entry_event_id char(64),
    p_holding_rule_version_id uuid,
    p_label_window_end_at timestamptz,
    p_interval_seconds integer,
    p_expected_bar_count integer,
    p_observed_bar_count integer,
    p_missing_bar_count integer,
    p_is_complete boolean,
    p_incomplete_reason text,
    p_mfe_percent numeric,
    p_mae_percent numeric,
    p_return_percent numeric,
    p_mfe_reached_at timestamptz,
    p_mae_reached_at timestamptz,
    p_endpoint_observed_at timestamptz,
    p_path_fingerprint char(64)
)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core
AS $$
    INSERT INTO strategy_training.training_entry_outcomes (
        entry_event_id, holding_rule_version_id, label_window_end_at,
        interval_seconds, expected_bar_count, observed_bar_count,
        missing_bar_count, is_complete, incomplete_reason,
        mfe_percent, mae_percent, return_percent, mfe_reached_at,
        mae_reached_at, endpoint_observed_at, path_fingerprint
    ) VALUES (
        p_entry_event_id, p_holding_rule_version_id, p_label_window_end_at,
        p_interval_seconds, p_expected_bar_count, p_observed_bar_count,
        p_missing_bar_count, p_is_complete, p_incomplete_reason,
        p_mfe_percent, p_mae_percent, p_return_percent, p_mfe_reached_at,
        p_mae_reached_at, p_endpoint_observed_at, p_path_fingerprint
    )
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_opportunity_event(
    p_entry_event_id char(64),
    p_opportunity_definition_version_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE
    outcome strategy_training.training_entry_outcomes%ROWTYPE;
    config_record strategy_training.training_config_versions%ROWTYPE;
    bound_experiment_id uuid;
    reasons jsonb := '[]'::jsonb;
    computed_is_opportunity boolean;
    computed_hash char(64);
BEGIN
    SELECT * INTO STRICT outcome
    FROM strategy_training.training_entry_outcomes
    WHERE entry_event_id = p_entry_event_id;
    IF NOT outcome.is_complete THEN
        RAISE EXCEPTION 'incomplete labels cannot become opportunity truth'
            USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT config_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = p_opportunity_definition_version_id;
    IF config_record.config_type <> 'OPPORTUNITY_DEFINITION'
       OR config_record.status <> 'READY'
       OR NOT config_record.config_json ?& ARRAY[
           'minimum_mfe_percent', 'maximum_mae_percent', 'minimum_return_percent'
       ] THEN
        RAISE EXCEPTION 'opportunity truth requires an explicit READY definition'
            USING ERRCODE = '23514';
    END IF;
    SELECT iteration.experiment_id INTO STRICT bound_experiment_id
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_iterations iteration
      ON iteration.iteration_id = entry.generating_iteration_id
    WHERE entry.entry_event_id = p_entry_event_id;
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_experiment_config_bindings
        WHERE training_experiment_config_bindings.experiment_id = bound_experiment_id
          AND config_type = 'OPPORTUNITY_DEFINITION'
          AND config_version_id = p_opportunity_definition_version_id
    ) THEN
        RAISE EXCEPTION 'opportunity definition is not frozen on the experiment'
            USING ERRCODE = '23514';
    END IF;
    IF outcome.mfe_percent <
       (config_record.config_json ->> 'minimum_mfe_percent')::numeric THEN
        reasons := reasons || '"MFE_BELOW_THRESHOLD"'::jsonb;
    END IF;
    IF outcome.mae_percent >
       (config_record.config_json ->> 'maximum_mae_percent')::numeric THEN
        reasons := reasons || '"MAE_ABOVE_THRESHOLD"'::jsonb;
    END IF;
    IF outcome.return_percent <
       (config_record.config_json ->> 'minimum_return_percent')::numeric THEN
        reasons := reasons || '"RETURN_BELOW_THRESHOLD"'::jsonb;
    END IF;
    computed_is_opportunity := jsonb_array_length(reasons) = 0;
    computed_hash := encode(public.digest(jsonb_build_object(
        'entry_event_id', p_entry_event_id,
        'is_opportunity', computed_is_opportunity,
        'opportunity_rule_version_id', p_opportunity_definition_version_id,
        'path_fingerprint', outcome.path_fingerprint,
        'reason_codes', reasons
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_opportunity_events (
        entry_event_id, opportunity_definition_version_id,
        is_opportunity, reason_codes, truth_fingerprint
    ) VALUES (
        p_entry_event_id, p_opportunity_definition_version_id,
        computed_is_opportunity, reasons, computed_hash
    );
END
$$;

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
    IF p_sampling_frame_size <
           (config_record.config_json ->> 'minimum_frame_size')::integer
       OR selected_count > (config_record.config_json ->> 'sample_count')::integer
       OR p_inclusion_probability <>
           selected_count::numeric / p_sampling_frame_size
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
        p_selected_candidate_ids, p_sampling_frame_size, p_inclusion_probability,
        p_random_seed, p_sampling_frame_hash, p_overlap_excluded_count
    );
    RETURN new_id;
END
$$;

CREATE TRIGGER trg_training_entry_outcome_insert_guard
BEFORE INSERT ON strategy_training.training_entry_outcomes
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_entry_outcome_insert();

CREATE TRIGGER trg_training_entry_outcome_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_entry_outcomes
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_opportunity_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_opportunity_events
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_random_baseline_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_entry_baselines
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_entry_outcomes OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_opportunity_events OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_random_entry_baselines OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_entry_outcome_bars(char(64))
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_entry_outcome_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_entry_outcome(
    char(64), uuid, timestamptz, integer, integer, integer, integer,
    boolean, text, numeric, numeric, numeric, timestamptz, timestamptz,
    timestamptz, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_opportunity_event(char(64), uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_random_baseline(
    char(64), uuid, jsonb, jsonb, integer, numeric, bigint, char(64), integer
) OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON strategy_training.training_entry_outcomes,
    strategy_training.training_opportunity_events,
    strategy_training.training_random_entry_baselines
TO tb2_training_evaluator;

GRANT EXECUTE ON FUNCTION
    strategy_training.training_entry_outcome_bars(char(64)),
    strategy_training.record_training_entry_outcome(
        char(64), uuid, timestamptz, integer, integer, integer, integer,
        boolean, text, numeric, numeric, numeric, timestamptz, timestamptz,
        timestamptz, char(64)
    ),
    strategy_training.record_training_opportunity_event(char(64), uuid),
    strategy_training.record_training_random_baseline(
        char(64), uuid, jsonb, jsonb, integer, numeric, bigint, char(64), integer
    )
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '027_training_model_a_labels_baselines',
    encode(digest('auto_trade_v2_027_training_model_a_labels_baselines_v1', 'sha256'), 'hex'),
    'Add isolated model-A labels, opportunity truth and matched random baselines'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
