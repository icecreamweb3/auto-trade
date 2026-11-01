#!/bin/sh
set -eu

project_name="auto-trade-integration-$PPID-$$"
compose_file="compose.integration.yaml"

cleanup() {
    docker compose --project-name "${project_name}" --file "${compose_file}" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! docker compose --project-name "${project_name}" --file "${compose_file}" \
    up --abort-on-container-exit --exit-code-from integration-tests integration-tests; then
    docker compose --project-name "${project_name}" --file "${compose_file}" logs --no-color
    exit 1
fi
