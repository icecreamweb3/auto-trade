\set ON_ERROR_STOP on
\pset pager off

-- Required psql variables:
--   code_commit, image_digest, dependency_lock_hash, coverage_query_hash,
--   python_version, system_version.
-- Optional variables below retain the original August build as their defaults.
-- A wrapper may override them to create a governed replacement without copying
-- this implementation and letting the two build paths drift.
\if :{?warmup_start}
\else
\set warmup_start '2026-07-24 22:20:00+00'
\endif
\if :{?eligible_start}
\else
\set eligible_start '2026-08-01 00:00:00+00'
\endif
\if :{?dataset_eligible_end}
\else
\set dataset_eligible_end '2026-08-31 00:00:00+00'
\endif
\if :{?label_window_end}
\else
\set label_window_end '2026-09-01 00:00:00+00'
\endif
-- The included coverage audit uses eligible_end as its audit upper bound and
-- therefore deliberately includes the complete 24-hour label window.
\if :{?eligible_end}
\else
\set eligible_end '2026-09-01 00:00:00+00'
\endif
\if :{?partition_start}
\else
\set partition_start '2026-08-01 00:00:00+00'
\endif
\if :{?partition_end}
\else
\set partition_end '2026-09-01 00:00:00+00'
\endif
\if :{?source_as_of}
\else
\set source_as_of '2026-11-04 13:11:00+00'
\endif
\if :{?visibility_cutoff}
\else
\set visibility_cutoff '2026-07-31 00:00:00+00'
\endif
\if :{?top_n}
\else
\set top_n 50
\endif
\if :{?actor_user_id}
\else
\set actor_user_id 'b123d0af-5004-4e69-a327-24532a1ae57c'
\endif
\if :{?supersedes_dataset_id}
\else
\set supersedes_dataset_id ''
\endif
\if :{?dataset_builder}
\else
\set dataset_builder 'AUGUST_TRAIN_A0_V1'
\endif
\if :{?resource_assessment}
\else
\set resource_assessment 'AUGUST_TRAIN_A0_DAILY_BOUNDED_V1'
\endif
\if :{?estimated_member_rows}
\else
\set estimated_member_rows 548200
\endif
\if :{?bounded_query_days}
\else
\set bounded_query_days 39
\endif
\if :{?transition_reason}
\else
\set transition_reason 'A0 August TRAIN coverage, historical pool, resources, and manifest passed'
\endif
\if :{?run_command}
\else
\set run_command 'psql -f scripts/build-august-train-dataset.sql'
\endif

SELECT EXISTS (
    SELECT 1
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND partition = 'TRAIN'
      AND partition_start_at = :'partition_start'::timestamptz
      AND partition_end_at = :'partition_end'::timestamptz
      AND status = 'READY'
) AS ready_dataset_exists
\gset

\if :ready_dataset_exists
\echo 'requested TRAIN dataset range is already READY'
\quit 3
\endif

SELECT (
    SELECT dataset_version_id
    FROM strategy_training.training_dataset_versions
    WHERE dataset_type = 'MODEL_A_FEATURES'
      AND partition = 'TRAIN'
      AND partition_start_at = :'partition_start'::timestamptz
      AND partition_end_at = :'partition_end'::timestamptz
      AND status = 'BUILDING'
    ORDER BY created_at DESC
    LIMIT 1
) AS existing_dataset_id
\gset

\if :{?existing_dataset_id}
\set dataset_id :existing_dataset_id
\else
BEGIN;
SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.create_training_dataset(
    'MODEL_A_FEATURES', 'TRAIN',
    :'partition_start'::timestamptz, :'partition_end'::timestamptz, 300,
    :'warmup_start'::timestamptz, :'eligible_start'::timestamptz,
    :'dataset_eligible_end'::timestamptz, :'label_window_end'::timestamptz,
    :'source_as_of'::timestamptz, :'visibility_cutoff'::timestamptz, 1,
    interval '1 day', interval '1 day',
    '146619e9-b414-4135-959f-57b7f2f24510',
    '401aeff4-3882-4476-8487-6ca65ae64f55',
    '9fd08b0c-5890-47dc-8b22-d40b9972ad24',
    interval '1 day', interval '1 day',
    jsonb_build_object(
        'coverage_query_hash', :'coverage_query_hash',
        'source_as_of_at', :'source_as_of',
        'policy', 'DAILY_D_MINUS_1_TOP_50_A0_V1'
    ),
    NULLIF(:'supersedes_dataset_id', '')::uuid, :'actor_user_id'::uuid
) AS dataset_id \gset

