\set ON_ERROR_STOP on
\pset pager off
\timing on

SELECT :'poc_tickers'::integer AS poc_tickers,
       :'poc_start'::timestamptz AS poc_start,
       :'poc_end'::timestamptz AS poc_end;

DROP SCHEMA IF EXISTS benchmark CASCADE;
CREATE SCHEMA benchmark;

CREATE TABLE benchmark.ticker_minutes_poc (
    instrument_id       integer NOT NULL,
    minute_time         timestamptz NOT NULL,
    last_price          numeric(38,18) NOT NULL,
    mark_price          numeric(38,18) NOT NULL,
    index_price         numeric(38,18) NOT NULL,
    price_change_24h    numeric(20,10),
    quote_volume_24h    numeric(38,18),
    funding_rate        numeric(20,12),
    open_interest_value numeric(38,18),
    quality_status      varchar(24) NOT NULL DEFAULT 'VALID',
    payload_hash        char(64) NOT NULL,
    PRIMARY KEY (instrument_id, minute_time)
);

SELECT create_hypertable(
    'benchmark.ticker_minutes_poc',
    by_range('minute_time', INTERVAL '7 days'),
    if_not_exists => TRUE
);

\echo 'P0_INSERT_BEGIN'
INSERT INTO benchmark.ticker_minutes_poc (
    instrument_id,
    minute_time,
    last_price,
    mark_price,
    index_price,
    price_change_24h,
    quote_volume_24h,
    funding_rate,
    open_interest_value,
    payload_hash
)
SELECT
    instrument_id,
    minute_time,
    100 + instrument_id + ((extract(epoch FROM minute_time)::bigint % 10000) / 10000.0),
    100 + instrument_id + ((extract(epoch FROM minute_time)::bigint % 10000) / 10000.0),
    100 + instrument_id,
    ((extract(minute FROM minute_time)::integer - 30) / 100.0),
    1000000 + instrument_id * 10000,
    0.0001,
    500000 + instrument_id * 1000,
    encode(digest(instrument_id::text || ':' || minute_time::text, 'sha256'), 'hex')
FROM generate_series(1, :'poc_tickers'::integer) AS instruments(instrument_id)
CROSS JOIN generate_series(
    :'poc_start'::timestamptz,
    :'poc_end'::timestamptz - INTERVAL '1 minute',
    INTERVAL '1 minute'
) AS minutes(minute_time);
\echo 'P0_INSERT_END'

ANALYZE benchmark.ticker_minutes_poc;

SELECT
    count(*) AS inserted_rows,
    count(DISTINCT instrument_id) AS ticker_count,
    min(minute_time) AS coverage_start,
    max(minute_time) AS coverage_end,
    hypertable_size('benchmark.ticker_minutes_poc') AS total_bytes,
    pg_size_pretty(hypertable_size('benchmark.ticker_minutes_poc')) AS total_size,
    round(hypertable_size('benchmark.ticker_minutes_poc')::numeric / count(*), 2) AS bytes_per_row,
    pg_size_pretty(
        (hypertable_size('benchmark.ticker_minutes_poc')::numeric
        / :'poc_tickers'::integer * 500)::bigint
    ) AS estimated_500_ticker_annual_size
FROM benchmark.ticker_minutes_poc;

\echo 'P0_12_MONTH_SINGLE_TICKER_QUERY'
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)
SELECT
    min(last_price),
    max(last_price),
    avg(last_price),
    sum(quote_volume_24h)
FROM benchmark.ticker_minutes_poc
WHERE instrument_id = 1
  AND minute_time >= :'poc_start'::timestamptz
  AND minute_time < :'poc_end'::timestamptz;

\echo 'P0_12_MONTH_15M_AGGREGATION_QUERY'
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)
SELECT
    time_bucket(INTERVAL '15 minutes', minute_time) AS bucket_time,
    first(last_price, minute_time) AS open_price,
    max(last_price) AS high_price,
    min(last_price) AS low_price,
    last(last_price, minute_time) AS close_price
FROM benchmark.ticker_minutes_poc
WHERE instrument_id = 1
  AND minute_time >= :'poc_start'::timestamptz
  AND minute_time < :'poc_end'::timestamptz
GROUP BY bucket_time
ORDER BY bucket_time;

SELECT
    hypertable_schema,
    hypertable_name,
    num_dimensions,
    num_chunks
FROM timescaledb_information.hypertables
WHERE hypertable_schema = 'benchmark';

