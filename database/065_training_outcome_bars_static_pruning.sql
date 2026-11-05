\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Resolve governed event context before planning the TimescaleDB read.  Typed
-- literals let the planner prune every kline chunk outside the 24-hour label
-- window instead of expanding the parameterized SQL function across history.
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
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core
AS $function$
DECLARE
    instrument_id_value bigint;
    entry_time_value timestamptz;
    label_end_value timestamptz;
    interval_seconds_value integer;
    source_as_of_value timestamptz;
BEGIN
    SELECT entry.instrument_id,
           entry.entry_time,
           entry.entry_time + dataset.label_horizon_duration,
           dataset.interval_seconds,
           dataset.source_as_of_at
    INTO STRICT instrument_id_value, entry_time_value, label_end_value,
                interval_seconds_value, source_as_of_value
    FROM strategy_training.training_entry_events entry
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = entry.dataset_version_id
    WHERE entry.entry_event_id = p_entry_event_id
      AND entry.status = 'COMPLETE'
      AND dataset.status = 'READY';

    RETURN QUERY EXECUTE format(
        $query$
        SELECT DISTINCT ON (bar.open_time)
               bar.close_time, bar.high_price, bar.low_price, bar.close_price,
               bar.revision_no, bar.payload_hash
        FROM market.klines bar
        WHERE bar.instrument_id = %1$L::bigint
          AND bar.price_type = 'TRADE'
          AND bar.interval_seconds = %2$L::integer
          AND bar.open_time >= %3$L::timestamptz
          AND bar.open_time < %4$L::timestamptz
          AND bar.close_time <= %4$L::timestamptz
          AND bar.effective_at <= %5$L::timestamptz
          AND bar.is_closed
          AND bar.quality_status = 'VALID'
        ORDER BY bar.open_time, bar.revision_no DESC,
                 bar.effective_at DESC, bar.collected_at DESC
        $query$,
        instrument_id_value,
        interval_seconds_value,
        entry_time_value,
        label_end_value,
        source_as_of_value
    );
END
$function$;

CREATE OR REPLACE FUNCTION strategy_training.training_random_candidate_outcome_bars(
    p_task_id uuid, p_lease_token uuid, p_matched_entry_event_id char(64),
    p_candidate_id char(64)
)
RETURNS TABLE (
    observed_at timestamptz, high_price numeric,
    low_price numeric, close_price numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market
AS $function$
DECLARE
    instrument_id_value bigint;
    entry_time_value timestamptz;
    label_end_value timestamptz;
    interval_seconds_value integer;
    source_as_of_value timestamptz;
BEGIN
    SELECT candidate.instrument_id, evaluation.entry_time,
           evaluation.label_window_end_at, evaluation.interval_seconds,
           dataset.source_as_of_at
    INTO STRICT instrument_id_value, entry_time_value, label_end_value,
                interval_seconds_value, source_as_of_value
    FROM strategy_training.training_random_candidate_outcome_context(
        p_task_id, p_lease_token, p_matched_entry_event_id, p_candidate_id
    ) evaluation
    JOIN strategy_training.training_random_baseline_candidates candidate
      ON candidate.candidate_id = p_candidate_id
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = candidate.dataset_version_id;

    RETURN QUERY EXECUTE format(
        $query$
        SELECT DISTINCT ON (bar.open_time)
               bar.close_time, bar.high_price, bar.low_price, bar.close_price
        FROM market.klines bar
        WHERE bar.instrument_id = %1$L::bigint
          AND bar.price_type = 'TRADE'
          AND bar.interval_seconds = %2$L::integer
          AND bar.open_time >= %3$L::timestamptz
          AND bar.open_time < %4$L::timestamptz
          AND bar.close_time <= %4$L::timestamptz
          AND bar.effective_at <= %5$L::timestamptz
          AND bar.is_closed
          AND bar.quality_status = 'VALID'
        ORDER BY bar.open_time, bar.revision_no DESC,
                 bar.effective_at DESC, bar.collected_at DESC
        $query$,
        instrument_id_value,
        interval_seconds_value,
        entry_time_value,
        label_end_value,
        source_as_of_value
    );
END
$function$;

ALTER FUNCTION strategy_training.training_entry_outcome_bars(char(64))
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.training_random_candidate_outcome_bars(
    uuid, uuid, char(64), char(64)
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.training_entry_outcome_bars(char(64)),
    strategy_training.training_random_candidate_outcome_bars(
        uuid, uuid, char(64), char(64)
    )
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    strategy_training.training_entry_outcome_bars(char(64)),
    strategy_training.training_random_candidate_outcome_bars(
        uuid, uuid, char(64), char(64)
    )
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '065_training_outcome_bars_static_pruning',
    encode(digest(
        'auto_trade_v2_065_training_outcome_bars_static_pruning_v1',
        'sha256'
    ), 'hex'),
    'Use typed SQL literals for TimescaleDB chunk pruning in Model-A outcome reads'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
