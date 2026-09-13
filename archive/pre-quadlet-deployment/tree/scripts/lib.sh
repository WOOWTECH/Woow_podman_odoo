#!/usr/bin/env bash
set -euo pipefail
umask 077

PROJECT_ROOT="${ODOO_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
RUNTIME_DIR="$PROJECT_ROOT/.runtime"
BACKUP_DIR="$PROJECT_ROOT/backups"
PODMAN_BIN="${PODMAN_BIN:-podman}"
PODMAN_COMPOSE_BIN="${PODMAN_COMPOSE_BIN:-podman-compose}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
STACK=odoo18
OWNER_UID="${ODOO_DEPLOY_UID:-$(id -u)}"
ODOO_IMAGE='docker.io/library/odoo:18.0@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67'
DB_IMAGE='docker.io/pgvector/pgvector:0.8.0-pg16@sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9'

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
compose() { "$PODMAN_COMPOSE_BIN" -p "$STACK" -f "$PROJECT_ROOT/docker-compose.yml" "$@"; }

acquire_lifecycle_lock() {
  local lock_file="$RUNTIME_DIR/.lifecycle.lock" current=
  mkdir -p "$RUNTIME_DIR"; chmod 700 "$RUNTIME_DIR"
  require_command flock
  python3 - "$lock_file" <<'PY'
import os, stat, sys
path = sys.argv[1]
fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise OSError("lifecycle lock is not a regular file")
    os.fchmod(fd, 0o600)
finally:
    os.close(fd)
PY
  if [[ ${ODOO_LIFECYCLE_LOCK_FD:-} =~ ^[0-9]+$ && -e /proc/$$/fd/$ODOO_LIFECYCLE_LOCK_FD ]]; then
    current=$(readlink -f "/proc/$$/fd/$ODOO_LIFECYCLE_LOCK_FD" 2>/dev/null || true)
  fi
  if [[ "$current" != "$lock_file" ]]; then
    exec {ODOO_LIFECYCLE_LOCK_FD}<>"$lock_file"
    export ODOO_LIFECYCLE_LOCK_FD
  fi
  # Re-locking an inherited open-file description succeeds immediately; a
  # forged unlocked descriptor is safely locked here rather than trusted.
  flock -x "$ODOO_LIFECYCLE_LOCK_FD"
}
release_lifecycle_lock() {
  if [[ ${ODOO_LIFECYCLE_LOCK_FD:-} =~ ^[0-9]+$ ]]; then
    flock -u "$ODOO_LIFECYCLE_LOCK_FD"
    eval "exec ${ODOO_LIFECYCLE_LOCK_FD}>&-"
    unset ODOO_LIFECYCLE_LOCK_FD
  fi
}

