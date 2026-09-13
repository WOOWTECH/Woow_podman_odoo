#!/usr/bin/env bash
# scripts/restore.sh: restore an archive made by scripts/backup.sh. Ported from the hardened compose
# variant: the archive is validated before anything is touched, a pre-restore backup is taken while
# Odoo is stopped, and a failure after the first database change rolls the whole pre-restore archive
# back before Odoo is allowed to serve again.
#
#   scripts/restore.sh --archive FILE --confirm-restore odoo18 [--restore-secrets]
#
#   --restore-secrets  also put the passwords from the archive (--include-secrets) into the podman
#                      secrets and re-render odoo.conf. Without it the archive's roles are loaded and
#                      the database role is then set back to this host's current password.
#
# Every database in the archive is dropped and recreated. Databases that are not in the archive are
# left alone and reported.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"

archive='' confirm='' restore_secrets=0
while (($#)); do
  case $1 in
    --archive) (($# >= 2)) || ql_die "--archive needs a path"; archive=$2; shift ;;
    --confirm-restore) (($# >= 2)) || ql_die "--confirm-restore needs the word $APP"; confirm=$2; shift ;;
    --restore-secrets) restore_secrets=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -n $archive && $confirm == "$APP" ]] || ql_die "usage: scripts/restore.sh --archive FILE --confirm-restore $APP"
archive=$(realpath -- "$archive")
[[ -f $archive ]] || ql_die "archive not found: $archive"
ql_require_rootless
app_lock
rollback_mode=${ODOO_RESTORE_ROLLBACK:-false}

stage_parent=$(mktemp -d "$BACKUP_ROOT/.restore.XXXXXX")
mutation_started=0 pre_restore='' web_was_running=false stage=''
old_stores=()
# One EXIT trap for both paths: a failure after the first database change (including a ql_die, which
# exits) must roll the pre-restore archive back before Odoo is allowed to serve again.
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if ((status != 0)); then
    systemctl --user stop odoo.service >/dev/null 2>&1
    if ((mutation_started)) && [[ $rollback_mode == false && -n $pre_restore ]]; then
      ql_warn "restore failed after the first change; restoring the pre-restore archive"
      if ODOO_RESTORE_ROLLBACK=true ODOO_RESTORE_MUTATED_ROLES="$stage/roles.sql" \
        "$REPO/scripts/restore.sh" --archive "$pre_restore" --confirm-restore "$APP"; then
        ql_warn "the pre-restore state is back and verified"
      else
        ql_warn "the rollback failed too; Odoo stays stopped so it cannot serve mixed state"
        ql_warn "recovery command: scripts/restore.sh --archive $pre_restore --confirm-restore $APP"
      fi
    elif [[ $web_was_running == true ]]; then
      systemctl --user start odoo.service >/dev/null 2>&1
    fi
  fi
  podman unshare rm -rf -- "$stage_parent" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

# Freeze the caller's pathname into a private file, then validate and extract from that one file.
staged=$stage_parent/source.tar
cp -- "$archive" "$staged"
chmod 400 "$staged"
python3 "$REPO/scripts/validate-backup.py" "$staged" --extract-to "$stage_parent/extracted" >/dev/null \
  || ql_die "the archive did not validate; nothing was changed"
stage=$stage_parent/extracted

mapfile -t dbs < <(find "$stage/databases" -maxdepth 1 -type f -name '*.dump' -printf '%f\n' 2>/dev/null | sed 's|\.dump$||' | LC_ALL=C sort || true)
ql_info "archive holds ${#dbs[@]} database(s): ${dbs[*]:-none}"
web_was_running=$(podman inspect --format '{{.State.Running}}' odoo18-web 2>/dev/null || echo false)

systemctl --user stop odoo.service
[[ $(podman inspect --format '{{.State.Health.Status}}' odoo18-db 2>/dev/null) == healthy ]] \
  || ql_die "odoo18-db is not healthy; refusing to restore"
# The pre-restore snapshot is taken while Odoo is already stopped, so it is one quiesced point in time.
if [[ $rollback_mode == false ]]; then
  pre_restore=$("$REPO/scripts/backup.sh") || ql_die "the pre-restore backup failed; nothing was changed"
  ql_info "pre-restore archive: $pre_restore"
fi

roles_prepared=$stage_parent/roles-idempotent.sql
role_args=()
if [[ $rollback_mode == true && -n ${ODOO_RESTORE_MUTATED_ROLES:-} ]]; then
  [[ -f $ODOO_RESTORE_MUTATED_ROLES ]] || ql_die "missing internal mutated-role record"
  role_args=(--drop-roles-from "$ODOO_RESTORE_MUTATED_ROLES")
fi
python3 "$REPO/scripts/make-roles-idempotent.py" "${role_args[@]}" <"$stage/roles.sql" >"$roles_prepared"

# From here on every failure takes the full-archive rollback path above.
mutation_started=1
podman exec -i odoo18-db psql -X -q --set=ON_ERROR_STOP=1 --single-transaction -U odoo -d postgres <"$roles_prepared"
if ((restore_secrets)); then
  [[ -f $stage/secrets/postgres-password && -f $stage/secrets/admin-password ]] \
    || ql_die "--restore-secrets needs an archive made with --include-secrets"
  for s in postgres admin; do
    podman secret create --replace --label "io.woowtech.app=$APP" "odoo18-$s-password" "$stage/secrets/$s-password" >/dev/null \
      || ql_die "cannot replace secret odoo18-$s-password"
  done
  ql_info "replaced both password secrets from the archive"
fi
# The archived roles carry the password of the backup host; make the role match this host's secret.
odoo_set_role_password || ql_die "could not set the database role password"

mountpoint=$(podman volume inspect --format '{{.Mountpoint}}' odoo18-web-data)
[[ $mountpoint == /* && $mountpoint != / ]] || ql_die "unexpected mountpoint for odoo18-web-data"
for db in "${dbs[@]}"; do
  [[ $db =~ ^[A-Za-z0-9_.-]+$ ]] || ql_die "refusing to restore a database with an unusual name: $db"
  podman exec odoo18-db dropdb -U odoo --if-exists --force "$db"
  podman exec odoo18-db createdb -U odoo -O odoo "$db"
  podman exec -i odoo18-db pg_restore -U odoo --exit-on-error --single-transaction -d "$db" <"$stage/databases/$db.dump"
  ql_info "restored database $db"
  # Filestore for this database only; other databases keep theirs.
  new=$mountpoint/.filestore.restore.$db.$$
  old=$mountpoint/.filestore.previous.$db.$$
  podman unshare mkdir -m 700 -p "$new"
  if podman unshare test -d "$stage/volume/filestore/$db"; then
    podman unshare cp -a "$stage/volume/filestore/$db/." "$new/"
  fi
  podman unshare chown -R 100:101 "$new"
  podman unshare mkdir -m 700 -p "$mountpoint/filestore"
  podman unshare chown 100:101 "$mountpoint/filestore"
  if podman unshare test -e "$mountpoint/filestore/$db"; then podman unshare mv "$mountpoint/filestore/$db" "$old"; old_stores+=("$old"); fi
  podman unshare mv "$new" "$mountpoint/filestore/$db"
done
if ((restore_secrets)); then odoo_render_conf_secret; fi

systemctl --user restart odoo.service
app_wait_healthy odoo18-web 300 odoo.service
"$REPO/tests/smoke.sh" --quick
for old in "${old_stores[@]}"; do podman unshare rm -rf -- "$old" >/dev/null 2>&1 || true; done
if [[ $web_was_running == false && $rollback_mode == false ]]; then
  ql_info "Odoo was stopped before the restore; it is running now so the restore could be verified"
fi
extra=$(comm -23 <(odoo_databases | LC_ALL=C sort) <(printf '%s\n' "${dbs[@]}" | grep -v '^$' | LC_ALL=C sort) || true)
[[ -z $extra ]] || ql_warn "databases not in the archive were left untouched: ${extra//$'\n'/ }"
if [[ $rollback_mode == false ]]; then
  ql_info "restore complete; the pre-restore archive is kept: $pre_restore"
else
  ql_info "pre-restore state restored and verified"
fi
