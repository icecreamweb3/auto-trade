\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- SQL-language runtime parameters prevent TimescaleDB from pruning unrelated
-- chunks while planning these large-history reads. Resolve the governed
-- context first, then render typed literals into the market-data query.
CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_benchmark_bars(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (open_time timestamptz, close_price numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $function$
DECLARE
    benchmark_instrument_id bigint;
    benchmark_symbol_value text;
    warmup_start_value timestamptz;
    eligible_end_value timestamptz;
    source_as_of_value timestamptz;
BEGIN
    SELECT config.config_json -> 'stratification' ->> 'benchmark_symbol',
           dataset.warmup_start_at, scan.eligible_end_at, dataset.source_as_of_at
    INTO STRICT benchmark_symbol_value, warmup_start_value,
                eligible_end_value, source_as_of_value
    FROM strategy_training.training_model_a_candidate_scan_context(
        p_task_id, p_lease_token
    ) scan
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = scan.dataset_version_id
    JOIN strategy_training.training_model_a_candidate_scan_random_config(
        p_task_id, p_lease_token
    ) config ON true;

    SELECT instrument.instrument_id
    INTO STRICT benchmark_instrument_id
    FROM core.instruments instrument
    WHERE instrument.exchange = 'BINANCE'
      AND instrument.market = 'USD_M_FUTURES'
      AND instrument.symbol = benchmark_symbol_value;

    RETURN QUERY EXECUTE format(
        $query$
        SELECT DISTINCT ON (bar.open_time) bar.open_time, bar.close_price
        FROM market.klines bar
        WHERE bar.instrument_id = %1$L::bigint
          AND bar.price_type = 'TRADE'
          AND bar.interval_seconds = 300
          AND bar.is_closed
          AND bar.quality_status = 'VALID'
          AND bar.open_time >= %2$L::timestamptz
          AND bar.open_time < %3$L::timestamptz
          AND bar.effective_at <= %4$L::timestamptz
        ORDER BY bar.open_time, bar.revision_no DESC
        $query$,
        benchmark_instrument_id,
        warmup_start_value,
        eligible_end_value,
        source_as_of_value
    );
END
$function$;

CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_bars(
    p_task_id uuid, p_lease_token uuid, p_instrument_id bigint
)
RETURNS TABLE (
    open_time timestamptz, open_price numeric, high_price numeric,
    low_price numeric, close_price numeric, price_precision integer,
    ema20 numeric, ema240 numeric, base_volume numeric, quote_volume numeric,
    amplitude_percent numeric, open_interest_value numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, market
AS $function$
DECLARE
    warmup_start_value timestamptz;
    scan_end_value timestamptz;
    source_as_of_value timestamptz;
BEGIN
    SELECT dataset.warmup_start_at,
           scan.eligible_end_at + interval '5 minutes',
           dataset.source_as_of_at
    INTO STRICT warmup_start_value, scan_end_value, source_as_of_value
    FROM strategy_training.training_model_a_candidate_scan_context(
        p_task_id, p_lease_token
    ) scan
    JOIN strategy_training.training_dataset_versions dataset
      ON dataset.dataset_version_id = scan.dataset_version_id
    WHERE EXISTS (
        SELECT 1
        FROM strategy_training.training_historical_pool_evaluations pool
        WHERE pool.dataset_version_id = scan.dataset_version_id
          AND pool.instrument_id = p_instrument_id
          AND pool.is_eligible
    );

    RETURN QUERY EXECUTE format(
        $query$
        WITH revisions AS (
            SELECT DISTINCT ON (bar.open_time)
                   bar.open_time, bar.open_price, bar.high_price, bar.low_price,
                   bar.close_price, bar.base_volume, bar.quote_volume
            FROM market.klines bar
            WHERE bar.instrument_id = %1$L::bigint
              AND bar.price_type = 'TRADE'
              AND bar.interval_seconds = 300
              AND bar.is_closed
              AND bar.quality_status = 'VALID'
              AND bar.open_time >= %2$L::timestamptz
              AND bar.open_time < %3$L::timestamptz
              AND bar.effective_at <= %4$L::timestamptz
            ORDER BY bar.open_time, bar.revision_no DESC
        )
        SELECT revision.open_time, revision.open_price, revision.high_price,
               revision.low_price, revision.close_price,
               rules.price_precision::integer,
               ema.ema20, ema.ema240, revision.base_volume,
               revision.quote_volume,
               ((revision.high_price - revision.low_price)
                    / revision.open_price * 100),
               oi.open_interest_value
        FROM revisions revision
        JOIN market.kline_ema_indicators ema
          ON ema.instrument_id = %1$L::bigint
         AND ema.price_type = 'TRADE'
         AND ema.interval_seconds = 300
         AND ema.open_time >= %2$L::timestamptz
         AND ema.open_time < %3$L::timestamptz
         AND ema.open_time = revision.open_time
         AND ema.close_price = revision.close_price
         AND ema.computed_at <= %4$L::timestamptz
        LEFT JOIN LATERAL (
            SELECT rule.price_precision
            FROM core.instrument_rule_versions rule
            WHERE rule.instrument_id = %1$L::bigint
              AND rule.effective_from <= revision.open_time
            ORDER BY rule.effective_from DESC
            LIMIT 1
        ) rules ON true
        LEFT JOIN LATERAL (
            SELECT observation.open_interest_value
            FROM market.open_interest_observations observation
            WHERE observation.instrument_id = %1$L::bigint
              AND observation.observed_at >= revision.open_time
              AND observation.observed_at
                    < revision.open_time + interval '5 minutes'
              AND observation.quality_status IN ('VALID', 'PARTIAL')
              AND observation.collected_at <= %4$L::timestamptz
            ORDER BY observation.observed_at DESC
            LIMIT 1
        ) oi ON true
        ORDER BY revision.open_time
        $query$,
        p_instrument_id,
        warmup_start_value,
        scan_end_value,
        source_as_of_value
    );
END
$function$;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '061_training_candidate_scan_static_pruning',
    encode(digest(
        'auto_trade_v2_061_training_candidate_scan_static_pruning_v1',
        'sha256'
    ), 'hex'),
    'Use typed SQL literals for TimescaleDB chunk pruning in Model-A candidate scans'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
