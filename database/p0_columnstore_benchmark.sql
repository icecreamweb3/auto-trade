\set ON_ERROR_STOP on
\pset pager off
\timing on

ALTER TABLE benchmark.ticker_minutes_poc SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'instrument_id',
    timescaledb.orderby = 'minute_time DESC'
);

SELECT format('%I.%I', chunk_schema, chunk_name) AS target_chunk
FROM timescaledb_information.chunks
WHERE hypertable_schema = 'benchmark'
  AND hypertable_name = 'ticker_minutes_poc'
  AND NOT is_compressed
ORDER BY range_start
LIMIT 1
\gset

\echo 'Converting benchmark chunk ' :target_chunk
CALL convert_to_columnstore(:'target_chunk');

SELECT
    total_chunks,
    number_compressed_chunks AS columnstore_chunks,
    pg_size_pretty(before_compression_total_bytes) AS before_columnstore,
    pg_size_pretty(after_compression_total_bytes) AS after_columnstore,
    round(
        100.0 * (
            before_compression_total_bytes - after_compression_total_bytes
        ) / nullif(before_compression_total_bytes, 0),
        2
    ) AS saved_percent
FROM hypertable_columnstore_stats('benchmark.ticker_minutes_poc');

SELECT
    count(*) AS rows,
    min(minute_time) AS earliest,
    max(minute_time) AS latest,
    min(last_price) AS minimum_price,
    max(last_price) AS maximum_price
FROM benchmark.ticker_minutes_poc
WHERE instrument_id = 1;