SELECT strategy_training.bind_training_dataset_config(
    :'dataset_id'::uuid, config_type, config_version_id
)
FROM strategy_training.training_config_versions
WHERE status = 'READY'
  AND config_type = ANY(ARRAY[
      'TICKER_POOL_RULES', 'DATA_QUALITY_RULES', 'HOLDING_HORIZON_RULES',
      'ELIGIBLE_POOL_RULES', 'REPRODUCIBILITY_TOLERANCE', 'RESOURCE_LIMITS',
      'FEE_MODEL', 'SLIPPAGE_MODEL', 'VISIBILITY_CUTOFF_POLICY'
  ]::text[]);

RESET ROLE;
COMMIT;
\endif

-- Recompute frozen evidence before continuing or resuming the build.
\ir training-data-coverage-preflight.sql

-- Persist one bounded shard per D-1 Top-50 instrument-day. Literal daily bounds
-- keep TimescaleDB chunk pruning effective and avoid cross-month plans.
\set QUIET 1
SELECT format(
$statement$
SELECT strategy_training.record_training_kline_dataset_member(
    %1$L::uuid, %2$L::bigint, %3$L::timestamptz, %4$L::timestamptz
);
$statement$,
    :'dataset_id', entry.instrument_id,
    greatest(coverage_day, :'warmup_start'::timestamptz),
    least(coverage_day + interval '1 day', :'label_window_end'::timestamptz)
)
FROM generate_series(
    :'warmup_start'::date,
    (:'label_window_end'::timestamptz - interval '1 microsecond')::date,
    interval '1 day'
) coverage_day
CROSS JOIN LATERAL (
    SELECT ranked_entry.instrument_id
    FROM market.ranking_entries ranked_entry
    WHERE ranked_entry.ranking_snapshot_id = (
        SELECT snapshot.ranking_snapshot_id
        FROM market.ranking_snapshots snapshot
        WHERE snapshot.ranking_type = 'UTC_DAILY_2355'
          AND snapshot.utc_trade_date = coverage_day::date - 1
          AND snapshot.quality_status = 'VALID'
          AND snapshot.generated_at <= :'source_as_of'::timestamptz
          AND snapshot.created_at <= :'source_as_of'::timestamptz
        ORDER BY snapshot.generated_at DESC, snapshot.ranking_snapshot_id
        LIMIT 1
    )
      AND ranked_entry.rank_no <= :'top_n'::integer
    ORDER BY ranked_entry.rank_no
) entry
WHERE NOT EXISTS (
    SELECT 1
    FROM strategy_training.training_dataset_members member
    WHERE member.dataset_version_id = :'dataset_id'::uuid
      AND member.member_start_at = greatest(
          coverage_day, :'warmup_start'::timestamptz
      )
      AND member.member_end_at = least(
          coverage_day + interval '1 day', :'label_window_end'::timestamptz
      )
      AND member.source_shard_identity LIKE concat(
          'instrument:', entry.instrument_id::text, ':TRADE:300:%'
      )
)
ORDER BY coverage_day, entry.instrument_id
\gexec
\set QUIET 0

-- Persist the canonical point-in-time pool once per eligible day. The trusted
-- database function computes the full governed Top-N once, verifies any partial
-- facts from a prior run, and atomically inserts only the missing rows.
\set QUIET 1
SELECT format(
$statement$
SELECT *
FROM strategy_training.record_historical_pool_day(
    %1$L::uuid, %2$L::timestamptz
);
$statement$,
    :'dataset_id', evaluation_day
)
FROM generate_series(
    :'eligible_start'::timestamptz,
    :'dataset_eligible_end'::timestamptz - interval '1 day',
    interval '1 day'
) evaluation_day
ORDER BY evaluation_day
\gexec
\set QUIET 0

