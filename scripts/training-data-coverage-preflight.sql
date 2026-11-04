\set ON_ERROR_STOP on
\pset pager off

-- Required psql variables: warmup_start, eligible_end, source_as_of, top_n.
-- Statements are generated with literal one-day bounds and per-instrument
-- LATERAL lookups so TimescaleDB prunes to one chunk instead of planning a
-- cross-month scan over the complete hypertable.
SET statement_timeout = '20s';
SET lock_timeout = '2s';
SET work_mem = '8MB';
SET max_parallel_workers_per_gather = 0;

CREATE TEMP TABLE training_coverage_preflight (
    coverage_date date NOT NULL,
    dependency_name text NOT NULL,
    expected_row_count bigint NOT NULL,
    observed_row_count bigint NOT NULL,
    missing_row_count bigint NOT NULL,
    missing_symbols jsonb NOT NULL,
    PRIMARY KEY (coverage_date, dependency_name)
);

-- Ranking and D-1 Ticker-pool presence.
SELECT format(
$statement$
INSERT INTO training_coverage_preflight
WITH selected_snapshot AS (
    SELECT snapshot.ranking_snapshot_id, snapshot.quality_status, snapshot.item_count
    FROM market.ranking_snapshots snapshot
    WHERE snapshot.ranking_type = 'UTC_DAILY_2355'
      AND snapshot.utc_trade_date = %1$L::date - 1
      AND snapshot.generated_at <= %2$L::timestamptz
      AND snapshot.created_at <= %2$L::timestamptz
    ORDER BY snapshot.generated_at DESC, snapshot.ranking_snapshot_id
    LIMIT 1
), state AS (
    SELECT count(*) FILTER (
        WHERE snapshot.quality_status = 'VALID'
          AND snapshot.item_count = %3$L::integer
          AND (SELECT count(*) FROM market.ranking_entries entry
               WHERE entry.ranking_snapshot_id = snapshot.ranking_snapshot_id
                 AND entry.rank_no <= %3$L::integer) = %3$L::integer
    )::bigint AS observed
    FROM selected_snapshot snapshot
)
SELECT %1$L::date, dependency_name, 1, state.observed, 1 - state.observed,
       CASE WHEN state.observed = 1 THEN '[]'::jsonb
            ELSE jsonb_build_array(jsonb_build_object('date', %1$L::date)) END
FROM state CROSS JOIN (VALUES
    ('UTC_DAILY_RANKING_D_MINUS_1'), ('TICKER_POOL_D_MINUS_1')
) dependency(dependency_name);
$statement$,
    coverage_day::date, :'source_as_of', :'top_n'
)
FROM generate_series(
    :'warmup_start'::date,
    (:'eligible_end'::timestamptz - interval '1 microsecond')::date,
    interval '1 day'
) coverage_day
\gexec

-- TRADE and MARK 5m coverage at the captured source_as_of snapshot.
SELECT format(
$statement$
INSERT INTO training_coverage_preflight
WITH candidates AS (
    SELECT entry.instrument_id, instrument.symbol
    FROM market.ranking_snapshots snapshot
    JOIN market.ranking_entries entry
      ON entry.ranking_snapshot_id = snapshot.ranking_snapshot_id
     AND entry.rank_no <= %5$L::integer
    JOIN core.instruments instrument USING (instrument_id)
    WHERE snapshot.ranking_snapshot_id = (
        SELECT candidate.ranking_snapshot_id
        FROM market.ranking_snapshots candidate
        WHERE candidate.ranking_type = 'UTC_DAILY_2355'
          AND candidate.utc_trade_date = %1$L::date - 1
          AND candidate.quality_status = 'VALID'
          AND candidate.generated_at <= %6$L::timestamptz
          AND candidate.created_at <= %6$L::timestamptz
        ORDER BY candidate.generated_at DESC, candidate.ranking_snapshot_id
        LIMIT 1
    )
), observed AS (
    SELECT kline.instrument_id, count(*)::bigint AS row_count
    FROM market.klines kline
    WHERE kline.price_type = %7$L AND kline.interval_seconds = 300
      AND kline.open_time >= %2$L::timestamptz
      AND kline.open_time < %3$L::timestamptz
      AND kline.is_current AND kline.is_closed AND kline.quality_status = 'VALID'
      AND kline.effective_at <= %6$L::timestamptz
      AND kline.instrument_id IN (SELECT instrument_id FROM candidates)
    GROUP BY kline.instrument_id
), per_instrument AS (
    SELECT candidates.symbol, coalesce(observed.row_count, 0)::bigint AS observed
    FROM candidates LEFT JOIN observed USING (instrument_id)
), aggregate AS (
    SELECT coalesce(sum(observed), 0)::bigint AS observed,
           coalesce(jsonb_agg(
               jsonb_build_object('symbol', symbol, 'missing_rows', %4$L::bigint - observed)
               ORDER BY symbol
           ) FILTER (WHERE observed < %4$L::bigint), '[]'::jsonb) AS missing_symbols
    FROM per_instrument
)
SELECT %1$L::date, %8$L,
       (%5$L::bigint * %4$L::bigint), aggregate.observed,
       (%5$L::bigint * %4$L::bigint) - aggregate.observed,
       aggregate.missing_symbols
FROM aggregate;
$statement$,
    coverage_day::date,
    greatest(coverage_day, :'warmup_start'::timestamptz),
    least(coverage_day + interval '1 day', :'eligible_end'::timestamptz),
    (extract(epoch FROM (
        least(coverage_day + interval '1 day', :'eligible_end'::timestamptz)
        - greatest(coverage_day, :'warmup_start'::timestamptz)
    )) / 300)::bigint,
    :'top_n', :'source_as_of', price_type, dependency_name
)
FROM generate_series(
    :'warmup_start'::date,
    (:'eligible_end'::timestamptz - interval '1 microsecond')::date,
    interval '1 day'
) coverage_day
CROSS JOIN (VALUES
    ('TRADE', 'TRADE_KLINE_5M'), ('MARK', 'MARK_KLINE_5M')
) dependency(price_type, dependency_name)
\gexec

