#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"

set -a
# shellcheck disable=SC1091
source .env
set +a

docker compose exec -T database psql \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  --set=ON_ERROR_STOP=1 \
  -c 'DROP SCHEMA IF EXISTS benchmark CASCADE;'

echo "benchmark Schema 已删除；正式业务Schema未改动。"

