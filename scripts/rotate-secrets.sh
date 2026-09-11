#!/usr/bin/env bash
# scripts/rotate-secrets.sh: rotate the generated credentials without ever putting one on a command
# line. This is also the documented fix for a database that was initialised with the password that
# docs/DEPLOYMENT_RECORD.md published before 2026-09.
#
#   scripts/rotate-secrets.sh --db      new database password: ALTER ROLE odoo, replace the secret,
#                                       re-render odoo.conf, restart Odoo
#   scripts/rotate-secrets.sh --admin   new Odoo master (database-manager) password
#   scripts/rotate-secrets.sh --db --admin
#
# The new values are generated. To set one yourself, use a private terminal:
#   read -rs -p 'new password: ' p; printf '%s' "$p" | podman secret create --replace odoo18-admin-password -; unset p
#   scripts/install.sh      # re-renders odoo.conf and restarts Odoo
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"

db=0 admin=0
while (($#)); do
  case $1 in
    --db) db=1 ;;
    --admin) admin=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
((db || admin)) || ql_die "choose --db, --admin or both (see --help)"
ql_require_rootless
app_lock
[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE does not exist: run scripts/install.sh first"
app_env_load

if ((db)); then
  [[ $(podman inspect --format '{{.State.Health.Status}}' odoo18-db 2>/dev/null) == healthy ]] \
    || ql_die "odoo18-db must be running and healthy to change the role password"
  # The secret is replaced first, then the role is set from it, so a crash in between leaves a
  # recoverable state: re-running the command makes the role match the secret again.
  ql_secret_ensure odoo18-postgres-password random:44 --replace
  odoo_set_role_password || ql_die "ALTER ROLE odoo failed; the secret and the database now disagree. Fix the database, then run this command again"
  ql_info "database role password rotated"
fi
if ((admin)); then
  ql_secret_ensure odoo18-admin-password random:44 --replace
  ql_info "master password rotated"
fi

odoo_render_conf_secret
ql_mark_changed "$APP" odoo.service
systemctl --user restart odoo.service
app_wait_healthy odoo18-web 300 odoo.service
"$REPO/tests/smoke.sh" --quick || ql_die "rotation done, but the quick smoke check failed"
ql_info "rotation complete. Read a value in a private terminal with:"
printf "    podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password\n" >&2