resource_exists() { "$PODMAN_BIN" "$1" inspect "$2" >/dev/null 2>&1; }
assert_resource() {
  local kind=$1 name=$2 labels format
  resource_exists "$kind" "$name" || return 0
  case "$kind" in
    container) format='{{ index .Config.Labels "io.woowtech.stack" }} {{ index .Config.Labels "io.woowtech.owner" }}';;
    network|volume) format='{{ index .Labels "io.woowtech.stack" }} {{ index .Labels "io.woowtech.owner" }}';;
    *) die "unsupported resource kind: $kind";;
  esac
  labels=$("$PODMAN_BIN" "$kind" inspect --format "$format" "$name") || die "cannot inspect $kind $name"
  [[ "$labels" == "$STACK $OWNER_UID" ]] || die "refusing foreign $kind $name (labels must be $STACK/$OWNER_UID)"
}
validate_resources() {
  assert_resource container odoo18-db
  assert_resource container odoo18-web
  assert_resource network odoo18-network
  assert_resource volume odoo18-db-data
  assert_resource volume odoo18-web-data
}
namespace_stat() { "$PODMAN_BIN" unshare stat -c "$1" "$2"; }
validate_web_filestore() {
  local action=$1 mountpoint
  resource_exists volume odoo18-web-data || die "missing expected volume: odoo18-web-data"
  assert_resource volume odoo18-web-data
  mountpoint=$("$PODMAN_BIN" volume inspect --format '{{.Mountpoint}}' odoo18-web-data) || die "cannot inspect web volume mountpoint"
  [[ -n "$mountpoint" && "$mountpoint" == /* && "$mountpoint" != / && "$mountpoint" != *$'\n'* ]] || die "unsafe web volume mountpoint"
  if ! "$PODMAN_BIN" unshare python3 - "$mountpoint" "$action" <<'PY'
import os
import stat
import sys


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


mountpoint, action = sys.argv[1:]
if action not in ("create", "check"):
    fail("invalid filestore validation action")
if not os.path.isabs(mountpoint) or os.path.normpath(mountpoint) != mountpoint or mountpoint == os.sep:
    fail("unsafe web volume mountpoint")

flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    volume_fd = os.open(mountpoint, flags)
except OSError as exc:
    fail(f"web volume mountpoint is not a safe directory: {exc.strerror}")
try:
    volume = os.fstat(volume_fd)
    if not stat.S_ISDIR(volume.st_mode):
        fail("web volume mountpoint is not a directory")
    if (volume.st_uid, volume.st_gid) != (100, 101):
        fail("wrong web volume ownership (expected 100:101)")

    created = False
    try:
        filestore_fd = os.open("filestore", flags, dir_fd=volume_fd)
    except FileNotFoundError:
        if action != "create":
            fail("missing filestore directory")
        try:
            os.mkdir("filestore", mode=0o700, dir_fd=volume_fd)
            created = True
        except FileExistsError:
            pass
        except OSError as exc:
            fail(f"cannot create filestore directory: {exc.strerror}")
        try:
            filestore_fd = os.open("filestore", flags, dir_fd=volume_fd)
        except OSError as exc:
            fail(f"filestore is not a safe directory: {exc.strerror}")
    except OSError as exc:
        fail(f"filestore is not a safe directory: {exc.strerror}")

    try:
        if created:
            os.fchown(filestore_fd, 100, 101)
            os.fchmod(filestore_fd, 0o700)
        filestore = os.fstat(filestore_fd)
        if not stat.S_ISDIR(filestore.st_mode):
            fail("filestore is not a directory")
        if (filestore.st_uid, filestore.st_gid) != (100, 101):
            fail("wrong filestore ownership (expected 100:101)")
        if stat.S_IMODE(filestore.st_mode) != 0o700:
            fail("wrong filestore mode (expected 700)")
    finally:
        os.close(filestore_fd)
finally:
    os.close(volume_fd)
PY
  then
    die "web filestore validation failed"
  fi
}
prepare_web_filestore() { validate_web_filestore create; }
assert_web_filestore() { validate_web_filestore check; }
assert_private_file() {
  local file=$1 owner=$2 mode actual
  [[ -f "$file" ]] || die "missing runtime file: $file"
  mode=$(stat -c '%a' "$file")
  [[ "$mode" == 600 ]] || die "unsafe mode on $file (expected 600)"
  actual=$(namespace_stat '%u:%g' "$file")
  [[ "$actual" == "$owner" ]] || die "wrong namespace owner on $file (expected $owner)"
}
assert_health_helper() {
  local file="$PROJECT_ROOT/scripts/odoo-healthcheck.py" mode actual
  [[ -f "$file" && ! -L "$file" ]] || die "missing or invalid Odoo health helper: $file"
  mode=$(stat -c '%a' "$file")
  [[ "$mode" == 755 ]] || die "unsafe mode on $file (expected 755)"
  actual=$(namespace_stat '%u:%g' "$file")
  [[ "$actual" == 0:0 ]] || die "wrong namespace owner on $file (expected 0:0)"
}
assert_runtime_files() {
  assert_private_file "$RUNTIME_DIR/secrets/postgres_password" 999:999
  assert_private_file "$RUNTIME_DIR/secrets/odoo_admin_password" 0:0
  assert_private_file "$RUNTIME_DIR/config/odoo.conf" 100:101
}
health_status() { "$PODMAN_BIN" inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null || true; }
assert_healthcheck_container() {
  local name=$1
  resource_exists container "$name" || die "missing container: $name"
  assert_resource container "$name"
}
run_owned_healthcheck() {
  local name=$1
  assert_healthcheck_container "$name"
  "$PODMAN_BIN" healthcheck run "$name" >/dev/null 2>&1
}
refresh_health_status() {
  local name=$1
  assert_healthcheck_container "$name"
  # Podman 4.9 can leave native health status at "starting" when its
  # systemd-backed scheduler is unavailable. Run the native check directly;
  # its exit status is reflected in the health state inspected below.
  "$PODMAN_BIN" healthcheck run "$name" >/dev/null 2>&1 || true
  health_status "$name"
}
emit_safe_logs() {
  local name=$1 output secret file
  output=$("$PODMAN_BIN" logs --tail 30 "$name" 2>&1) || true
  for file in "$RUNTIME_DIR/secrets/postgres_password" "$RUNTIME_DIR/secrets/odoo_admin_password"; do
    [[ -f "$file" ]] || continue
    if [[ "$file" == */postgres_password ]]; then
      secret=$("$PODMAN_BIN" unshare cat "$file" 2>/dev/null) || { log "Container diagnostics suppressed: cannot load redaction values."; return; }
    else
      secret=$(cat "$file" 2>/dev/null) || { log "Container diagnostics suppressed: cannot load redaction values."; return; }
    fi
    [[ -n "$secret" ]] || { log "Container diagnostics suppressed: empty redaction value."; return; }
    output=${output//"$secret"/[REDACTED]}
  done
  printf '%s\n' "$output" >&2
}
wait_healthy() {
  local name=$1 timeout=$2 elapsed=0 status
  while (( elapsed < timeout )); do
    status=$(refresh_health_status "$name")
    [[ "$status" == healthy ]] && return 0
    [[ "$status" == unhealthy ]] && { emit_safe_logs "$name"; die "$name is unhealthy"; }
    sleep 2; elapsed=$((elapsed + 2))
  done
  emit_safe_logs "$name"
  die "timed out waiting for $name health"
}
