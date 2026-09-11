#!/usr/bin/env bash
# scripts/backup.sh: consistent backup of every Odoo database plus the filestore. Ported from the
# hardened compose variant; the compose calls became systemd unit calls, and it now dumps every Odoo
# database instead of only the "postgres" maintenance database.
#
#   scripts/backup.sh [--include-secrets]
#
#   --include-secrets  also store the database and master passwords in the archive (0600 inside a
#                      0700 directory). Needed to restore onto a host that has no secrets yet.
#
# Odoo is stopped for the capture, so the dumps and the filestore are one point in time; PostgreSQL
# keeps running for the dump. The archive is validated before it is published, and printed on stdout:
#   ~/.local/share/woow-backups/odoo18/odoo18-<UTC stamp>.tar
#     roles.sql  databases/<db>.dump  volume/...  metadata.json  SHA256SUMS  [secrets/...]
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

include_secrets=0
while (($#)); do
  case $1 in
    --include-secrets) include_secrets=1 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
app_lock

[[ $(podman inspect --format '{{.State.Health.Status}}' odoo18-db 2>/dev/null) == healthy ]] \
  || ql_die "odoo18-db is not healthy; refusing to back up"
web_was_running=$(podman inspect --format '{{.State.Running}}' odoo18-web 2>/dev/null || echo false)
(umask 077 && mkdir -p -- "$BACKUP_ROOT") || ql_die "cannot create $BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
staging=$(mktemp -d "$BACKUP_ROOT/.backup.XXXXXX")
web_restored=0
cleanup() {
  local status=$?
  trap - EXIT
  podman unshare rm -rf -- "$staging" >/dev/null 2>&1 || true
  if [[ $web_was_running == true && $web_restored == 0 ]]; then
    systemctl --user start odoo.service >/dev/null 2>&1 || ql_warn "could not start odoo.service again"
  fi
  exit "$status"
}
trap cleanup EXIT

# Quiesce Odoo for the whole capture. The database stays up for the dumps.
systemctl --user stop odoo.service
stamp=$(date -u +%Y%m%dT%H%M%SZ)
root=$staging/odoo18-backup-$stamp
mkdir -p "$root/databases" "$root/volume"

podman exec odoo18-db pg_dumpall -U odoo --roles-only >"$root/roles.sql"
[[ -s $root/roles.sql ]] || ql_die "pg_dumpall --roles-only produced nothing"
dbs_raw=$(odoo_databases) || ql_die "cannot list the databases"
mapfile -t dbs < <(printf '%s' "$dbs_raw" | grep -v '^[[:space:]]*$' || true)
if ((${#dbs[@]} == 0)); then
  ql_warn "no Odoo database exists yet; the archive will hold roles and the filestore only"
fi
for db in "${dbs[@]}"; do
  [[ $db =~ ^[A-Za-z0-9_.-]+$ ]] || ql_die "refusing to back up a database with an unusual name: $db"
  # --file=- would be a literal file named "-" in this image, so the dump is streamed on stdout.
  podman exec odoo18-db pg_dump -U odoo --format=custom "$db" >"$root/databases/$db.dump"
  [[ $(head -c 5 "$root/databases/$db.dump") == PGDMP ]] || ql_die "the dump of $db is not in PostgreSQL custom format"
  ql_info "dumped database $db ($(du -h "$root/databases/$db.dump" | cut -f1))"
done

mountpoint=$(podman volume inspect --format '{{.Mountpoint}}' odoo18-web-data)
[[ $mountpoint == /* && $mountpoint != / ]] || ql_die "unexpected mountpoint for odoo18-web-data"
podman unshare cp -a "$mountpoint/." "$root/volume/"

if ((include_secrets)); then
  mkdir -m 700 "$root/secrets"
  for s in odoo18-postgres-password odoo18-admin-password; do
    (umask 077 && app_secret_read "$s" >"$root/secrets/${s#odoo18-}") || ql_die "cannot read secret $s"
  done
  ql_warn "the archive contains both passwords (--include-secrets): keep it as private as a password"
fi

dblist=''
for db in "${dbs[@]}"; do dblist+="\"$db\","; done
dblist=${dblist%,}
secrets_json=false
((include_secrets == 0)) || secrets_json=true
printf '{"project":"odoo18","created_utc":"%s","databases":[%s],"images":{"odoo":"%s","database":"%s"},"secrets_included":%s}\n' \
  "$stamp" "$dblist" "$ODOO_IMAGE" "$DB_IMAGE" "$secrets_json" >"$root/metadata.json"

podman unshare bash -c 'cd "$1"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | while IFS= read -r -d "" f; do sha256sum "${f#./}"; done >SHA256SUMS' sh "$root"
podman unshare find "$root" -type d -exec chmod 700 {} +
podman unshare find "$root" -type f -exec chmod 600 {} +

archive=$BACKUP_ROOT/odoo18-$stamp.tar
[[ ! -e $archive ]] || archive=$BACKUP_ROOT/odoo18-$stamp-$$.tar
tmp=$staging/publish.tar
podman unshare tar -C "$staging" -cf "$tmp" "odoo18-backup-$stamp"
podman unshare chown 0:0 "$tmp"
chmod 600 "$tmp"
# Publication is atomic and happens only after this exact file passed full validation.
python3 "$REPO/scripts/validate-backup.py" "$tmp" >/dev/null || ql_die "the archive did not validate; nothing was published"
mv "$tmp" "$archive"
(cd "$BACKUP_ROOT" && sha256sum "${archive##*/}" >"${archive##*/}.sha256")
chmod 600 "$archive.sha256"

if [[ $web_was_running == true ]]; then
  systemctl --user start odoo.service
  web_restored=1
  app_wait_healthy odoo18-web 300 odoo.service
fi
ql_info "backup complete: $archive ($(du -h "$archive" | cut -f1))"
printf '%s\n' "$archive"
