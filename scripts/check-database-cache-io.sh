#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"

sample_seconds=${1:-60}
if [[ ! ${sample_seconds} =~ ^[1-9][0-9]*$ ]] \
  || ((sample_seconds > 600)); then
  echo "采样秒数必须是1到600之间的整数。" >&2
  exit 2
fi
if [[ ! -f .env ]]; then
  echo "缺少 .env，无法读取数据库连接配置。" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "采样数据库缓存与关系I/O：${sample_seconds}秒"
docker compose exec -T database psql \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  --set=ON_ERROR_STOP=1 \
  --set=sample_seconds="${sample_seconds}" <<'SQL'
CREATE TEMP TABLE database_io_sample AS
SELECT blks_read, blks_hit
FROM pg_stat_database
WHERE datname = current_database();

CREATE TEMP TABLE relation_io_sample AS
SELECT
    relid,
    heap_blks_read,
    heap_blks_hit,
    idx_blks_read,
    idx_blks_hit,
    toast_blks_read,
    toast_blks_hit,
    tidx_blks_read,
    tidx_blks_hit
FROM pg_statio_all_tables;

SELECT pg_sleep(:'sample_seconds'::double precision);

SELECT
    current_stats.blks_read - sample.blks_read AS blocks_read,
    round(
        (current_stats.blks_read - sample.blks_read)
        * current_setting('block_size')::numeric / 1024 / 1024,
        2
    ) AS read_mib,
    current_stats.blks_hit - sample.blks_hit AS blocks_hit,
    round(
        100.0 * (current_stats.blks_hit - sample.blks_hit)
        / NULLIF(
            (current_stats.blks_read - sample.blks_read)
            + (current_stats.blks_hit - sample.blks_hit),
            0
        ),
        2
    ) AS cache_hit_percent
FROM pg_stat_database current_stats
CROSS JOIN database_io_sample sample
WHERE current_stats.datname = current_database();

WITH deltas AS (
    SELECT
        current_stats.schemaname,
        current_stats.relname,
        (
            current_stats.heap_blks_read - sample.heap_blks_read
            + current_stats.idx_blks_read - sample.idx_blks_read
            + current_stats.toast_blks_read - sample.toast_blks_read
            + current_stats.tidx_blks_read - sample.tidx_blks_read
        ) AS blocks_read,
        (
            current_stats.heap_blks_hit - sample.heap_blks_hit
            + current_stats.idx_blks_hit - sample.idx_blks_hit
            + current_stats.toast_blks_hit - sample.toast_blks_hit
            + current_stats.tidx_blks_hit - sample.tidx_blks_hit
        ) AS blocks_hit
    FROM pg_statio_all_tables current_stats
    JOIN relation_io_sample sample USING (relid)
), mapped AS (
    SELECT
        coalesce(
            chunks.hypertable_schema || '.' || chunks.hypertable_name,
            deltas.schemaname || '.' || deltas.relname
        ) AS relation_name,
        sum(deltas.blocks_read) AS blocks_read,
        sum(deltas.blocks_hit) AS blocks_hit
    FROM deltas
    LEFT JOIN timescaledb_information.chunks chunks
      ON chunks.chunk_schema = deltas.schemaname
     AND chunks.chunk_name = deltas.relname
    WHERE deltas.blocks_read + deltas.blocks_hit > 0
    GROUP BY 1
)
SELECT
    relation_name,
    blocks_read,
    round(
        blocks_read * current_setting('block_size')::numeric / 1024 / 1024,
        2
    ) AS read_mib,
    blocks_hit,
    round(
        100.0 * blocks_hit / NULLIF(blocks_read + blocks_hit, 0),
        2
    ) AS cache_hit_percent
FROM mapped
ORDER BY blocks_read DESC
LIMIT 20;
SQL
