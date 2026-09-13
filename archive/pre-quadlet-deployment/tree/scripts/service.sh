#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
case ${1:-} in
  start)
    # The recursion guard prevents deploy from reinstalling/restarting this
    # service. Start the independently enabled timer only after the stack is up.
    "$SCRIPT_DIR/deploy.sh" --no-systemd
    "$SYSTEMCTL_BIN" --user start odoo18-health.timer
    ;;
  stop)
    export ODOO_DEPLOY_UID="$(id -u)"
    # Quiesce scheduled and in-flight checks before taking the lifecycle lock;
    # a healthcheck process may itself be waiting for that lock.
    "$SYSTEMCTL_BIN" --user stop odoo18-health.timer odoo18-health.service
    acquire_lifecycle_lock
    trap release_lifecycle_lock EXIT
    validate_resources
    compose stop
    ;;

  *) die "usage: scripts/service.sh {start|stop}" ;;
esac
