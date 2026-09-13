#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Woow Odoo 18 Quadlet units. Keeps all data by default.
#
#   scripts/uninstall.sh                          stop and remove the units; keep volumes, network,
#                                                 secrets, images, the addons dir, ~/.config/odoo18
#                                                 and every backup
#   scripts/uninstall.sh --purge --confirm-purge odoo18   (or --purge --yes)
#                                                 also delete both volumes, the network, the odoo18-*
#                                                 secrets and ~/.config/odoo18, after a final cold
#                                                 backup of both volumes and the env file
#   scripts/uninstall.sh --dry-run                report what would be removed
#
# --purge is the only way this repo deletes data. Images, backups and the addons dir are never deleted.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

purge=0 yes=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --confirm-purge) (($# >= 2)) || ql_die "--confirm-purge needs the word $APP"; [[ $2 == "$APP" ]] || ql_die "--confirm-purge needs the word $APP"; yes=1; shift ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
if ((!purge)); then
  ql_uninstall_units "$APP"
  exit 0
fi

app_confirm "$APP" "$yes" "--purge deletes the Odoo databases, filestore, network, secrets and settings"
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  final=$(app_new_backup_dir final)
  # Cold copies: both containers stop first, so the database files are consistent.
  systemctl --user stop odoo.service odoo-db.service >/dev/null 2>&1 || true
  for v in odoo18-db-data odoo18-web-data; do
    if podman volume exists "$v"; then ql_backup_volume "$v" "$final" >/dev/null; fi
  done
  if [[ -f $ENV_FILE ]]; then install -m 600 -- "$ENV_FILE" "$final/${ENV_FILE##*/}"; fi
  app_checksums "$final"
  ql_info "final backup: $final"
fi
ql_uninstall_units "$APP" --purge
if [[ ${QL_DRY_RUN:-0} == 1 ]]; then
  ql_info "[dry-run] --purge would also remove $HOME/.config/$APP"
else
  rm -rf -- "$HOME/.config/$APP"
  ql_info "removed $HOME/.config/$APP (a copy of the env file is in the final backup); the addons dir is kept"
fi
