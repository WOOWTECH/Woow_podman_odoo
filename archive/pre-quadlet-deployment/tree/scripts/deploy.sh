#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

no_systemd=false
[[ ${1:-} == --no-systemd ]] && { no_systemd=true; shift; }
[[ $# -eq 0 ]] || die "usage: scripts/deploy.sh [--no-systemd]"
[[ $(id -u) -ne 0 ]] || die "root execution is not supported"
require_command "$PODMAN_BIN"; require_command "$PODMAN_COMPOSE_BIN"
require_command openssl; require_command curl; require_command python3

podman_version=$("$PODMAN_BIN" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[[ -n "$podman_version" && "$(printf '%s\n' 4.9.3 "$podman_version" | sort -V | head -1)" == 4.9.3 ]] || die "Podman 4.9.3 or newer is required"
compose_version_output=$("$PODMAN_COMPOSE_BIN" --version) || die "could not determine podman-compose version"
compose_versions=()
while IFS= read -r line; do
  if [[ $line =~ ^podman-compose[[:space:]]+version([[:space:]]*:[[:space:]]*|[[:space:]]+)([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$ ]]; then
    compose_versions+=("${BASH_REMATCH[2]}")
  fi
done <<<"$compose_version_output"
[[ ${#compose_versions[@]} -eq 1 && ${compose_versions[0]} == 1.0.6 ]] || die "podman-compose 1.0.6 is required"
if ! $no_systemd; then
  require_command "$SYSTEMCTL_BIN"
  "$SYSTEMCTL_BIN" --user show-environment >/dev/null || die "user systemd is unavailable (or use --no-systemd from the service wrapper)"
fi

export ODOO_DEPLOY_UID="$(id -u)"
acquire_lifecycle_lock
"$SCRIPT_DIR/render-config.sh"
validate_resources
compose up -d db
wait_healthy odoo18-db 120
compose up -d web
prepare_web_filestore
wait_healthy odoo18-web 300
"$SCRIPT_DIR/verify.sh"
# Do not hold the lock while systemd starts the service wrapper, which invokes
# deploy again in another process.
release_lifecycle_lock
if ! $no_systemd; then "$SCRIPT_DIR/install-systemd.sh"; fi
log "Odoo deployment is healthy at http://127.0.0.1:18069"
