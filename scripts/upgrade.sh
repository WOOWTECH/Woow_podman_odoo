#!/usr/bin/env bash
# scripts/upgrade.sh: upgrade Woow Odoo 18 to the images pinned in this checkout, with automatic
# rollback of the units when the upgrade fails.
#
#   git pull && scripts/upgrade.sh [--update-modules] [--no-backup]
#
#   --update-modules   after the upgrade, run `odoo -u all --stop-after-init` for every database.
#                      Off by default: it rewrites module data and takes minutes per database.
#
# Steps: backup -> save the installed units -> scripts/install.sh (pulls the new pinned images before
# any unit changes) -> ALTER EXTENSION vector UPDATE where pgvector is installed -> optional module
# update -> tests/smoke.sh. When install or smoke fails, the saved units are put back and Odoo is
# restarted on the previous images. A database that a newer Odoo has already migrated is not rolled
# back: restore the pre-upgrade archive with scripts/restore.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"

update_modules=0 no_backup=0
while (($#)); do
  case $1 in
    --update-modules) update_modules=1 ;;
    --no-backup) no_backup=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_preflight "$PODMAN_MIN"
[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE does not exist: run scripts/install.sh first"
app_lock

snap=$(app_new_backup_dir upgrade)
data=''
if ((no_backup == 0)); then
  data=$("$REPO/scripts/backup.sh") || ql_die "backup failed; nothing was changed"
  ql_info "pre-upgrade backup: $data"
fi
app_snapshot "$snap/units"
podman inspect --format '{{.Name}} {{.ImageName}} {{.Image}}' odoo18-db odoo18-web >"$snap/images.txt" 2>/dev/null || true

if "$REPO/scripts/install.sh" --no-smoke; then
  # pgvector keeps the extension version of the database it was created in: bring each one forward.
  while IFS= read -r db; do
    [[ -n $db ]] || continue
    if [[ $(podman exec odoo18-db psql -X -U odoo -d "$db" -Atqc "SELECT 1 FROM pg_extension WHERE extname = 'vector'" 2>/dev/null) == 1 ]]; then
      podman exec odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U odoo -d "$db" -c 'ALTER EXTENSION vector UPDATE' >/dev/null \
        && ql_info "pgvector updated in $db"
    fi
  done < <(odoo_databases || true)
  if ((update_modules)); then
    while IFS= read -r db; do
      [[ -n $db ]] || continue
      ql_info "updating modules in $db (this takes a while)"
      podman exec odoo18-web odoo -c /etc/odoo/odoo.conf -d "$db" -u all --stop-after-init --no-http \
        || ql_die "module update failed for $db; restore the pre-upgrade backup with scripts/restore.sh (${data:-no backup was taken})"
    done < <(odoo_databases || true)
    systemctl --user restart odoo.service
    app_wait_healthy odoo18-web 600 odoo.service
  fi
  if "$REPO/tests/smoke.sh"; then
    ql_info "upgrade complete (unit snapshot: $snap)"
    exit 0
  fi
fi

ql_warn "upgrade failed; rolling back to the units saved in $snap/units"
app_snapshot_restore "$snap/units" || ql_die "rollback failed: no usable snapshot. Inspect $snap and journalctl --user -u odoo.service"
systemctl --user restart odoo-db.service odoo.service || true
if ql_wait_container_healthy odoo18-web 300 && "$REPO/tests/smoke.sh" --quick; then
  ql_die "upgrade failed and was rolled back; the previous version is running again"
fi
ql_die "upgrade failed and the rollback is unhealthy too. Restore data with: scripts/restore.sh --archive ${data:-<backup>} --confirm-restore $APP"
