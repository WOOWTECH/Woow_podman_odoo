#!/usr/bin/env bash
# A Podman reset removed the Odoo network and volumes while systemd still reports
# the generated oneshot units active. A normal install must recover them once.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"

declare -A present=(
  [odoo18-network]=0
  [odoo18-db-data]=0
  [odoo18-web-data]=0
)
declare -a restarted=()
podman() {
  [[ $2 == exists && -v present[$3] ]] || return 2
  [[ ${present[$3]} == 1 ]]
}
systemctl() {
  [[ $1 == --user ]] || return 2
  shift
  case $1 in
    is-active) [[ $2 == --quiet ]] ;;
    restart)
      restarted+=("$2")
      case $2 in
        odoo-network.service) present[odoo18-network]=1 ;;
        odoo-db-data-volume.service) present[odoo18-db-data]=1 ;;
        odoo-web-data-volume.service) present[odoo18-web-data]=1 ;;
        *) return 2 ;;
      esac ;;
    *) return 2 ;;
  esac
}

odoo_reconcile_resources
[[ ${present[odoo18-network]} == 1 && ${present[odoo18-db-data]} == 1 && ${present[odoo18-web-data]} == 1 ]]
[[ ${#restarted[@]} == 3 ]]
odoo_reconcile_resources
[[ ${#restarted[@]} == 3 ]]
echo 'ok   stale active Odoo Quadlet resources are recreated once'
