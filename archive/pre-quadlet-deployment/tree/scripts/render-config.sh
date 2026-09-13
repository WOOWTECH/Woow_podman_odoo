#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

mkdir -p "$RUNTIME_DIR/secrets" "$RUNTIME_DIR/config"
chmod 700 "$RUNTIME_DIR" "$RUNTIME_DIR/secrets" "$RUNTIME_DIR/config"
# Hold the shared lifecycle lock across secret discovery, exclusive atomic
# installation, ownership mapping, and config publication.
acquire_lifecycle_lock

created_targets=()
temporary_files=()
cleanup_render() {
  status=$?
  local path
  trap - EXIT
  for path in "${temporary_files[@]:-}"; do [[ -n "$path" ]] && rm -f -- "$path"; done
  if ((status != 0)); then
    for path in "${created_targets[@]:-}"; do [[ -n "$path" ]] && "$PODMAN_BIN" unshare rm -f -- "$path" >/dev/null 2>&1; done
  fi
  exit "$status"
}
trap cleanup_render EXIT

lookup_ids() {
  local image=$1 account=$2
  "$PODMAN_BIN" run --rm --entrypoint sh "$image" -c "id -u '$account'; id -g '$account'"
}
mapfile -t db_ids < <(lookup_ids "$DB_IMAGE" postgres)
mapfile -t web_ids < <(lookup_ids "$ODOO_IMAGE" odoo)
[[ "${db_ids[*]:-}" == "999 999" ]] || die "pinned DB image account mismatch; expected postgres 999:999"
[[ "${web_ids[*]:-}" == "100 101" ]] || die "pinned Odoo image account mismatch; expected odoo 100:101"
assert_health_helper

generate_secret() {
  local target=$1 tmp
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] || die "refusing invalid secret path: $target"
    [[ $(stat -c '%a' "$target") == 600 ]] || die "existing secret has unsafe mode: $target"
    return
  fi
  tmp=$(mktemp "$RUNTIME_DIR/secrets/.secret.XXXXXX")
  temporary_files+=("$tmp")
  openssl rand -base64 32 >"$tmp"
  chmod 600 "$tmp"
  # Hard-link publication is atomic, never overwrites or follows an existing
  # destination, and exposes only the already-complete private file.
  python3 - "$tmp" "$target" <<'PY'
import os, sys
source, target = sys.argv[1:]
os.link(source, target, follow_symlinks=False)
PY
  created_targets+=("$target")
  rm -f -- "$tmp"
}

generate_secret "$RUNTIME_DIR/secrets/postgres_password"
generate_secret "$RUNTIME_DIR/secrets/odoo_admin_password"
"$PODMAN_BIN" unshare chown 999:999 "$RUNTIME_DIR/secrets/postgres_password"
"$PODMAN_BIN" unshare chown 0:0 "$RUNTIME_DIR/secrets/odoo_admin_password"

postgres_password=$("$PODMAN_BIN" unshare cat "$RUNTIME_DIR/secrets/postgres_password")
IFS= read -r admin_password <"$RUNTIME_DIR/secrets/odoo_admin_password"
[[ "$postgres_password" != "$admin_password" ]] || die "generated secrets are not independent"
[[ ${#postgres_password} -ge 43 && ${#admin_password} -ge 43 ]] || die "secret is unexpectedly short"
config_tmp=$(mktemp "$RUNTIME_DIR/config/.odoo.conf.XXXXXX")
temporary_files+=("$config_tmp")
while IFS= read -r line || [[ -n "$line" ]]; do
  line=${line//@POSTGRES_PASSWORD@/$postgres_password}
  line=${line//@ODOO_ADMIN_PASSWORD@/$admin_password}
  printf '%s\n' "$line"
done <"$PROJECT_ROOT/config/odoo.conf.template" >"$config_tmp"
unset postgres_password admin_password
chmod 600 "$config_tmp"
"$PODMAN_BIN" unshare chown 100:101 "$config_tmp"
mv -f "$config_tmp" "$RUNTIME_DIR/config/odoo.conf"
assert_runtime_files
log "Runtime secrets and configuration are ready."
