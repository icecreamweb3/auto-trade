#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: ./scripts/setup_test_host_ubuntu.sh' \
    '' \
    'Installs Docker Engine from Docker official APT repository, Docker Compose v2,' \
    'Git, GNU Make, OpenSSL and OpenSSH Server on supported Ubuntu releases.'
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
  usage
  exit 0
fi
if [[ "$#" -ne 0 ]]; then
  usage >&2
  exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  printf '%s\n' 'This script must run on Ubuntu Linux.' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  printf '%s\n' 'Cannot identify the operating system.' >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != 'ubuntu' ]]; then
  printf 'Unsupported distribution: %s. Ubuntu is required.\n' "${ID:-unknown}" >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  TARGET_USER="${SUDO_USER:-}"
  if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    printf '%s\n' 'Run this script as the normal deployment user; it will use sudo.' >&2
    exit 1
  fi
else
  TARGET_USER="$USER"
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf '%s\n' 'sudo is required.' >&2
  exit 1
fi

printf '%s\n' '==> Installing APT prerequisites and host tools'
sudo apt-get update
sudo apt-get install -y ca-certificates curl git make openssl openssh-server

conflicts=()
for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    conflicts+=("$package")
  fi
done

if [[ "${#conflicts[@]}" -gt 0 ]] && ! dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
  printf 'Conflicting Docker packages are installed: %s\n' "${conflicts[*]}" >&2
  printf '%s\n' \
    'This script will not remove existing packages automatically.' \
    'Review Docker official uninstall-conflicts guidance, remove them intentionally,' \
    'then rerun this script.' >&2
  exit 3
fi

printf '%s\n' '==> Configuring Docker official APT repository'
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ -z "$ubuntu_codename" ]]; then
  printf '%s\n' 'Ubuntu codename is unavailable in /etc/os-release.' >&2
  exit 1
fi

docker_arch="$(dpkg --print-architecture)"
printf '%s\n' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/ubuntu' \
  "Suites: ${ubuntu_codename}" \
  'Components: stable' \
  "Architectures: ${docker_arch}" \
  'Signed-By: /etc/apt/keyrings/docker.asc' \
  | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null

printf '%s\n' '==> Installing Docker Engine and Docker Compose v2'
sudo apt-get update
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

printf '%s\n' '==> Enabling Docker, SSH and UTC time synchronization'
sudo systemctl enable --now docker
sudo systemctl enable --now ssh
sudo timedatectl set-ntp true
sudo timedatectl set-timezone UTC

if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$TARGET_USER"
  group_changed=true
else
  group_changed=false
fi

printf '%s\n' '==> Installed versions'
sudo docker --version
sudo docker compose version
git --version
make --version | head -n 1
openssl version
ssh -V 2>&1 | head -n 1

sudo docker run --rm hello-world >/dev/null

printf '%s\n' '' 'Ubuntu host preparation completed.'
if [[ "$group_changed" == true ]]; then
  printf '%s\n' \
    "User ${TARGET_USER} was added to the docker group." \
    'Log out and log in again before running docker without sudo.' \
    'Membership in the docker group grants root-equivalent Docker access.'
fi
printf '%s\n' \
  'Do not expose PostgreSQL or NATS ports to the public Internet.' \
  'Prefer wired Ethernet and assign a stable LAN address.'
