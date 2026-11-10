#!/usr/bin/env bash
# Tenant cloud restore: build and verify a side database while the live web keeps serving,
# then switch the database and filestore during a short, recoverable maintenance window.
#   restore-online.sh --stage --archive FILE --request ID
#   restore-online.sh --switch --request ID --confirm-restore odoo18
#   restore-online.sh --rollback --request ID --confirm-restore odoo18
#   restore-online.sh --discard --request ID --confirm-restore odoo18
#   restore-online.sh --finalize --request ID --confirm-restore odoo18 (after 24h)
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$REPO/scripts/lib/quadlet-lib.sh"
. "$REPO/scripts/common.sh"
. "$REPO/scripts/odoo-helpers.sh"
mode='' archive='' request='' confirm=''
while (($#)); do
  case $1 in
    --stage|--switch|--rollback|--discard|--finalize) [[ -z $mode ]] || ql_die 'choose one mode'; mode=${1#--} ;;
    --archive|--request|--confirm-restore)
      (($# >= 2)) || ql_die "$1 needs a value"
      case $1 in --archive) archive=$2 ;; --request) request=$2 ;; --confirm-restore) confirm=$2 ;; esac
      shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1" ;;
  esac
  shift
done
[[ $mode == stage || $mode == switch || $mode == rollback || $mode == discard || $mode == finalize ]] || ql_die 'choose --stage, --switch, --rollback, --discard or --finalize'
[[ $request =~ ^[a-z0-9][a-z0-9_-]{0,20}$ ]] || ql_die 'request must be 1-21 lowercase letters, digits, _ or -'
[[ $mode == stage || $confirm == odoo18 ]] || ql_die 'switch/rollback/discard/finalize requires --confirm-restore odoo18'
[[ $mode != stage || -n $archive ]] || ql_die '--stage requires --archive FILE'
ql_require_rootless
ql_lock "$APP"
app_env_load
[[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]] || ql_die 'online restore requires tenant cloud profile'
[[ $(podman exec odoo18-db psql -X -U postgres -d postgres -Atqc \
  "SELECT rolsuper FROM pg_roles WHERE rolname='odoo'" 2>/dev/null) == f ]] \
  || ql_die 'online restore requires an isolated Odoo database role'
