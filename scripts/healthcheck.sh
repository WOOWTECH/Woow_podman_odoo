#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
export ODOO_DEPLOY_UID="$(id -u)"
acquire_lifecycle_lock
trap release_lifecycle_lock EXIT

# Validate both exact-name containers before running either check. This avoids
# partially acting on the stack when a same-named foreign container exists.
for name in odoo18-db odoo18-web; do
  assert_healthcheck_container "$name"
done

failed=false
for name in odoo18-db odoo18-web; do
  if ! run_owned_healthcheck "$name"; then
    log "$name native healthcheck failed"
    failed=true
  fi
done
$failed && exit 1
