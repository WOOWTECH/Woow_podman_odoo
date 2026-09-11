#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
restart=false
[[ ${1:-} == --restart-persistence ]] && { restart=true; shift; }
[[ $# -eq 0 ]] || die "usage: scripts/verify.sh [--restart-persistence]"
export ODOO_DEPLOY_UID="$(id -u)"
validate_resources
assert_runtime_files
assert_health_helper
for spec in 'container odoo18-db' 'container odoo18-web' 'network odoo18-network' 'volume odoo18-db-data' 'volume odoo18-web-data'; do
  read -r kind name <<<"$spec"
  resource_exists "$kind" "$name" || die "missing expected $kind: $name"
done

for name in odoo18-db odoo18-web; do
  running=$("$PODMAN_BIN" inspect --format '{{.State.Running}}' "$name" 2>/dev/null) || die "missing container: $name"
  [[ "$running" == true ]] || die "$name is not running"
  [[ $(refresh_health_status "$name") == healthy ]] || die "$name is not healthy"
done

for spec in 'odoo18-db-data 999:999' 'odoo18-web-data 100:101'; do
  read -r volume expected <<<"$spec"
  mountpoint=$("$PODMAN_BIN" volume inspect --format '{{.Mountpoint}}' "$volume")
  [[ $(namespace_stat '%u:%g' "$mountpoint") == "$expected" ]] || die "wrong data ownership on $volume"
  if [[ "$volume" == odoo18-web-data ]]; then
    assert_web_filestore
  fi
done

"$PODMAN_BIN" exec odoo18-db pg_isready -U odoo -d postgres >/dev/null
[[ $("$PODMAN_BIN" exec odoo18-db psql -U odoo -d postgres -Atqc 'SELECT 1') == 1 ]] || die "PostgreSQL query failed"
[[ $("$PODMAN_BIN" exec odoo18-db psql -U odoo -d postgres -Atqc "SELECT default_version FROM pg_available_extensions WHERE name='vector'") == 0.8.0 ]] || die "pgvector 0.8.0 is unavailable"
probe="odoo18_vector_verify_$$"
"$PODMAN_BIN" exec odoo18-db createdb -U odoo "$probe"
trap '"$PODMAN_BIN" exec odoo18-db dropdb -U odoo --if-exists "$probe" >/dev/null 2>&1 || true' EXIT
"$PODMAN_BIN" exec odoo18-db psql -U odoo -d "$probe" -v ON_ERROR_STOP=1 -Atqc 'CREATE EXTENSION vector; SELECT extversion FROM pg_extension WHERE extname='"'"'vector'"'"';' | grep -qx 0.8.0
"$PODMAN_BIN" exec odoo18-db dropdb -U odoo --if-exists "$probe" >/dev/null
trap - EXIT

[[ $("$PODMAN_BIN" port odoo18-web 8069) == 127.0.0.1:18069 ]] || die "Odoo port is not loopback-only"
[[ -z $("$PODMAN_BIN" port odoo18-db) ]] || die "PostgreSQL has a published host port"
curl --noproxy '*' --fail --silent --show-error --max-time 10 http://127.0.0.1:18069/web/health >/dev/null
code=$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --max-time 10 http://127.0.0.1:18069/)
[[ "$code" =~ ^(200|30[12378])$ ]] || die "Odoo root returned HTTP $code"

inspect=$("$PODMAN_BIN" inspect odoo18-db odoo18-web)
db_secret=$("$PODMAN_BIN" unshare cat "$RUNTIME_DIR/secrets/postgres_password")
IFS= read -r admin_secret <"$RUNTIME_DIR/secrets/odoo_admin_password"
[[ "$inspect" != *"$db_secret"* && "$inspect" != *"$admin_secret"* ]] || die "secret found in container inspection"
processes=$("$PODMAN_BIN" top odoo18-db args; "$PODMAN_BIN" top odoo18-web args)
logs=$("$PODMAN_BIN" logs --tail 1000 odoo18-db 2>&1; "$PODMAN_BIN" logs --tail 1000 odoo18-web 2>&1)
[[ "$processes" != *"$db_secret"* && "$processes" != *"$admin_secret"* ]] || die "secret found in process arguments"
[[ "$logs" != *"$db_secret"* && "$logs" != *"$admin_secret"* ]] || die "secret found in container logs"
while IFS= read -r tracked; do
  [[ -f "$PROJECT_ROOT/$tracked" ]] || continue
  content=$(cat "$PROJECT_ROOT/$tracked")
  [[ "$content" != *"$db_secret"* && "$content" != *"$admin_secret"* ]] || die "secret found in tracked file"
done < <(git -C "$PROJECT_ROOT" ls-files)
unset inspect processes logs db_secret admin_secret content

if $restart; then
  before=$("$PODMAN_BIN" unshare sha256sum "$RUNTIME_DIR/secrets/postgres_password" "$RUNTIME_DIR/secrets/odoo_admin_password")
  marker="verify-persistence-$$"
  "$PODMAN_BIN" exec odoo18-web sh -c 'printf "%s" "$1" > /var/lib/odoo/filestore/.persistence-marker' sh "$marker"
  if "$SYSTEMCTL_BIN" --user is-active --quiet odoo18.service 2>/dev/null; then
    "$SYSTEMCTL_BIN" --user restart odoo18.service
  else
    compose stop
    "$SCRIPT_DIR/deploy.sh" --no-systemd
  fi
  wait_healthy odoo18-db 120; wait_healthy odoo18-web 300
  [[ "$before" == "$("$PODMAN_BIN" unshare sha256sum "$RUNTIME_DIR/secrets/postgres_password" "$RUNTIME_DIR/secrets/odoo_admin_password")" ]] || die "credentials changed across restart"
  [[ $("$PODMAN_BIN" exec odoo18-web cat /var/lib/odoo/filestore/.persistence-marker) == "$marker" ]] || die "filestore did not persist"
  [[ $("$PODMAN_BIN" exec odoo18-db psql -U odoo -d postgres -Atqc 'SELECT 1') == 1 ]] || die "database failed after restart"
fi
log "Local verification passed."
