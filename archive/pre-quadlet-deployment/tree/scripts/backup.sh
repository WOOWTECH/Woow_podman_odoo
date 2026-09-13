#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
[[ $# -eq 0 ]] || die "usage: scripts/backup.sh"
export ODOO_DEPLOY_UID="$(id -u)"
acquire_lifecycle_lock
validate_resources; assert_runtime_files
[[ $(health_status odoo18-db) == healthy ]] || die "database must be healthy"
web_was_running=$("$PODMAN_BIN" inspect --format '{{.State.Running}}' odoo18-web) || die "cannot inspect web running state"
[[ "$web_was_running" == true || "$web_was_running" == false ]] || die "cannot determine web running state"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
staging=$(mktemp -d "$BACKUP_DIR/.backup.XXXXXX")
web_restored=false
cleanup_backup() {
  status=$?
  trap - EXIT
  "$PODMAN_BIN" unshare rm -rf "$staging" >/dev/null 2>&1 || true
  if [[ "$web_was_running" == true && "$web_restored" == false ]]; then
    compose start web >/dev/null 2>&1 || log "ERROR: backup could not restore the prior web running state"
  fi
  exit "$status"
}
trap cleanup_backup EXIT

# Keep Odoo quiesced for the complete database and filestore capture. PostgreSQL
# remains available only to the local container command used for the dump.
compose stop web
stamp=$(date -u +%Y%m%dT%H%M%SZ)
root="$staging/odoo18-backup-$stamp"
mkdir -p "$root/volume" "$root/config" "$root/secrets"
"$PODMAN_BIN" exec odoo18-db pg_dump -U odoo --format=custom postgres >"$root/database.dump"
[[ $(head -c 5 "$root/database.dump") == PGDMP ]] || die "database dump is not PostgreSQL custom format"
"$PODMAN_BIN" exec odoo18-db pg_dumpall -U odoo --roles-only >"$root/roles.sql"
mountpoint=$("$PODMAN_BIN" volume inspect --format '{{.Mountpoint}}' odoo18-web-data)
"$PODMAN_BIN" unshare cp -a "$mountpoint/." "$root/volume/"
"$PODMAN_BIN" unshare cp "$RUNTIME_DIR/config/odoo.conf" "$root/config/odoo.conf"
cp "$RUNTIME_DIR/secrets/odoo_admin_password" "$root/secrets/odoo_admin_password"
printf '{"project":"odoo18","created_utc":"%s","images":{"odoo":"%s","database":"%s"}}\n' "$stamp" "$ODOO_IMAGE" "$DB_IMAGE" >"$root/metadata.json"
"$PODMAN_BIN" unshare bash -c 'cd "$1"; find . -type f ! -name SHA256SUMS -print0 | sort -z | while IFS= read -r -d "" file; do sha256sum "${file#./}"; done >SHA256SUMS' sh "$root"
"$PODMAN_BIN" unshare find "$root" -type d -exec chmod 700 {} +
"$PODMAN_BIN" unshare find "$root" -type f -exec chmod 600 {} +
archive="$BACKUP_DIR/odoo18-$stamp.tar"
if [[ -e "$archive" ]]; then archive="$BACKUP_DIR/odoo18-$stamp-$$.tar"; fi
temporary="$staging/$(basename "$archive").tmp"
"$PODMAN_BIN" unshare tar -C "$staging" -cf "$temporary" "$(basename "$root")"
"$PODMAN_BIN" unshare chown 0:0 "$temporary"
chmod 600 "$temporary"
# Publication is atomic and happens only after the exact temporary artifact has
# passed full structural and checksum validation.
python3 "$SCRIPT_DIR/validate-backup.py" "$temporary" >/dev/null
mv "$temporary" "$archive"
if [[ "$web_was_running" == true ]]; then
  compose start web
  web_restored=true
fi
log "Backup created: $archive"
printf '%s\n' "$archive"