-- EMA20 and EMA240 share the same non-null persisted indicator-row contract.
SELECT format(
$statement$
INSERT INTO training_coverage_preflight
WITH candidates AS (
    SELECT entry.instrument_id, instrument.symbol
    FROM market.ranking_snapshots snapshot
    JOIN market.ranking_entries entry
      ON entry.ranking_snapshot_id = snapshot.ranking_snapshot_id
     AND entry.rank_no <= %5$L::integer
    JOIN core.instruments instrument USING (instrument_id)
    WHERE snapshot.ranking_snapshot_id = (
        SELECT candidate.ranking_snapshot_id
        FROM market.ranking_snapshots candidate
        WHERE candidate.ranking_type = 'UTC_DAILY_2355'
          AND candidate.utc_trade_date = %1$L::date - 1
          AND candidate.quality_status = 'VALID'
          AND candidate.generated_at <= %6$L::timestamptz
          AND candidate.created_at <= %6$L::timestamptz
        ORDER BY candidate.generated_at DESC, candidate.ranking_snapshot_id
        LIMIT 1
    )
), observed AS (
    SELECT ema.instrument_id, count(*)::bigint AS row_count
    FROM market.kline_ema_indicators ema
    WHERE ema.price_type = 'TRADE' AND ema.interval_seconds = 300
      AND ema.open_time >= %2$L::timestamptz
      AND ema.open_time < %3$L::timestamptz
      AND ema.computed_at <= %6$L::timestamptz
      AND ema.instrument_id IN (SELECT instrument_id FROM candidates)
    GROUP BY ema.instrument_id
), per_instrument AS (
    SELECT candidates.symbol, coalesce(observed.row_count, 0)::bigint AS observed
    FROM candidates LEFT JOIN observed USING (instrument_id)
), aggregate AS (
    SELECT coalesce(sum(observed), 0)::bigint AS observed,
           coalesce(jsonb_agg(
               jsonb_build_object('symbol', symbol, 'missing_rows', %4$L::bigint - observed)
               ORDER BY symbol
           ) FILTER (WHERE observed < %4$L::bigint), '[]'::jsonb) AS missing_symbols
    FROM per_instrument
)
SELECT %1$L::date, dependency_name,
       (%5$L::bigint * %4$L::bigint), aggregate.observed,
       (%5$L::bigint * %4$L::bigint) - aggregate.observed,
       aggregate.missing_symbols
FROM aggregate
CROSS JOIN (VALUES ('EMA20_5M'), ('EMA240_5M')) dependency(dependency_name);
$statement$,
    coverage_day::date,
    greatest(coverage_day, :'warmup_start'::timestamptz),
    least(coverage_day + interval '1 day', :'eligible_end'::timestamptz),
    (extract(epoch FROM (
        least(coverage_day + interval '1 day', :'eligible_end'::timestamptz)
        - greatest(coverage_day, :'warmup_start'::timestamptz)
    )) / 300)::bigint,
    :'top_n', :'source_as_of'
)
FROM generate_series(
    :'warmup_start'::date,
    (:'eligible_end'::timestamptz - interval '1 microsecond')::date,
    interval '1 day'
) coverage_day
\gexec

SELECT dependency_name,
       sum(expected_row_count) AS expected_row_count,
       sum(observed_row_count) AS observed_row_count,
       sum(missing_row_count) AS missing_row_count,
       round(sum(observed_row_count)::numeric / sum(expected_row_count), 8) AS coverage_ratio,
       count(*) FILTER (WHERE missing_row_count > 0) AS affected_days
FROM training_coverage_preflight
GROUP BY dependency_name
ORDER BY dependency_name;

SELECT coverage_date, dependency_name, expected_row_count, observed_row_count,
       missing_row_count, missing_symbols
FROM training_coverage_preflight
WHERE missing_row_count > 0
ORDER BY coverage_date, dependency_name;