-- The six required reports are derived from the frozen temporary audit table.
BEGIN;
WITH aggregate AS (
    SELECT dependency_name,
           sum(expected_row_count)::bigint AS expected_rows,
           sum(observed_row_count)::bigint AS observed_rows,
           sum(missing_row_count)::bigint AS missing_rows,
           count(*)::bigint AS covered_days
    FROM training_coverage_preflight
    GROUP BY dependency_name
)
SELECT strategy_training.record_training_quality_report(
    :'dataset_id'::uuid,
    '401aeff4-3882-4476-8487-6ca65ae64f55'::uuid,
    dependency_name,
    CASE
        WHEN dependency_name LIKE '%RANKING%' THEN 'RANKING'
        WHEN dependency_name LIKE '%TICKER_POOL%' THEN 'TICKER_POOL'
        WHEN dependency_name LIKE 'EMA%' THEN 'DERIVED_INDICATOR'
        ELSE 'MARKET_DATA'
    END,
    true,
    observed_rows::numeric / expected_rows,
    missing_rows::numeric / expected_rows,
    missing_rows = 0,
    CASE WHEN dependency_name LIKE '%D_MINUS_1' THEN covered_days ELSE observed_rows END,
    1,
    expected_rows, observed_rows, missing_rows,
    CASE WHEN missing_rows = 0 THEN 'PASS' ELSE 'BLOCKED' END,
    CASE WHEN missing_rows = 0 THEN NULL ELSE 'FROZEN_COVERAGE_GAP' END,
    jsonb_build_object(
        'coverage_query_hash', :'coverage_query_hash',
        'source_as_of_at', :'source_as_of',
        'warmup_start_at', :'warmup_start',
        'label_window_end_at', :'label_window_end',
        'covered_days', covered_days,
        'expected_rows', expected_rows,
        'observed_rows', observed_rows,
        'missing_rows', missing_rows
    )
)
FROM aggregate;

SELECT strategy_training.record_training_resource_preflight(
    :'dataset_id'::uuid,
    '4fc0c640-72e8-456b-bd7e-522306c137b6'::uuid,
    1, 0, :'estimated_member_rows'::bigint, 268435456,
    1, 1, 900, 8388608,
    1, 1073741824, 536870912, 189141012480,
    'PASS', '[]'::jsonb,
    jsonb_build_object(
        'assessment', :'resource_assessment',
        'host_available_bytes', 189141012480,
        'container_memory_limit_bytes', 0,
        'estimated_member_rows', :'estimated_member_rows'::bigint,
        'bounded_query_days', :'bounded_query_days'::integer,
        'top_n', 50,
        'source_as_of_at', :'source_as_of'
    )
);

SELECT strategy_training.finalize_training_dataset_fingerprint(
    :'dataset_id'::uuid
) AS root_fingerprint \gset

WITH binding_manifest AS (
    SELECT jsonb_object_agg(config_type, config_version_id::text ORDER BY config_type) AS value,
           encode(digest(string_agg(
               config_type || ':' || config_version_id::text,
               '|' ORDER BY config_type
           ), 'sha256'), 'hex') AS binding_hash
    FROM strategy_training.training_dataset_config_bindings
    WHERE dataset_version_id = :'dataset_id'::uuid
)
SELECT strategy_training.complete_training_dataset_manifest(
    :'dataset_id'::uuid, :'code_commit', :'image_digest',
    :'python_version', :'system_version', :'dependency_lock_hash',
    '059_training_historical_pool_daily_batch',
    jsonb_build_object('dataset_builder', :'dataset_builder',
                       'config_bindings', binding_manifest.value),
    42, 1, 1, 4, 1, :'coverage_query_hash',
    jsonb_build_object(
        'coverage_preflight', :'coverage_query_hash',
        'config_bindings', binding_manifest.binding_hash
    ),
    jsonb_build_object('dataset_root', :'root_fingerprint'),
    :'run_command'
)
FROM binding_manifest;

RESET ROLE;
SET LOCAL ROLE tb2_training_orchestrator;

SELECT strategy_training.transition_training_dataset(
    :'dataset_id'::uuid, 'BUILDING', 'READY',
    :'actor_user_id'::uuid, NULL,
    :'transition_reason',
    gen_random_uuid()
);

COMMIT;

RESET ROLE;
SELECT dataset_version_id, partition, partition_start_at, partition_end_at,
       eligible_start_at, eligible_end_at, source_as_of_at,
       status, root_fingerprint, ready_at
FROM strategy_training.training_dataset_versions
WHERE dataset_version_id = :'dataset_id'::uuid;
