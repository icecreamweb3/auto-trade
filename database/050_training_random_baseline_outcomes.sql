\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_random_baseline_candidate_outcomes (
    candidate_id            char(64) NOT NULL
                            REFERENCES strategy_training.training_random_baseline_candidates,
    matched_entry_event_id  char(64) NOT NULL
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
    path_fingerprint        char(64) NOT NULL CHECK (path_fingerprint ~ '^[0-9a-f]{64}$'),
    created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (candidate_id, matched_entry_event_id),
    CHECK (observed_bar_count + missing_bar_count = expected_bar_count),
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
    task_record strategy_training.training_tasks%ROWTYPE;
    candidate_record strategy_training.training_random_baseline_candidates%ROWTYPE;
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    entry_price_value numeric;
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks task
    WHERE task.task_id = p_task_id;
    IF task_record.state <> 'RUNNING'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp()
       OR NOT EXISTS (
            SELECT 1 FROM strategy_training.training_entry_events entry
            WHERE entry.entry_event_id = p_matched_entry_event_id
              AND entry.generating_iteration_id = task_record.iteration_id
              AND entry.status = 'COMPLETE'
       ) THEN
        RAISE EXCEPTION 'random outcome context requires its active evaluator lease'
            USING ERRCODE = '40001';
    END IF;
    SELECT * INTO STRICT candidate_record
    FROM strategy_training.training_random_baseline_candidates candidate
    WHERE candidate.candidate_id = p_candidate_id
      AND candidate.generating_iteration_id = task_record.iteration_id;
    SELECT * INTO STRICT dataset_record
    FROM strategy_training.training_dataset_versions dataset
    WHERE dataset.dataset_version_id = candidate_record.dataset_version_id;
    SELECT bar.open_price INTO STRICT entry_price_value
    FROM market.klines bar
    WHERE bar.instrument_id = candidate_record.instrument_id
      AND bar.price_type = 'TRADE'
      AND bar.interval_seconds = dataset_record.interval_seconds
      AND bar.open_time = candidate_record.entry_time
      AND bar.is_closed AND bar.quality_status = 'VALID'
      AND bar.effective_at <= dataset_record.source_as_of_at
    ORDER BY bar.revision_no DESC, bar.effective_at DESC, bar.collected_at DESC
    LIMIT 1;
    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN'
       OR candidate_record.entry_time + dataset_record.label_horizon_duration
          > dataset_record.partition_end_at THEN
        RAISE EXCEPTION 'random outcome requires a complete READY TRAIN label window'
            USING ERRCODE = '23514';
    END IF;
    RETURN QUERY SELECT dataset_record.partition::text,
        dataset_record.partition_start_at, dataset_record.partition_end_at,
        candidate_record.entry_time, entry_price_value,
        candidate_record.direction::text,
        candidate_record.entry_time + dataset_record.label_horizon_duration,
        dataset_record.interval_seconds, dataset_record.holding_rule_version_id;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_candidate_outcome_bars(
    p_task_id uuid, p_lease_token uuid, p_matched_entry_event_id char(64),
    p_candidate_id char(64)
)
RETURNS TABLE (
    observed_at timestamptz, high_price numeric,
    low_price numeric, close_price numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market
AS $$
    WITH context AS (
        SELECT evaluation.*, candidate.instrument_id, dataset.source_as_of_at
        FROM strategy_training.training_random_candidate_outcome_context(
            p_task_id, p_lease_token, p_matched_entry_event_id, p_candidate_id
        ) evaluation
        JOIN strategy_training.training_random_baseline_candidates candidate
          ON candidate.candidate_id = p_candidate_id
        JOIN strategy_training.training_dataset_versions dataset
          ON dataset.dataset_version_id = candidate.dataset_version_id
    ), ranked AS (
        SELECT bar.close_time AS observed_at, bar.high_price, bar.low_price,
               bar.close_price,
               row_number() OVER (
                   PARTITION BY bar.open_time
                   ORDER BY bar.revision_no DESC, bar.effective_at DESC,
                            bar.collected_at DESC
               ) AS revision_rank
        FROM context
        JOIN market.klines bar ON bar.instrument_id = context.instrument_id
         AND bar.price_type = 'TRADE'
         AND bar.interval_seconds = context.interval_seconds
         AND bar.open_time >= context.entry_time
         AND bar.close_time <= context.label_window_end_at
         AND bar.effective_at <= context.source_as_of_at
        WHERE bar.is_closed AND bar.quality_status = 'VALID'
    )
    SELECT observed_at, high_price, low_price, close_price
    FROM ranked WHERE revision_rank = 1 ORDER BY observed_at
$$;

CREATE OR REPLACE FUNCTION strategy_training.record_training_random_candidate_outcome(
    p_task_id uuid, p_lease_token uuid, p_matched_entry_event_id char(64),
    p_candidate_id char(64), p_holding_rule_version_id uuid,
    p_label_window_end_at timestamptz, p_interval_seconds integer,
    p_expected_bar_count integer, p_observed_bar_count integer,
    p_missing_bar_count integer, p_is_complete boolean,
    p_incomplete_reason text, p_mfe_percent numeric, p_mae_percent numeric,
    p_return_percent numeric, p_mfe_reached_at timestamptz,
    p_mae_reached_at timestamptz, p_endpoint_observed_at timestamptz,
    p_path_fingerprint char(64)
)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE context_record record;
BEGIN
    SELECT * INTO STRICT context_record
    FROM strategy_training.training_random_candidate_outcome_context(
        p_task_id, p_lease_token, p_matched_entry_event_id, p_candidate_id
    );
    IF p_holding_rule_version_id <> context_record.holding_rule_version_id
       OR p_label_window_end_at <> context_record.label_window_end_at
       OR p_interval_seconds <> context_record.interval_seconds
       OR p_expected_bar_count <> extract(epoch FROM
          (context_record.label_window_end_at - context_record.entry_time)
       )::integer / context_record.interval_seconds
       OR p_observed_bar_count + p_missing_bar_count <> p_expected_bar_count
       OR p_mfe_reached_at IS NOT NULL AND (
            p_mfe_reached_at < context_record.entry_time
            OR p_mfe_reached_at > p_label_window_end_at
       ) OR p_mae_reached_at IS NOT NULL AND (
            p_mae_reached_at < context_record.entry_time
            OR p_mae_reached_at > p_label_window_end_at
       ) THEN
        RAISE EXCEPTION 'random candidate outcome violates its governed contract'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO strategy_training.training_random_baseline_candidate_outcomes (
        candidate_id, matched_entry_event_id, holding_rule_version_id,
        label_window_end_at, interval_seconds, expected_bar_count,
        observed_bar_count, missing_bar_count, is_complete, incomplete_reason,
        mfe_percent, mae_percent, return_percent, mfe_reached_at,
        mae_reached_at, endpoint_observed_at, path_fingerprint
    ) VALUES (
        p_candidate_id, p_matched_entry_event_id, p_holding_rule_version_id,
        p_label_window_end_at, p_interval_seconds, p_expected_bar_count,
        p_observed_bar_count, p_missing_bar_count, p_is_complete,
        p_incomplete_reason, p_mfe_percent, p_mae_percent, p_return_percent,
        p_mfe_reached_at, p_mae_reached_at, p_endpoint_observed_at,
        p_path_fingerprint
    );
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_outcomes()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
DECLARE selected_count integer; complete_count integer;
BEGIN
    SELECT jsonb_array_length(NEW.selected_candidate_ids) INTO selected_count;
    SELECT count(*) INTO complete_count
    FROM jsonb_array_elements_text(NEW.selected_candidate_ids) selected(candidate_id)
    JOIN strategy_training.training_random_baseline_candidate_outcomes outcome
      ON outcome.candidate_id = selected.candidate_id::char(64)
     AND outcome.matched_entry_event_id = NEW.matched_entry_event_id
     AND outcome.is_complete;
    IF complete_count <> selected_count THEN
        RAISE EXCEPTION 'random baseline requires complete outcomes for every selected candidate'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_random_baseline_complete_outcomes
BEFORE INSERT ON strategy_training.training_random_entry_baselines
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_training_random_baseline_outcomes();

CREATE TRIGGER trg_training_random_baseline_candidate_outcomes_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_random_baseline_candidate_outcomes
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_random_baseline_candidate_outcomes
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_candidate_outcome_context(
    uuid, uuid, char(64), char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_candidate_outcome_bars(
    uuid, uuid, char(64), char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.record_training_random_candidate_outcome(
    uuid, uuid, char(64), char(64), uuid, timestamptz, integer,
    integer, integer, integer, boolean, text, numeric, numeric, numeric,
    timestamptz, timestamptz, timestamptz, char(64)
) OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_training_random_baseline_outcomes()
OWNER TO tb2_training_owner;

REVOKE ALL ON strategy_training.training_random_baseline_candidate_outcomes FROM PUBLIC;
REVOKE ALL ON FUNCTION
    strategy_training.training_random_candidate_outcome_context(
        uuid, uuid, char(64), char(64)
    ),
    strategy_training.training_random_candidate_outcome_bars(
        uuid, uuid, char(64), char(64)
    ),
    strategy_training.record_training_random_candidate_outcome(
        uuid, uuid, char(64), char(64), uuid, timestamptz, integer,
        integer, integer, integer, boolean, text, numeric, numeric, numeric,
        timestamptz, timestamptz, timestamptz, char(64)
    ),
    strategy_training.guard_training_random_baseline_outcomes()
FROM PUBLIC;
GRANT SELECT ON strategy_training.training_random_baseline_candidate_outcomes
TO tb2_training_evaluator;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_random_candidate_outcome_context(
        uuid, uuid, char(64), char(64)
    ),
    strategy_training.training_random_candidate_outcome_bars(
        uuid, uuid, char(64), char(64)
    ),
    strategy_training.record_training_random_candidate_outcome(
        uuid, uuid, char(64), char(64), uuid, timestamptz, integer,
        integer, integer, integer, boolean, text, numeric, numeric, numeric,
        timestamptz, timestamptz, timestamptz, char(64)
    )
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '050_training_random_baseline_outcomes',
    encode(digest('auto_trade_v2_050_training_random_baseline_outcomes_v1', 'sha256'), 'hex'),
    'Persist leased future-path outcomes for selected matched random candidates'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
