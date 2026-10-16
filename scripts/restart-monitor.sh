#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"

command -v docker >/dev/null
docker compose version >/dev/null

echo "[1/5] 构建监控服务镜像"
docker compose --profile runtime build monitor-api monitor-ui

echo "[2/5] 重建 monitor-api"
docker compose --profile runtime up -d \
  --no-deps \
  --force-recreate \
  monitor-api

echo "[3/5] 等待 monitor-api 健康"
for attempt in $(seq 1 30); do
  status=$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      auto-trade-monitor-api
  )

  if [[ ${status} == "healthy" ]]; then
    echo "monitor-api 已健康"
    break
  fi

  if [[ ${attempt} -eq 30 ]]; then
    echo "monitor-api 健康检查超时，最近日志如下：" >&2
    docker compose --profile runtime logs --tail=100 monitor-api >&2
    exit 1
  fi

  sleep 2
done

echo "[4/5] 重建 monitor-ui"
docker compose --profile runtime up -d \
  --no-deps \
  --force-recreate \
  monitor-ui

echo "[5/5] 验证新 REST 权重字段"
docker compose --profile runtime exec -T monitor-api python -c '
import json
import urllib.request

url = "http://127.0.0.1:8000/api/monitoring/overview"
with urllib.request.urlopen(url, timeout=15) as response:
    data = json.load(response)

rest = data["rest_usage"]
required = {
    "average_used_weight_1h",
    "average_utilization_percent_1h",
    "sampled_minutes_1h",
}
missing = sorted(required - rest.keys())
if missing:
    raise RuntimeError(f"监控 API 缺少新字段: {missing}")

result = {
    "近10分钟峰值": rest.get("used_weight_1m"),
    "每分钟上限": rest.get("limit_1m"),
    "近1小时加权均值": rest.get("average_used_weight_1h"),
    "近1小时平均占比": rest.get("average_utilization_percent_1h"),
    "有效分钟样本": rest.get("sampled_minutes_1h"),
}
print(json.dumps(result, ensure_ascii=False, indent=2))
'

echo
docker compose --profile runtime ps monitor-api monitor-ui
echo "监控服务更新完成"
