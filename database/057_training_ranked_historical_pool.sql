\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- The SECURITY DEFINER function is owned by this non-login role.  Grant only
-- the ranking inputs it needs; callers still receive no direct table access.
GRANT SELECT ON market.ranking_snapshots, market.ranking_entries
TO tb2_training_owner;

-- Apply the governed D-1 ranking before any per-instrument Kline aggregation.
-- Besides enforcing the configured Ticker pool, this bounds each evaluation to
-- at most top_n instruments instead of scanning the entire futures catalogue.
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
AS $$
    WITH dataset AS (
        SELECT version.dataset_version_id, version.eligible_start_at, version.eligible_end_at,
               version.source_as_of_at, eligibility.config_json AS eligible_rules,
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
               instrument.quote_asset || '_' || instrument.contract_type AS contract_identity,
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
        LEFT JOIN LATERAL (
            SELECT sum(revision.quote_volume) AS quote_notional,
                   max(revision.close_time) AS observed_at,
                   encode(
                       public.digest(
                           string_agg(
                               revision.open_time::text || ':' || revision.revision_no::text
                               || ':' || revision.payload_hash,
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
                WHERE bar.instrument_id = candidate.instrument_id
                  AND bar.price_type = 'TRADE'
                  AND bar.interval_seconds = 300
                  AND bar.is_closed
                  AND bar.quality_status = 'VALID'
                  AND bar.close_time <= p_evaluation_at
                  AND bar.open_time >= p_evaluation_at - make_interval(
                      secs => (candidate.eligible_rules
                               ->> 'liquidity_lookback_seconds')::double precision
                  )
                  AND bar.effective_at <= candidate.source_as_of_at
                ORDER BY bar.open_time, bar.revision_no DESC
            ) revision
        ) liquidity ON true
    ), resolved AS (
        SELECT observation.*,
               observation.recorded_status_effective_at IS NULL
               AND jsonb_typeof(
                   observation.eligible_rules -> 'inferred_trading_minimum_notional_volume'
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
                   WHEN resolved.status_inferred_from_klines THEN resolved.liquidity_observed_at
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
                               'observed_quote_volume', resolved.observed_quote_notional,
                               'liquidity_revision_hash', resolved.liquidity_revision_hash
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
                   CASE WHEN classified.resolved_exchange_status IS DISTINCT FROM 'TRADING'
                       OR classified.resolved_system_status IS DISTINCT FROM 'ACTIVE'
                       THEN 'NOT_TRADING_AT_EVALUATION' END,
                   CASE WHEN classified.observed_quote_notional IS NULL
                       THEN 'MISSING_LIQUIDITY' END,
                   CASE WHEN classified.observed_quote_notional IS NOT NULL AND
                       classified.observed_quote_notional <
                           (classified.eligible_rules ->> 'minimum_notional_volume')::numeric
                       THEN 'INSUFFICIENT_LIQUIDITY' END
               ]::text[], NULL) AS reasons
        FROM classified
    )
    SELECT eligible.instrument_id, eligible.symbol, p_evaluation_at,
           eligible.onboard_at, eligible.contract_identity,
           eligible.resolved_exchange_status, eligible.resolved_system_status,
           eligible.resolved_status_effective_at, eligible.resolved_status_payload_hash,
           eligible.observed_quote_notional, eligible.liquidity_observed_at,
           eligible.liquidity_revision_hash,
           cardinality(eligible.reasons) = 0,
           to_jsonb(eligible.reasons)
    FROM eligible
    ORDER BY eligible.symbol
$$;

COMMENT ON FUNCTION strategy_training.historical_instrument_universe(uuid, timestamptz)
IS 'D-1 ranked point-in-time pool; exchange status history wins, otherwise governed 24h TRADE Kline quote volume may infer TRADING.';

ALTER FUNCTION strategy_training.historical_instrument_universe(uuid, timestamptz)
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.historical_instrument_universe(uuid, timestamptz)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION strategy_training.historical_instrument_universe(uuid, timestamptz)
TO tb2_training_rw;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '057_training_ranked_historical_pool',
    encode(digest('auto_trade_v2_057_training_ranked_historical_pool_v2', 'sha256'), 'hex'),
    'Apply governed D-1 Top-N ranking before historical pool Kline aggregation'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
