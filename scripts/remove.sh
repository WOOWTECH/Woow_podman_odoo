#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
purge=false; confirm=
while (($#)); do
 case $1 in
  --purge-data) purge=true; shift;;
  --confirm-purge) [[ $# -ge 2 ]] || die "--confirm-purge needs odoo18"; confirm=$2; shift 2;;
  *) die "usage: scripts/remove.sh [--purge-data --confirm-purge odoo18]";;
 esac
done
if $purge; then [[ "$confirm" == odoo18 ]] || die "purge requires --purge-data --confirm-purge odoo18"; elif [[ -n "$confirm" ]]; then die "--confirm-purge requires --purge-data"; fi
export ODOO_DEPLOY_UID="$(id -u)"
# Validate every present exact-name object before the first mutation.
validate_resources
"$SYSTEMCTL_BIN" --user disable --now odoo18-health.timer odoo18.service >/dev/null 2>&1 || true
"$SYSTEMCTL_BIN" --user stop odoo18-health.service >/dev/null 2>&1 || true
for container in odoo18-web odoo18-db; do resource_exists container "$container" && "$PODMAN_BIN" rm -f "$container"; done
resource_exists network odoo18-network && "$PODMAN_BIN" network rm odoo18-network
if $purge; then
 for volume in odoo18-web-data odoo18-db-data; do resource_exists volume "$volume" && "$PODMAN_BIN" volume rm "$volume"; done
 rm -rf -- "$RUNTIME_DIR"
 log "Stack and data removed; backups were preserved."
else
 log "Stack removed; named volumes, runtime credentials, and backups were preserved."
fi
