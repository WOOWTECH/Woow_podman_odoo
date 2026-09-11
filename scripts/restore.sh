#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
archive= confirm=
while (($#)); do
 case $1 in
  --archive) [[ $# -ge 2 ]] || die "--archive needs a path"; archive=$2; shift 2;;
  --confirm-restore) [[ $# -ge 2 ]] || die "--confirm-restore needs odoo18"; confirm=$2; shift 2;;
  *) die "usage: scripts/restore.sh --archive PATH --confirm-restore odoo18";;
 esac
done
[[ -n "$archive" && "$confirm" == odoo18 ]] || die "restore requires --archive PATH --confirm-restore odoo18"
archive=$(realpath "$archive"); [[ -f "$archive" ]] || die "archive not found"
rollback_mode=${ODOO_RESTORE_ROLLBACK:-false}
[[ "$rollback_mode" == true || "$rollback_mode" == false ]] || die "invalid internal rollback mode"
export ODOO_DEPLOY_UID="$(id -u)"
acquire_lifecycle_lock
validate_resources; assert_runtime_files
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
stage_parent=$(mktemp -d "$BACKUP_DIR/.restore.XXXXXX")
cleanup_restore() {
  status=$?
  trap - EXIT
  "$PODMAN_BIN" unshare rm -rf "$stage_parent" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup_restore EXIT

# Freeze the caller-controlled pathname into a private inode before validation.
# Validation and extraction then also share one tar descriptor in the validator.
staged_archive="$stage_parent/source.tar"
python3 - "$archive" "$staged_archive" <<'PY'
import os, shutil, sys
source, target = sys.argv[1:]
source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    target_fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o400)
    try:
        with os.fdopen(source_fd, "rb", closefd=False) as incoming, os.fdopen(target_fd, "wb", closefd=False) as outgoing:
            shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
            outgoing.flush()
            os.fsync(target_fd)
    finally:
        os.close(target_fd)
finally:
    os.close(source_fd)
PY
python3 "$SCRIPT_DIR/validate-backup.py" "$staged_archive" --extract-to "$stage_parent/extracted" >/dev/null
stage="$stage_parent/extracted"
web_was_running=$("$PODMAN_BIN" inspect --format '{{.State.Running}}' odoo18-web)
[[ "$web_was_running" == true || "$web_was_running" == false ]] || die "cannot determine web running state"
service_stopped=false mutation_started=false pre_restore= old= new=

recovery_command() {
  local command
  [[ -n "$pre_restore" ]] || return 0
  printf -v command '%q ' "$SCRIPT_DIR/restore.sh" --archive "$pre_restore" --confirm-restore odoo18
  log "Recovery command: ${command% }"
}
restore_failed() {
  status=$?
  local rollback_ok=false
  trap - ERR
  set +e
  # Once any role/database command has begun, serving is forbidden until the
  # complete pre-restore archive has itself been restored and verified.
  compose stop web >/dev/null 2>&1
  if [[ "$mutation_started" == true && "$rollback_mode" == false && -n "$pre_restore" ]]; then
    if ODOO_RESTORE_ROLLBACK=true ODOO_RESTORE_MUTATED_ROLES="$stage/roles.sql" \
         "$SCRIPT_DIR/restore.sh" --archive "$pre_restore" --confirm-restore odoo18; then
      rollback_ok=true
      [[ -n "$old" ]] && "$PODMAN_BIN" unshare rm -rf "$old" >/dev/null 2>&1
      [[ -n "$new" ]] && "$PODMAN_BIN" unshare rm -rf "$new" >/dev/null 2>&1
    fi
  fi
  if [[ "$mutation_started" == true ]]; then
    if [[ "$rollback_ok" == true ]]; then
      if [[ "$web_was_running" == true ]]; then compose start web || rollback_ok=false; else compose stop web >/dev/null 2>&1; fi
    fi
    if [[ "$rollback_ok" == true ]]; then
      log "Restore failed; the complete pre-restore state was restored and verified."
    else
      compose stop web >/dev/null 2>&1
      log "Restore failed; web remains stopped to prevent serving mixed state."
    fi
    recovery_command
  elif [[ "$service_stopped" == true && "$web_was_running" == true ]]; then
    compose start web >/dev/null 2>&1 || log "ERROR: could not restore prior web running state"
  fi
  exit "$status"
}
trap restore_failed ERR

compose stop web
service_stopped=true
# A pre-restore snapshot is taken while web is already stopped, so its database
# and filestore represent one quiesced point in time.
if [[ "$rollback_mode" == false ]]; then pre_restore=$("$SCRIPT_DIR/backup.sh"); fi
roles_prepared="$stage_parent/roles-idempotent.sql"
role_args=()
if [[ "$rollback_mode" == true && -n ${ODOO_RESTORE_MUTATED_ROLES:-} ]]; then
  [[ -f "$ODOO_RESTORE_MUTATED_ROLES" ]] || die "missing internal mutated-role record"
  role_args=(--drop-roles-from "$ODOO_RESTORE_MUTATED_ROLES")
fi
python3 "$SCRIPT_DIR/make-roles-idempotent.py" "${role_args[@]}" <"$stage/roles.sql" >"$roles_prepared"

# Both SQL phases are strict and transactional. From this point onward every
# error takes the full-archive rollback path above, never a local-only rollback.
mutation_started=true
"$PODMAN_BIN" exec -i odoo18-db psql -X --set=ON_ERROR_STOP=1 --single-transaction -U odoo -d postgres <"$roles_prepared"
"$PODMAN_BIN" exec -i odoo18-db pg_restore -U odoo --clean --if-exists --exit-on-error --single-transaction -d postgres <"$stage/database.dump"
mountpoint=$("$PODMAN_BIN" volume inspect --format '{{.Mountpoint}}' odoo18-web-data)
new="$mountpoint/.filestore.restore.$$"; old="$mountpoint/.filestore.previous.$$"
"$PODMAN_BIN" unshare mkdir -m 700 "$new"
if [[ -d "$stage/volume/filestore" ]]; then "$PODMAN_BIN" unshare cp -a "$stage/volume/filestore/." "$new/"; fi
"$PODMAN_BIN" unshare chown -R 100:101 "$new"
if "$PODMAN_BIN" unshare test -e "$mountpoint/filestore"; then "$PODMAN_BIN" unshare mv "$mountpoint/filestore" "$old"; fi
"$PODMAN_BIN" unshare mv "$new" "$mountpoint/filestore"
install_runtime() {
 local source=$1 target=$2 owner=$3 tmp
 tmp=$(mktemp "$(dirname "$target")/.restore.XXXXXX")
 cp "$source" "$tmp"; chmod 600 "$tmp"; "$PODMAN_BIN" unshare chown "$owner" "$tmp"; mv -f "$tmp" "$target"
}
install_runtime "$stage/config/odoo.conf" "$RUNTIME_DIR/config/odoo.conf" 100:101
install_runtime "$stage/secrets/odoo_admin_password" "$RUNTIME_DIR/secrets/odoo_admin_password" 0:0
# Recover the DB secret from its single exact config field without exposing it in argv/logs.
tmp_secret=$(mktemp "$RUNTIME_DIR/secrets/.restore.XXXXXX")
while IFS= read -r line; do case "$line" in 'db_password = '*) printf '%s\n' "${line#db_password = }" >"$tmp_secret";; esac; done < <("$PODMAN_BIN" unshare cat "$RUNTIME_DIR/config/odoo.conf")
[[ -s "$tmp_secret" ]] || die "restored config has no database password"
chmod 600 "$tmp_secret"; "$PODMAN_BIN" unshare chown 999:999 "$tmp_secret"; mv -f "$tmp_secret" "$RUNTIME_DIR/secrets/postgres_password"
assert_runtime_files
"$SCRIPT_DIR/deploy.sh" --no-systemd
"$SCRIPT_DIR/verify.sh"
"$PODMAN_BIN" unshare rm -rf "$old"
if [[ "$web_was_running" == false ]]; then compose stop web; fi
trap - ERR
if [[ "$rollback_mode" == false ]]; then
  log "Restore completed. Pre-restore recovery archive retained: $pre_restore"
else
  log "Pre-restore state restored and verified."
fi
