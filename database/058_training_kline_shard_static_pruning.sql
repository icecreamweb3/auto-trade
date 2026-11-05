\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- SQL-language function arguments become runtime Params.  On a large
-- Timescale hypertable that forces planning across every chunk before startup
-- exclusion can apply, which can exhaust the database host while building a
-- tiny governed shard.  Render the already typed arguments as SQL literals so
-- static chunk pruning happens during planning.
CREATE OR REPLACE FUNCTION strategy_training.training_kline_source_shard(
    p_dataset_version_id uuid,
    p_instrument_id bigint,
    p_member_start_at timestamptz,
    p_member_end_at timestamptz
)
RETURNS TABLE (
    source_schema text,
    source_table text,
    source_shard_identity text,
    member_start_at timestamptz,
    member_end_at timestamptz,
    source_revision_watermark jsonb,
    member_hash char(64),
    shard_fingerprint char(64),
    normalized_query_hash char(64),
    row_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, core, public
AS $function$
BEGIN
    RETURN QUERY EXECUTE format(
        $query$
        WITH dataset AS (
            SELECT interval_seconds, source_as_of_at,
                   warmup_start_at, label_window_end_at
            FROM strategy_training.training_dataset_versions
            WHERE dataset_version_id = %1$L::uuid
              AND status = 'BUILDING'
              AND %3$L::timestamptz >= warmup_start_at
              AND %4$L::timestamptz <= label_window_end_at
              AND %3$L::timestamptz < %4$L::timestamptz
        ), ranked AS (
            SELECT kline.open_time, kline.close_time, kline.revision_no,
                   kline.effective_at, kline.collected_at, kline.payload_hash,
                   row_number() OVER (
                       PARTITION BY kline.open_time
                       ORDER BY kline.revision_no DESC, kline.effective_at DESC,
                                kline.collected_at DESC
                   ) AS revision_rank
            FROM dataset
            JOIN market.klines kline
              ON kline.instrument_id = %2$L::bigint
             AND kline.price_type = 'TRADE'
             AND kline.interval_seconds = dataset.interval_seconds
             AND kline.open_time >= %3$L::timestamptz
             AND kline.open_time < %4$L::timestamptz
             AND kline.effective_at <= dataset.source_as_of_at
            WHERE kline.is_closed AND kline.quality_status = 'VALID'
        ), selected AS (
            SELECT * FROM ranked WHERE revision_rank = 1
        ), aggregate_values AS (
            SELECT dataset.interval_seconds, dataset.source_as_of_at,
                   count(selected.open_time)::bigint AS selected_count,
                   max(selected.revision_no) AS maximum_revision_no,
                   max(selected.effective_at) AS maximum_effective_at,
                   max(selected.collected_at) AS maximum_collected_at,
                   encode(public.digest(string_agg(
                       concat_ws(':',
                           to_char(selected.open_time AT TIME ZONE 'UTC',
                                   'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                           selected.revision_no::text, selected.payload_hash
                       ), '|' ORDER BY selected.open_time
                   ), 'sha256'), 'hex')::char(64) AS computed_member_hash
            FROM dataset
            LEFT JOIN selected ON true
            GROUP BY dataset.interval_seconds, dataset.source_as_of_at
            HAVING count(selected.open_time) > 0
        ), canonical AS (
            SELECT 'market'::text AS computed_source_schema,
                   'klines'::text AS computed_source_table,
                   concat_ws(':', 'instrument', %2$L::bigint::text, 'TRADE',
                       aggregate_values.interval_seconds::text,
                       to_char(%3$L::timestamptz AT TIME ZONE 'UTC',
                               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                       to_char(%4$L::timestamptz AT TIME ZONE 'UTC',
                               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                   ) AS computed_identity,
                   jsonb_build_object(
                       'maximum_revision_no', aggregate_values.maximum_revision_no,
                       'maximum_effective_at', aggregate_values.maximum_effective_at,
                       'maximum_collected_at', aggregate_values.maximum_collected_at,
                       'source_as_of_at', aggregate_values.source_as_of_at
                   ) AS computed_watermark,
                   aggregate_values.computed_member_hash,
                   encode(public.digest(
                       'training_kline_source_shard:v1:highest_revision_effective_lte_source_as_of:left_closed_right_open',
                       'sha256'
                   ), 'hex')::char(64) AS computed_query_hash,
                   aggregate_values.selected_count
            FROM aggregate_values
        )
        SELECT canonical.computed_source_schema,
               canonical.computed_source_table,
               canonical.computed_identity,
               %3$L::timestamptz,
               %4$L::timestamptz,
               canonical.computed_watermark,
               canonical.computed_member_hash,
               encode(public.digest(concat_ws('|',
                   canonical.computed_source_schema,
                   canonical.computed_source_table,
                   canonical.computed_identity,
                   to_char(%3$L::timestamptz AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                   to_char(%4$L::timestamptz AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                   canonical.selected_count::text,
                   canonical.computed_member_hash,
                   canonical.computed_query_hash,
                   canonical.computed_watermark::text
               ), 'sha256'), 'hex')::char(64),
               canonical.computed_query_hash,
               canonical.selected_count
        FROM canonical
        $query$,
        p_dataset_version_id,
        p_instrument_id,
        p_member_start_at,
        p_member_end_at
    );
END
$function$;

ALTER FUNCTION strategy_training.training_kline_source_shard(
    uuid, bigint, timestamptz, timestamptz
) OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.training_kline_source_shard(
    uuid, bigint, timestamptz, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.training_kline_source_shard(
    uuid, bigint, timestamptz, timestamptz
) TO tb2_training_rw;

-- Isolate the historical 24-hour Kline aggregation behind the same literal
-- planning boundary.  The caller remains responsible for applying the frozen
-- eligibility policy; this helper only returns point-in-time source evidence.
CREATE OR REPLACE FUNCTION strategy_training.historical_kline_liquidity(
    p_instrument_id bigint,
    p_evaluation_at timestamptz,
    p_source_as_of_at timestamptz,
    p_lookback_seconds double precision
)
RETURNS TABLE (
    quote_notional numeric,
    observed_at timestamptz,
    revision_hash char(64)
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, market, public
AS $function$
DECLARE
    lookback_start_at timestamptz;
BEGIN
    IF p_lookback_seconds <= 0 THEN
        RAISE EXCEPTION 'historical Kline lookback must be positive'
            USING ERRCODE = '22023';
    END IF;
    lookback_start_at := p_evaluation_at
        - make_interval(secs => p_lookback_seconds);

    RETURN QUERY EXECUTE format(
        $query$
        SELECT sum(revision.quote_volume) AS quote_notional,
               max(revision.close_time) AS observed_at,
               encode(
                   public.digest(
                       string_agg(
                           revision.open_time::text || ':'
                           || revision.revision_no::text || ':'
                           || revision.payload_hash,
                           '|' ORDER BY revision.open_time
                       ),
                       'sha256'
                   ),
                   'hex'
               )::char(64) AS revision_hash
        FROM (
            SELECT DISTINCT ON (bar.open_time)
                   bar.open_time, bar.close_time, bar.revision_no,
                   bar.quote_volume, bar.payload_hash
            FROM market.klines bar
            WHERE bar.instrument_id = %1$L::bigint
              AND bar.price_type = 'TRADE'
              AND bar.interval_seconds = 300
              AND bar.is_closed
              AND bar.quality_status = 'VALID'
              AND bar.close_time <= %2$L::timestamptz
              AND bar.open_time >= %3$L::timestamptz
              AND bar.effective_at <= %4$L::timestamptz
            ORDER BY bar.open_time, bar.revision_no DESC
        ) revision
        $query$,
        p_instrument_id,
        p_evaluation_at,
        lookback_start_at,
        p_source_as_of_at
    );
END
$function$;

ALTER FUNCTION strategy_training.historical_kline_liquidity(
    bigint, timestamptz, timestamptz, double precision
) OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.historical_kline_liquidity(
    bigint, timestamptz, timestamptz, double precision
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION strategy_training.historical_instrument_universe(
    p_dataset_version_id uuid,
    p_evaluation_at timestamptz
)
RETURNS TABLE (
    instrument_id bigint,
    symbol varchar(32),
    evaluation_at timestamptz,
    onboard_at timestamptz,
    contract_identity text,
    exchange_status varchar(32),
    system_status varchar(32),
    status_effective_at timestamptz,
    status_payload_hash char(64),
    observed_quote_notional numeric,
    liquidity_observed_at timestamptz,
    liquidity_revision_hash char(64),
    is_eligible boolean,
    rejection_codes jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $function$
    WITH dataset AS (
        SELECT version.dataset_version_id, version.eligible_start_at,
               version.eligible_end_at, version.source_as_of_at,
               eligibility.config_json AS eligible_rules,
               ticker.config_json AS ticker_rules
        FROM strategy_training.training_dataset_versions version
        JOIN strategy_training.training_dataset_config_bindings eligibility_binding
          ON eligibility_binding.dataset_version_id = version.dataset_version_id
         AND eligibility_binding.config_type = 'ELIGIBLE_POOL_RULES'
        JOIN strategy_training.training_config_versions eligibility
          ON eligibility.config_version_id = eligibility_binding.config_version_id
         AND eligibility.config_type = 'ELIGIBLE_POOL_RULES'
         AND eligibility.status = 'READY'
        JOIN strategy_training.training_config_versions ticker
          ON ticker.config_version_id = version.ticker_pool_rule_version_id
         AND ticker.config_type = 'TICKER_POOL_RULES'
         AND ticker.status = 'READY'
        WHERE version.dataset_version_id = p_dataset_version_id
          AND version.status = 'BUILDING'
          AND p_evaluation_at >= version.eligible_start_at
          AND p_evaluation_at < version.eligible_end_at
    ), candidates AS (
        SELECT instrument.instrument_id, instrument.symbol, instrument.onboard_at,
               instrument.quote_asset || '_' || instrument.contract_type
                   AS contract_identity,
               dataset.source_as_of_at, dataset.eligible_rules
        FROM dataset
        CROSS JOIN LATERAL (
            SELECT snapshot.ranking_snapshot_id
            FROM market.ranking_snapshots snapshot
            WHERE snapshot.ranking_type = dataset.ticker_rules ->> 'ranking_type'
              AND snapshot.utc_trade_date =
                  (p_evaluation_at AT TIME ZONE 'UTC')::date
                  - (dataset.ticker_rules ->> 'as_of_lag_days')::integer
              AND snapshot.quality_status = 'VALID'
              AND snapshot.generated_at <= dataset.source_as_of_at
              AND snapshot.created_at <= dataset.source_as_of_at
            ORDER BY snapshot.generated_at DESC, snapshot.ranking_snapshot_id
            LIMIT 1
        ) snapshot
        JOIN market.ranking_entries ranking
          ON ranking.ranking_snapshot_id = snapshot.ranking_snapshot_id
         AND ranking.rank_no <= (dataset.ticker_rules ->> 'top_n')::integer
        JOIN core.instruments instrument
          ON instrument.instrument_id = ranking.instrument_id
        WHERE instrument.exchange = 'BINANCE'
          AND instrument.market = 'USD_M_FUTURES'
          AND instrument.first_seen_at <= dataset.source_as_of_at
          AND NOT (
              coalesce(dataset.ticker_rules -> 'excluded_symbols', '[]'::jsonb)
              ? instrument.symbol
          )
    ), observations AS (
        SELECT candidate.*,
               status.exchange_status AS recorded_exchange_status,
               status.system_status AS recorded_system_status,
               status.effective_at AS recorded_status_effective_at,
               status.payload_hash AS recorded_status_payload_hash,
               liquidity.quote_notional AS observed_quote_notional,
               liquidity.observed_at AS liquidity_observed_at,
               liquidity.revision_hash AS liquidity_revision_hash
        FROM candidates candidate
        LEFT JOIN LATERAL (
            SELECT history.exchange_status, history.system_status,
                   history.effective_at, history.payload_hash
            FROM core.instrument_status_history history
            WHERE history.instrument_id = candidate.instrument_id
              AND history.effective_at <= p_evaluation_at
              AND history.created_at <= candidate.source_as_of_at
            ORDER BY history.effective_at DESC, history.created_at DESC
            LIMIT 1
        ) status ON true
        LEFT JOIN LATERAL strategy_training.historical_kline_liquidity(
            candidate.instrument_id,
            p_evaluation_at,
            candidate.source_as_of_at,
            (candidate.eligible_rules
             ->> 'liquidity_lookback_seconds')::double precision
        ) liquidity ON true
    ), resolved AS (
        SELECT observation.*,
               observation.recorded_status_effective_at IS NULL
               AND jsonb_typeof(
                   observation.eligible_rules
                   -> 'inferred_trading_minimum_notional_volume'
               ) = 'number'
               AND observation.observed_quote_notional >
                   (observation.eligible_rules
                    ->> 'inferred_trading_minimum_notional_volume')::numeric
                   AS status_inferred_from_klines
        FROM observations observation
    ), classified AS (
        SELECT resolved.*,
               CASE
                   WHEN resolved.recorded_status_effective_at IS NOT NULL
                       THEN resolved.recorded_exchange_status
                   WHEN resolved.status_inferred_from_klines THEN 'TRADING'
               END::varchar(32) AS resolved_exchange_status,
               CASE
                   WHEN resolved.recorded_status_effective_at IS NOT NULL
                       THEN resolved.recorded_system_status
                   WHEN resolved.status_inferred_from_klines THEN 'ACTIVE'
               END::varchar(32) AS resolved_system_status,
               CASE
                   WHEN resolved.recorded_status_effective_at IS NOT NULL
                       THEN resolved.recorded_status_effective_at
                   WHEN resolved.status_inferred_from_klines
                       THEN resolved.liquidity_observed_at
               END AS resolved_status_effective_at,
               CASE
                   WHEN resolved.recorded_status_effective_at IS NOT NULL
                       THEN resolved.recorded_status_payload_hash
                   WHEN resolved.status_inferred_from_klines THEN encode(
                       public.digest(
                           jsonb_build_object(
                               'policy', 'KLINE_24H_QUOTE_VOLUME_STATUS_INFERENCE_V1',
                               'instrument_id', resolved.instrument_id,
                               'evaluation_at', p_evaluation_at,
                               'minimum_quote_volume', resolved.eligible_rules
                                   -> 'inferred_trading_minimum_notional_volume',
                               'observed_quote_volume',
                                   resolved.observed_quote_notional,
                               'liquidity_revision_hash',
                                   resolved.liquidity_revision_hash
                           )::text,
                           'sha256'
                       ),
                       'hex'
                   )::char(64)
               END AS resolved_status_payload_hash
        FROM resolved
    ), eligible AS (
        SELECT classified.*,
               array_remove(ARRAY[
                   CASE WHEN classified.contract_identity <>
                       classified.eligible_rules ->> 'required_contract_type'
                       THEN 'CONTRACT_TYPE_NOT_ALLOWED' END,
                   CASE WHEN classified.onboard_at IS NULL
                       THEN 'MISSING_ONBOARD_TIME' END,
                   CASE WHEN classified.onboard_at IS NOT NULL AND
                       classified.onboard_at + make_interval(
                           secs => (classified.eligible_rules
                                    ->> 'minimum_listing_age_seconds')::double precision
                       ) > p_evaluation_at THEN 'LISTING_AGE_TOO_SHORT' END,
                   CASE WHEN classified.recorded_status_effective_at IS NULL
                          AND NOT classified.status_inferred_from_klines
                       THEN 'MISSING_STATUS_HISTORY_AND_KLINE_VOLUME_FALLBACK' END,
                   CASE WHEN classified.resolved_exchange_status
                                  IS DISTINCT FROM 'TRADING'
                          OR classified.resolved_system_status
                                  IS DISTINCT FROM 'ACTIVE'
                       THEN 'NOT_TRADING_AT_EVALUATION' END,
                   CASE WHEN classified.observed_quote_notional IS NULL
                       THEN 'MISSING_LIQUIDITY' END,
                   CASE WHEN classified.observed_quote_notional IS NOT NULL AND
                       classified.observed_quote_notional <
                           (classified.eligible_rules
                            ->> 'minimum_notional_volume')::numeric
                       THEN 'INSUFFICIENT_LIQUIDITY' END
               ]::text[], NULL) AS reasons
        FROM classified
    )
    SELECT eligible.instrument_id, eligible.symbol, p_evaluation_at,
           eligible.onboard_at, eligible.contract_identity,
           eligible.resolved_exchange_status, eligible.resolved_system_status,
           eligible.resolved_status_effective_at,
           eligible.resolved_status_payload_hash,
           eligible.observed_quote_notional, eligible.liquidity_observed_at,
           eligible.liquidity_revision_hash,
           cardinality(eligible.reasons) = 0,
           to_jsonb(eligible.reasons)
    FROM eligible
    ORDER BY eligible.symbol
$function$;

COMMENT ON FUNCTION strategy_training.historical_instrument_universe(
    uuid, timestamptz
) IS 'D-1 ranked point-in-time pool; exchange status history wins, otherwise governed 24h TRADE Kline quote volume may infer TRADING.';

ALTER FUNCTION strategy_training.historical_instrument_universe(
    uuid, timestamptz
) OWNER TO tb2_training_owner;
REVOKE ALL ON FUNCTION strategy_training.historical_instrument_universe(
    uuid, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.historical_instrument_universe(
    uuid, timestamptz
) TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '058_training_kline_shard_static_pruning',
    encode(digest(
        'auto_trade_v2_058_training_kline_shard_static_pruning_v2',
        'sha256'
    ), 'hex'),
    'Use literal bounds so Timescale prunes governed Kline chunks during planning'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
