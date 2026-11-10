#!/usr/bin/env bash
# Rebuild a legacy tenant cluster whose bootstrap OID 10 belongs to odoo. PostgreSQL
# forbids demoting its bootstrap role, so the only safe path is a new postgres-owned volume.
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$REPO/scripts/lib/quadlet-lib.sh"
. "$REPO/scripts/common.sh"
. "$REPO/scripts/odoo-helpers.sh"
[[ $# == 0 ]] || ql_die 'migration takes no arguments'
ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
app_env_load
[[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]] || ql_die 'migration requires tenant cloud profile'
[[ $(podman exec odoo18-db psql -X -U odoo -d postgres -Atqc \
  "SELECT oid FROM pg_authid WHERE rolname='odoo'") == 10 ]] \
  || ql_die 'current odoo is not bootstrap OID 10; no rebuild is needed'
ql_secret_ensure odoo18-postgres-super-password random:44
new_volume=odoo18-db-data-isolated
podman volume exists "$new_volume" && ql_die "$new_volume already exists; inspect it before retrying"
stage_container=odoo18-db-isolated-stage
podman container exists "$stage_container" && ql_die "$stage_container already exists; inspect it before retrying"
db_image=$(ql_env_get WOOW_ODOO_DB_IMAGE '')
[[ -n $db_image ]] || db_image=$DB_IMAGE
odoo_image=$(ql_env_get WOOW_ODOO_IMAGE '')
[[ -n $odoo_image ]] || odoo_image=$ODOO_IMAGE
backup_dir=$(app_new_backup_dir tenant-role-migration)
app_snapshot "$backup_dir/units"
work=$backup_dir/work
mkdir -m 700 "$work"
old_web=$(podman inspect --format '{{.State.Running}}' odoo18-web 2>/dev/null || true)
old_gateway=$(podman inspect --format '{{.State.Running}}' odoo18-gateway 2>/dev/null || true)
switched=0 volume_created=0
cleanup() {
  local rc=$?
  podman rm -f "$stage_container" >/dev/null 2>&1 || true
  if ((rc != 0 && switched == 0)); then
    ql_warn 'tenant role migration failed; restoring previous Quadlet units and services'
    app_snapshot_restore "$backup_dir/units" >/dev/null 2>&1 || true
    systemctl --user stop odoo-db.service >/dev/null 2>&1 || true
    systemctl --user start odoo-db.service >/dev/null 2>&1 || true
    if [[ $old_web == true ]]; then systemctl --user start odoo.service >/dev/null 2>&1 || true; fi
    if [[ $old_gateway == true ]]; then systemctl --user start odoo-gateway.service >/dev/null 2>&1 || true; fi
    if ((volume_created)); then podman volume rm "$new_volume" >/dev/null 2>&1 || true; fi
  fi
  return "$rc"
}
ql_cleanup tenant_role_migration cleanup

# The web and gateway stay stopped from this point until the new cluster is verified.
systemctl --user stop odoo-gateway.service 2>/dev/null || true
systemctl --user stop odoo.service
archive=$("$REPO/scripts/backup.sh" --include-secrets)
ql_info "quiesced, validated migration backup: $archive"
python3 "$REPO/scripts/validate-backup.py" "$archive" --extract-to "$work/archive" >/dev/null
dump=$work/archive/databases/odoo.dump
[[ -s $dump ]] || ql_die 'migration backup has no odoo dump'

podman volume create --label io.woowtech.stack=odoo18 "$new_volume" >/dev/null
volume_created=1
podman run -d --name "$stage_container" --network odoo18-network \
  --volume "$new_volume":/var/lib/postgresql/data \
  --env POSTGRES_USER=postgres --env POSTGRES_DB=postgres \
  --env POSTGRES_INITDB_ARGS=--data-checksums \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  --secret odoo18-postgres-super-password,type=mount,target=postgres_password,uid=999,gid=999,mode=0400 \
  "$db_image" >/dev/null
healthy=0
for ((i=0; i<180; i++)); do
  # The entrypoint briefly starts a socket-only bootstrap server; TCP opens only on final postgres.
  if podman exec "$stage_container" pg_isready -q -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; then healthy=1; break; fi
  sleep 1
done
((healthy)) || ql_die 'isolated PostgreSQL did not initialize within 180 seconds'
[[ $(podman exec "$stage_container" psql -X -U postgres -d postgres -Atqc 'SHOW data_checksums') == on ]] \
  || ql_die 'isolated PostgreSQL was not initialized with data checksums'
pw=$(app_secret_read odoo18-postgres-password)
[[ -n $pw ]] || ql_die 'app database password secret missing'
ODOO_DB_PASSWORD=$pw podman exec -i -e ODOO_DB_PASSWORD "$stage_container" \
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
\getenv pw ODOO_DB_PASSWORD
CREATE ROLE odoo LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
\unset pw
SQL
pw=''
podman exec "$stage_container" createdb -U postgres -O odoo --template=template0 \
  --encoding=UTF8 --lc-collate=C odoo
podman exec "$stage_container" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d odoo \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS vector; ALTER EXTENSION vector UPDATE' >/dev/null
podman cp "$dump" "$stage_container:/tmp/tenant-role.dump"
podman exec "$stage_container" sh -c 'pg_restore -l /tmp/tenant-role.dump > /tmp/tenant-role-all.toc'
podman cp "$stage_container:/tmp/tenant-role-all.toc" "$work/toc.all"
awk '!/ EXTENSION / && !/ COMMENT - EXTENSION /' "$work/toc.all" >"$work/toc"
podman cp "$work/toc" "$stage_container:/tmp/tenant-role.toc"
podman exec "$stage_container" pg_restore -U postgres --role=odoo --no-owner --no-acl \
  --exit-on-error --single-transaction -L /tmp/tenant-role.toc -d odoo /tmp/tenant-role.dump
podman exec "$stage_container" rm -f /tmp/tenant-role.toc /tmp/tenant-role-all.toc /tmp/tenant-role.dump

flags=$(podman exec "$stage_container" psql -X -U postgres -d postgres -Atqc \
  "SELECT oid || ',' || rolsuper || ',' || rolcreatedb || ',' || rolcreaterole FROM pg_authid WHERE rolname='odoo'")
[[ $flags =~ ^[0-9]+,false,false,false$ && $flags != 10,* ]] || ql_die "isolated Odoo role has wrong privileges: $flags"
[[ $(podman exec "$stage_container" psql -X -U postgres -d odoo -Atqc \
  "SELECT string_agg(name || ':' || state, ',' ORDER BY name) FROM ir_module_module WHERE name IN ('base','web')") \
  == base:installed,web:installed ]] || ql_die 'isolated database module validation failed'
expected_digest=sha256:$(podman image inspect --format '{{.Id}}' "$odoo_image")
done_json=$(podman exec "$stage_container" psql -X -U odoo -d odoo -Atqc \
  "SELECT value FROM ir_config_parameter WHERE key='woow_paas_platform.upgrade_done'")
python3 - "$done_json" "$expected_digest" <<'PY'
import json,sys
if json.loads(sys.argv[1]).get('digest') != sys.argv[2]:
    raise SystemExit('migration backup has no matching completed upgrade marker')
PY
fs_root=$(podman volume inspect --format '{{.Mountpoint}}' odoo18-web-data)/filestore/odoo
podman exec "$stage_container" psql -X -U postgres -d odoo -Atqc \
  'SELECT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL' \
  | podman unshare python3 "$REPO/scripts/verify-filestore.py" "$fs_root"
ql_info 'isolated PG17 cluster, restricted role, modules, marker and filestore verified'

podman stop "$stage_container" >/dev/null
podman rm "$stage_container" >/dev/null
systemctl --user stop odoo-db.service
systemctl --user stop odoo-db-data-volume.service 2>/dev/null || true
ODOO_TENANT_ROLE_MIGRATION=1 "$REPO/scripts/install.sh" --no-smoke
"$REPO/tests/smoke.sh"
switched=1
rm -rf -- "$work"
ql_info "tenant role migration complete; old database volume odoo18-db-data retained, backup: $archive"
