#!/usr/bin/env bash
# Drive the actual bootstrap helper with controlled PostgreSQL answers.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"
ql_die() { echo "$*" >&2; exit 1; }
app_secret_read() { printf '%s' fake-test-secret; }
odoo_ensure_tenant_database() { :; }
init_calls=0
odoo_tenant_init_base() { init_calls=$((init_calls + 1)); }
podman() {
  case "$*" in
    *'SELECT oid FROM pg_authid'*) echo 123 ;;
    *'SELECT count(*) FROM pg_database'*) echo 1 ;;
    *'SELECT to_regclass'*) echo "$initialized_fixture" ;;
    *'exec -i'*) cat >/dev/null ;;
  esac
  return 0
}
initialized_fixture=f
ODOO_TENANT_FRESH=0
odoo_tenant_bootstrap_db odoo
[[ $init_calls == 1 && $ODOO_TENANT_FRESH == 1 ]]
initialized_fixture=t
ODOO_TENANT_FRESH=0
odoo_tenant_bootstrap_db odoo
[[ $init_calls == 1 && $ODOO_TENANT_FRESH == 0 ]]
echo 'PASS: fresh database is adopted once; existing tenant is never reinitialized'
