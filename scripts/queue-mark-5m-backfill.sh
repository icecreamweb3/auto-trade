#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "用法: $0 <UTC开始时间> <UTC结束时间>" >&2
  echo "示例: $0 2026-07-21T00:00:00Z 2026-09-01T00:00:00Z" >&2
  exit 2
fi

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"

start_at=$1
end_at=$2

command -v docker >/dev/null
docker compose version >/dev/null
if [[ ! -f .env ]]; then
  echo "缺少 .env，无法读取数据库及 NATS 配置。" >&2
  exit 1
fi

echo "排队 MARK 5m 回补范围：[${start_at}, ${end_at})"
docker compose --profile runtime run --rm --no-deps data-repair \
  python -m auto_trade.collectors.data_repair queue-mark-5m \
  --start "${start_at}" \
  --end "${end_at}"

echo "MARK 5m 回补任务已排队；运行中的 data-repair 将按限速配置处理。"
docker compose exec -T database sh -lc '
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -c "
SELECT status, count(*) AS jobs,
       min(range_start) AS first_start,
       max(range_end) AS last_end
FROM market.backfill_jobs
WHERE data_type = \$\$KLINE_MARK\$\$
  AND EXISTS (
      SELECT 1
      FROM market.data_gaps gap
      WHERE gap.gap_id = market.backfill_jobs.gap_id
        AND gap.interval_seconds = 300
  )
GROUP BY status
ORDER BY status;
"
'
