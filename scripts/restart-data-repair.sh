#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"

command -v docker >/dev/null
docker compose version >/dev/null
if [[ ! -f .env ]]; then
  echo "缺少 .env，无法读取数据库连接配置。" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

echo "[1/5] 应用数据库迁移"
docker compose --profile tools run --rm db-migrate

echo "[2/5] 构建 data-repair 镜像"
docker compose --profile runtime build data-repair

echo "[3/5] 重建 data-repair"
docker compose --profile runtime up -d \
  --no-deps \
  --force-recreate \
  data-repair

echo "[4/5] 等待历史扫描检查点初始化"
checkpoint=""
for attempt in $(seq 1 30); do
  container_status=$(
    docker inspect --format '{{.State.Status}}' auto-trade-data-repair
  )
  if [[ ${container_status} != "running" ]]; then
    echo "data-repair 状态异常：${container_status}" >&2
    docker compose --profile runtime logs --tail=100 data-repair >&2
    exit 1
  fi

  checkpoint=$(
    docker compose exec -T database psql \
      -U "${POSTGRES_USER}" \
      -d "${POSTGRES_DB}" \
      --tuples-only \
      --no-align \
      --command \
      "SELECT concat_ws('|', cursor_at, scan_stop_at, COALESCE(completed_at::text, 'RUNNING')) FROM market.backfill_scan_checkpoints WHERE scan_key = 'KLINE_GAP_HISTORY';"
  )
  if [[ -n ${checkpoint} ]]; then
    break
  fi

  if [[ ${attempt} -eq 30 ]]; then
    echo "历史扫描检查点初始化超时，最近日志如下：" >&2
    docker compose --profile runtime logs --tail=100 data-repair >&2
    exit 1
  fi
  sleep 2
done

echo "历史扫描检查点：${checkpoint}"

echo "[5/5] 验证运行配置和日志"
docker inspect auto-trade-data-repair \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^BACKFILL_(WORKER_COUNT|JOBS_PER_CYCLE|REQUEST_INTERVAL_SECONDS)='
docker compose --profile runtime logs --since=2m --tail=30 data-repair
echo "data-repair 更新完成"
