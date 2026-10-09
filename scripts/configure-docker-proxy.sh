#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "请使用 sudo --preserve-env=HTTP_PROXY,HTTPS_PROXY,NO_PROXY 执行此脚本。" >&2
  exit 1
fi

docker_http_proxy=${HTTP_PROXY:-${http_proxy:-}}
docker_https_proxy=${HTTPS_PROXY:-${https_proxy:-}}
docker_no_proxy=${NO_PROXY:-${no_proxy:-}}

if [[ -z ${docker_http_proxy} && -z ${docker_https_proxy} ]]; then
  echo "未检测到 HTTP_PROXY 或 HTTPS_PROXY，未修改 Docker 配置。" >&2
  exit 1
fi

command -v jq >/dev/null
command -v dockerd >/dev/null
command -v systemctl >/dev/null

docker_config=/etc/docker/daemon.json
backup_suffix=$(date -u +%Y%m%dT%H%M%SZ)
working_config=$(mktemp)
trap 'rm -f "${working_config}"' EXIT

install -d -m 0755 /etc/docker

if [[ -f ${docker_config} ]]; then
  install -m 0600 "${docker_config}" "${docker_config}.backup-${backup_suffix}"
  jq \
    --arg http_proxy "${docker_http_proxy}" \
    --arg https_proxy "${docker_https_proxy}" \
    --arg no_proxy "${docker_no_proxy}" \
    '. + {proxies: {"http-proxy": $http_proxy, "https-proxy": $https_proxy, "no-proxy": $no_proxy}}' \
    "${docker_config}" > "${working_config}"
else
  jq -n \
    --arg http_proxy "${docker_http_proxy}" \
    --arg https_proxy "${docker_https_proxy}" \
    --arg no_proxy "${docker_no_proxy}" \
    '{proxies: {"http-proxy": $http_proxy, "https-proxy": $https_proxy, "no-proxy": $no_proxy}}' \
    > "${working_config}"
fi

dockerd --validate --config-file="${working_config}"
install -m 0600 "${working_config}" "${docker_config}"
systemctl restart docker
systemctl is-active --quiet docker

echo "Docker 代理已配置，原配置备份后缀：${backup_suffix}"

