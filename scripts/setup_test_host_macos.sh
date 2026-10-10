#!/usr/bin/env bash
set -Eeuo pipefail

ENABLE_SSH=false

usage() {
  printf '%s\n' \
    'Usage: ./scripts/setup_test_host_macos.sh [--enable-ssh]' \
    '' \
    'Installs/checks the tools required by the Auto Trade test collector.' \
    'Docker Desktop settings that require GUI confirmation are reported at the end.' \
    '' \
    'Options:' \
    '  --enable-ssh  Enable macOS Remote Login after installation.' \
    '  -h, --help    Show this help.'
}

for argument in "$@"; do
  case "$argument" in
    --enable-ssh)
      ENABLE_SSH=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$argument" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'This script must run on macOS.' >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  printf '%s\n' 'Run this script as the login user, not as root.' >&2
  exit 1
fi

printf '%s\n' '==> Checking Apple Command Line Tools'
if ! xcode-select -p >/dev/null 2>&1; then
  printf '%s\n' \
    'Apple Command Line Tools are not installed.' \
    'An installer window will open. Complete it, then run this script again.'
  xcode-select --install || true
  exit 2
fi

printf '%s\n' '==> Checking Homebrew'
if ! command -v brew >/dev/null 2>&1; then
  printf '%s\n' \
    'Homebrew is required for the automated macOS setup.' \
    'Install it from https://brew.sh, open a new terminal, and run this script again.' >&2
  exit 2
fi

printf '%s\n' '==> Installing command-line dependencies'
brew update
brew install git make openssl@3

printf '%s\n' '==> Installing Docker Desktop when absent'
if [[ ! -d /Applications/Docker.app ]]; then
  brew install --cask docker
else
  printf '%s\n' 'Docker Desktop is already installed.'
fi

if [[ "$ENABLE_SSH" == true ]]; then
  printf '%s\n' '==> Enabling macOS Remote Login (SSH)'
  sudo systemsetup -setremotelogin on
else
  printf '%s\n' \
    '==> SSH was not changed.' \
    'Enable System Settings > General > Sharing > Remote Login,' \
    'or rerun this script with --enable-ssh.'
fi

printf '%s\n' '==> Starting Docker Desktop'
open -a Docker

printf '%s\n' '==> Waiting for Docker Engine (up to 180 seconds)'
docker_ready=false
for _attempt in $(seq 1 90); do
  if docker info >/dev/null 2>&1; then
    docker_ready=true
    break
  fi
  sleep 2
done

if [[ "$docker_ready" != true ]]; then
  printf '%s\n' \
    'Docker Engine did not become ready.' \
    'Open Docker Desktop, accept its license/setup prompts, then rerun this script.' >&2
  exit 3
fi

printf '%s\n' '==> Installed versions'
docker --version
docker compose version
git --version
"$(brew --prefix make)/libexec/gnubin/make" --version | head -n 1
"$(brew --prefix openssl@3)/bin/openssl" version
ssh -V 2>&1 | head -n 1

cat <<'EOF'

macOS host preparation completed.

Required manual Docker Desktop settings:
1. Settings > General > enable "Start Docker Desktop when you sign in".
2. Settings > Resources > Network > enable "Host networking".
3. Settings > Resources > Advanced > allocate sufficient memory and disk.

Required macOS settings:
1. System Settings > Energy > enable prevention of automatic sleep.
2. Enable automatic startup after a power failure when available.
3. Prefer wired Ethernet and assign a stable LAN address.

GNU Make is installed as both gmake and through Homebrew's gnubin directory.
The project's current Makefile is also compatible with the make shipped by macOS.
EOF
