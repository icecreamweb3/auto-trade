\set ON_ERROR_STOP on
\pset pager off

SELECT
    h.hypertable_schema,
    h.hypertable_name,
    d.time_interval AS chunk_interval,
    h.num_chunks,
    h.compression_enabled AS columnstore_enabled,
    settings.segmentby,
    settings.orderby
FROM timescaledb_information.hypertables h
JOIN timescaledb_information.dimensions d
  ON d.hypertable_schema = h.hypertable_schema
 AND d.hypertable_name = h.hypertable_name
 AND d.dimension_number = 1
LEFT JOIN timescaledb_information.hypertable_columnstore_settings settings
  ON settings.hypertable = format(
      '%I.%I', h.hypertable_schema, h.hypertable_name
  )::regclass
WHERE h.hypertable_schema = 'market'
  AND h.hypertable_name IN (
      'raw_events',
      'klines',
      'ticker_minutes',
      'funding_observations',
      'open_interest_observations'
  )
ORDER BY h.hypertable_name;

SELECT
    job_id,
    hypertable_schema,
    hypertable_name,
    scheduled,
    config ->> 'compress_after' AS columnstore_after,
    schedule_interval,
    next_start
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_compression'
  AND hypertable_schema = 'market'
ORDER BY hypertable_name;

SELECT
    h.hypertable_schema,
    h.hypertable_name,
    coalesce(stats.number_compressed_chunks, 0) AS columnstore_chunks,
    pg_size_pretty(
        coalesce(stats.before_compression_total_bytes, 0)
    ) AS before_columnstore,
    pg_size_pretty(
        coalesce(stats.after_compression_total_bytes, 0)
    ) AS after_columnstore,
    CASE
        WHEN coalesce(stats.before_compression_total_bytes, 0) = 0 THEN NULL
        ELSE round(
            100.0 * (
                stats.before_compression_total_bytes
                - stats.after_compression_total_bytes
            ) / stats.before_compression_total_bytes,
            2
        )
    END AS saved_percent
FROM timescaledb_information.hypertables h
LEFT JOIN LATERAL hypertable_columnstore_stats(
    format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass
) stats ON true
WHERE h.hypertable_schema = 'market'
  AND h.hypertable_name IN (
      'raw_events',
      'klines',
      'ticker_minutes',
      'funding_observations',
      'open_interest_observations'
  )
ORDER BY h.hypertable_name;