root=$BACKUP_ROOT/restore-online
state_dir=$root/$request
state=$state_dir/state
db_stage=odoo__restore_$request
db_old=odoo__old_$request
mountpoint=$(podman volume inspect --format '{{.Mountpoint}}' odoo18-web-data)
[[ $mountpoint == /* && $mountpoint != / ]] || ql_die 'unsafe Odoo volume mountpoint'
fs_root=$mountpoint/filestore
fs_live=$fs_root/odoo
fs_stage=$fs_root/$db_stage
fs_old=$fs_root/$db_old

pg() { local database=$1; shift; podman exec -i odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$database" "$@"; }
oid() { podman exec odoo18-db psql -X -U postgres -d postgres -Atqc \
  "SELECT oid FROM pg_database WHERE datname='$1'"; }
set_connections() { pg postgres -v db="$1" -v yes="$2" >/dev/null <<'SQL'
ALTER DATABASE :"db" ALLOW_CONNECTIONS :yes;
SQL
}
terminate_db() { pg postgres -v db="$1" >/dev/null <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=:'db';
SQL
}
safe_rm_fs() {
  [[ $1 == "$fs_root"/odoo__* ]] || ql_die 'unsafe filestore removal path'
  podman unshare rm -rf -- "$1"
}
stop_web() {
  systemctl --user stop odoo-gateway.service 2>/dev/null || true
  systemctl --user stop odoo.service
}
start_web() {
  systemctl --user start odoo.service
  app_wait_healthy odoo18-web 300 odoo.service
  systemctl --user start odoo-gateway.service
  app_wait_healthy odoo18-gateway 180 odoo-gateway.service
  "$REPO/tests/smoke.sh" --quick
}
read_state() {
  [[ -f $state ]] || ql_die "request $request has no staged state"
  mapfile -t fields <"$state"
  [[ ${#fields[@]} == 5 || ${#fields[@]} == 7 ]] || ql_die 'corrupt restore state'
  status=${fields[0]} live_oid=${fields[1]} stage_oid=${fields[2]} image_id=${fields[3]} archive_sha=${fields[4]}
  created_epoch=${fields[5]:-0}; switched_epoch=${fields[6]:-0}
  [[ $live_oid =~ ^[0-9]+$ && $stage_oid =~ ^[0-9]+$ && $image_id =~ ^sha256:[a-f0-9]{64}$ \
      && $archive_sha =~ ^[a-f0-9]{64}$ && $created_epoch =~ ^[0-9]+$ \
      && $switched_epoch =~ ^[0-9]+$ ]] || ql_die 'invalid restore state'
}
write_state() {
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$status" "$live_oid" "$stage_oid" \
    "$image_id" "$archive_sha" "$created_epoch" "$switched_epoch" >"$state.tmp"
  mv -f -- "$state.tmp" "$state"
}
rollback_swap() {
  local current
  current=$(oid odoo) || return 1
  if [[ $current != "$live_oid" ]]; then
    [[ $(oid "$db_old") == "$live_oid" ]] || return 1
    set_connections odoo false
    terminate_db odoo
    pg postgres -v live=odoo -v old="$db_old" -v stage="$db_stage" >/dev/null <<'SQL'
BEGIN;
ALTER DATABASE :"live" RENAME TO :"stage";
ALTER DATABASE :"old" RENAME TO :"live";
COMMIT;
SQL
  fi
  if podman unshare test -d "$fs_old"; then
    if podman unshare test -d "$fs_live"; then
      if podman unshare test -e "$fs_stage"; then return 1; fi
      podman unshare mv -- "$fs_live" "$fs_stage"
    fi
    if podman unshare test -e "$fs_live"; then return 1; fi
    podman unshare mv -- "$fs_old" "$fs_live"
  fi
  set_connections odoo true
}

if [[ $mode == stage ]]; then
  [[ ! -e $state_dir && -z $(oid "$db_stage") ]] || ql_die 'request already exists; choose a new ID'
  archive=$(realpath -- "$archive")
  [[ -f $archive ]] || ql_die 'archive is missing'
  mkdir -m 700 -p "$root"
  mkdir -m 700 "$state_dir"
  work=$state_dir/work
  mkdir -m 700 "$work"
  complete=0 created=0
  stage_cleanup() {
    local rc=$?
    if ((rc != 0 && complete == 0)); then
      if [[ -n ${dump_in_container:-} ]]; then
        podman exec odoo18-db rm -f -- "$dump_in_container" >/dev/null 2>&1 || true
      fi
      if [[ -n ${toc_in_container:-} ]]; then
        podman exec odoo18-db rm -f -- "$toc_in_container" "$toc_in_container.all" >/dev/null 2>&1 || true
      fi
      if ((created)); then
        podman exec odoo18-db dropdb -U postgres --if-exists --force "$db_stage" >/dev/null 2>&1 || true
      fi
      safe_rm_fs "$fs_stage" >/dev/null 2>&1 || true
      rm -rf -- "$state_dir"
    fi
    return "$rc"
  }
  ql_cleanup online_stage stage_cleanup
  cp -- "$archive" "$work/source.tar"
  python3 "$REPO/scripts/validate-backup.py" "$work/source.tar" --extract-to "$work/extracted" >/dev/null
  python3 - "$work/extracted/metadata.json" "$(podman inspect --format '{{.ImageName}}' odoo18-web)" <<'PY'
import json, sys
meta=json.load(open(sys.argv[1]))
if meta.get('project') != 'odoo18' or meta.get('databases') != ['odoo']:
    raise SystemExit('archive is not a single tenant odoo backup')
if meta.get('images',{}).get('odoo') != sys.argv[2]:
    raise SystemExit('archive image differs from the running Odoo image; use a matching image')
PY
  dump=$work/extracted/databases/odoo.dump
  db_bytes=$(podman exec odoo18-db psql -X -U postgres -d postgres -Atqc "SELECT pg_database_size('odoo')")
  fs_bytes=$(du -sb "$work/extracted/volume/filestore/odoo" 2>/dev/null | cut -f1 || printf 0)
  db_free=$(podman exec odoo18-db df -B1 --output=avail /var/lib/postgresql/data | tail -n 1 | tr -d ' ')
  fs_free=$(podman exec odoo18-web df -B1 --output=avail /var/lib/odoo | tail -n 1 | tr -d ' ')
  [[ $db_bytes =~ ^[0-9]+$ && $fs_bytes =~ ^[0-9]+$ && $db_free =~ ^[0-9]+$ && $fs_free =~ ^[0-9]+$ ]] \
    || ql_die 'cannot measure restore capacity'
  ((db_free * 10 >= db_bytes * 12 && fs_free * 10 >= fs_bytes * 11)) \
    || ql_die 'insufficient free space for staged database or filestore'
  dump_in_container=/tmp/odoo-restore-$request.dump
  podman cp "$dump" "odoo18-db:$dump_in_container"
  podman exec odoo18-db pg_restore -f /dev/null "$dump_in_container" >/dev/null
  archive_sha=$(sha256sum "$work/source.tar"); archive_sha=${archive_sha%% *}
  image_id=sha256:$(podman inspect --format '{{.Image}}' odoo18-web)
  live_oid=$(oid odoo)
  [[ $live_oid =~ ^[0-9]+$ ]] || ql_die 'live database is missing'
  podman exec odoo18-db createdb -U postgres -O odoo --template=template0 --encoding=UTF8 \
    --lc-collate=C "$db_stage"
  created=1
  stage_oid=$(oid "$db_stage")
  pg "$db_stage" >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
ALTER EXTENSION vector UPDATE;
SQL
  toc_in_container=/tmp/odoo-restore-$request.toc
  podman exec odoo18-db sh -c "pg_restore -l '$dump_in_container' > '$toc_in_container.all'"
  podman cp "odoo18-db:$toc_in_container.all" "$work/toc.all"
  awk '!/ EXTENSION / && !/ COMMENT - EXTENSION /' "$work/toc.all" >"$work/toc"
  podman cp "$work/toc" "odoo18-db:$toc_in_container"
  podman exec odoo18-db pg_restore -U postgres --role=odoo --no-owner --no-acl \
    --exit-on-error --single-transaction -L "$toc_in_container" -d "$db_stage" "$dump_in_container" \
    || ql_die 'staged database restore failed; live Odoo was not changed'
  podman exec odoo18-db rm -f -- "$toc_in_container" "$toc_in_container.all" "$dump_in_container"
  podman unshare mkdir -m 700 -- "$fs_stage"
  if [[ -d $work/extracted/volume/filestore/odoo ]]; then
    podman unshare cp -a "$work/extracted/volume/filestore/odoo/." "$fs_stage/"
  fi
  podman unshare chown -R 100:101 "$fs_stage"
  [[ $(podman exec odoo18-db psql -X -U postgres -d "$db_stage" -Atqc \
    "SELECT string_agg(name || ':' || state, ',' ORDER BY name) FROM ir_module_module WHERE name IN ('base','web')") \
    == base:installed,web:installed ]] || ql_die 'staged base/web modules are incomplete'
  [[ $(podman exec odoo18-db psql -X -U postgres -d "$db_stage" -Atqc \
    "SELECT count(*) FROM ir_module_module WHERE state IN ('to install','to upgrade','to remove')") == 0 ]] \
    || ql_die 'staged database contains pending module changes'
  image=$(podman inspect --format '{{.ImageName}}' odoo18-web)
  addons=$(ql_expand_home "$(ql_env_get WOOW_ODOO_ADDONS_DIR)")
  podman run --rm --network odoo18-network \
    --volume odoo18-web-data:/var/lib/odoo:ro \
    --volume "$addons":/mnt/extra-addons:ro,Z \
    --volume "$REPO/scripts/verify-modules.py":/tmp/verify-modules.py:ro,Z \
    --secret odoo18-odoo-conf,type=mount,target=/etc/odoo/odoo.conf,uid=100,gid=101,mode=0400 \
    --entrypoint python3 "$image" /tmp/verify-modules.py --database "$db_stage" --mode post \
    || ql_die 'staged database modules do not match the running image'
  done_json=$(podman exec odoo18-db psql -X -U odoo -d odoo -Atqc \
    "SELECT value FROM ir_config_parameter WHERE key='woow_paas_platform.upgrade_done'")
  python3 - "$done_json" "$image_id" <<'PY'
import json,sys
if json.loads(sys.argv[1]).get('digest') != sys.argv[2]:
    raise SystemExit('live upgrade marker does not match the running image')
PY
  podman exec -i odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U odoo -d "$db_stage" \
    -v value="$done_json" >/dev/null <<'SQL'
INSERT INTO ir_config_parameter(key,value)
VALUES('woow_paas_platform.upgrade_done',:'value')
ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value;
DELETE FROM ir_config_parameter WHERE key='woow_paas_platform.upgrade_attempt';
SQL
  podman exec odoo18-db psql -X -U postgres -d "$db_stage" -Atqc \
    "SELECT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL" \
    | podman unshare python3 "$REPO/scripts/verify-filestore.py" "$fs_stage"
  set_connections "$db_stage" false
  status=staged
  created_epoch=$(date -u +%s)
  switched_epoch=0
  write_state
  rm -rf -- "$work"
  complete=1
  ql_info "request $request staged and verified; live database oid=$live_oid remains active"
  exit 0
fi

read_state
if [[ $mode == switch || $mode == rollback ]]; then
  [[ sha256:$(podman inspect --format '{{.Image}}' odoo18-web) == "$image_id" ]] \
    || ql_die 'Odoo image changed since staging'
fi
if [[ $mode == discard ]]; then
  [[ $status == staged || $status == rolled-back ]] || ql_die "cannot discard request with status $status"
  [[ $(oid odoo) == "$live_oid" && $(oid "$db_stage") == "$stage_oid" && -z $(oid "$db_old") ]] \
    || ql_die 'database identity changed; refusing to discard stage'
  podman exec odoo18-db dropdb -U postgres --if-exists --force "$db_stage"
  safe_rm_fs "$fs_stage"
  status=discarded
  write_state
  ql_info "request $request stage discarded; live database untouched"
  exit 0
fi
if [[ $mode == finalize ]]; then
  [[ $status == switched && $switched_epoch -gt 0 ]] || ql_die "cannot finalize request with status $status"
  (( $(date -u +%s) >= switched_epoch + 86400 )) || ql_die 'previous database must remain available for 24 hours after switch'
  [[ $(oid odoo) == "$stage_oid" && $(oid "$db_old") == "$live_oid" ]] \
    || ql_die 'database identity changed; refusing to finalize'
  podman unshare test -d "$fs_old" || ql_die 'previous filestore is missing'
  podman exec odoo18-db dropdb -U postgres --if-exists --force "$db_old"
  safe_rm_fs "$fs_old"
  status=finalized
  write_state
  ql_info "request $request finalized after 24h; old database and filestore removed"
  exit 0
fi
if [[ $mode == switch ]]; then
  [[ $status == staged ]] || ql_die "request status is $status, expected staged"
  ((created_epoch > 0 && $(date -u +%s) < created_epoch + 86400)) \
    || ql_die 'staged restore expired after 24 hours; discard it and stage a new request'
  [[ $(oid odoo) == "$live_oid" && $(oid "$db_stage") == "$stage_oid" && -z $(oid "$db_old") ]] \
    || ql_die 'database identity changed since staging'
  podman unshare test -d "$fs_stage" && podman unshare test -d "$fs_live" \
    && ! podman unshare test -e "$fs_old" || ql_die 'filestore identity changed since staging'
  stop_web
  switched=0
  switch_cleanup() {
    local rc=$?
    if ((rc != 0 && switched == 0)); then
      ql_warn 'switch failed; restoring original database and filestore'
      if rollback_swap && start_web; then
        status=staged; write_state
        ql_warn 'original Odoo service is healthy again'
      else
        stop_web
        ql_warn 'automatic rollback failed; Odoo remains stopped for manual recovery'
      fi
    fi
    return "$rc"
  }
  ql_cleanup online_switch switch_cleanup
  [[ $(oid odoo) == "$live_oid" ]] || ql_die 'live database changed during cutover'
  set_connections odoo false
  terminate_db odoo
  pg postgres -v live=odoo -v old="$db_old" -v stage="$db_stage" >/dev/null <<'SQL'
BEGIN;
ALTER DATABASE :"live" RENAME TO :"old";
ALTER DATABASE :"stage" RENAME TO :"live";
COMMIT;
SQL
  podman unshare mv -- "$fs_live" "$fs_old"
  podman unshare mv -- "$fs_stage" "$fs_live"
  podman unshare rm -rf -- "$mountpoint/sessions"
  set_connections odoo true
  start_web
  status=switched
  switched_epoch=$(date -u +%s)
  write_state
  switched=1
  ql_info "request $request switched; previous database and filestore retained as $db_old"
  exit 0
fi

[[ $status == switched ]] || ql_die "request status is $status, expected switched"
[[ $(oid "$db_old") == "$live_oid" && $(oid odoo) == "$stage_oid" ]] \
  || ql_die 'database identity changed after switch; refusing rollback'
stop_web
rollback_swap
start_web
status=rolled-back
write_state
ql_info "request $request rolled back and original Odoo is healthy"
