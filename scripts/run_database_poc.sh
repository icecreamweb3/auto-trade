#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"

if [[ ! -f .env ]]; then
  echo "缺少 .env，请先完成本地数据库环境配置。" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

poc_tickers=${POC_TICKERS:-10}
poc_start=${POC_START:-2025-01-01T00:00:00Z}
poc_end=${POC_END:-2026-01-01T00:00:00Z}

if [[ ! ${poc_tickers} =~ ^[1-9][0-9]*$ ]]; then
  echo "POC_TICKERS 必须是正整数。" >&2
  exit 1
fi

mkdir -p artifacts
report_path="artifacts/p0_database_capacity_$(date -u +%Y%m%dT%H%M%SZ).log"

docker compose exec -T database psql \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  --set=ON_ERROR_STOP=1 \
  --set=poc_tickers="${poc_tickers}" \
  --set=poc_start="${poc_start}" \
  --set=poc_end="${poc_end}" \
  < database/p0_capacity_poc.sql \
  | tee "${report_path}"

echo "PoC报告：${report_path}"

