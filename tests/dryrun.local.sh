# shellcheck shell=bash
# tests/dryrun.local.sh: Odoo-specific assertions. Sourced at the end of tests/dryrun.sh (vendored),
# which provides run_variant, render_variant, $WORK, $REPO, $base, $failures.
# shellcheck disable=SC2154 # the variables above are defined by tests/dryrun.sh

check() { # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
has_line() { grep -qxF -- "$3" "$WORK/$1/out/$2"; }

tenant_env=$WORK/tenant-pinned.env
sed -e 's/^WOOW_ODOO_DEFAULT_DB=.*/WOOW_ODOO_DEFAULT_DB=odoo/' \
    -e 's/^WOOW_ODOO_ADMIN_LOGIN=.*/WOOW_ODOO_ADMIN_LOGIN=tenant@example.invalid/' \
    "$REPO/config/profiles/tenant-cloud.profile" >"$tenant_env"
run_variant tenant-pinned "$tenant_env" "${base[@]}" \
  "$REPO/quadlet/optional/odoo-gateway.container"

check "example publishes Odoo on 127.0.0.1:18069" has_line example odoo.container 'PublishPort=127.0.0.1:18069:8069'
check "example mounts the default addons dir read-only" has_line example odoo.container \
  'Volume=%h/.local/share/odoo18/addons:/mnt/extra-addons:ro,Z'
check "a moved port and a custom addons dir are rendered" has_line fixture-custom odoo.container 'PublishPort=127.0.0.1:28069:8069'
check "the custom addons dir stays read-only" has_line fixture-custom odoo.container 'Volume=%h/src/my-addons:/mnt/extra-addons:ro,Z'
check "the default Odoo image remains pinned" has_line example odoo.container \
  'Image=docker.io/library/odoo:18.0-20260817@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67'
check "the default PostgreSQL image remains pinned" has_line example odoo-db.container \
  'Image=docker.io/pgvector/pgvector:0.8.0-pg16@sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9'
check "a digest-pinned PG17 image renders" has_line fixture-db17 odoo-db.container \
  'Image=jcr-prod.woowtech.io/woow-paas-docker-local/paas-postgres:17.11-20260928.1549@sha256:dbd1fed8882043f45bf759e8f7c73092505ef0afef7a23a93b177e6f7c2c840f'
check "a digest-pinned external Odoo image renders" has_line fixture-image odoo.container \
  'Image=docker.io/library/odoo:18.0-20260926@sha256:eea33387602b203a834d60eee027fcc0d9fcdfd47e310a2d1740ea82322445d7'
check "a valid first-run bootstrap configuration renders" has_line fixture-bootstrap odoo.container \
  'PublishPort=127.0.0.1:18069:8069'
check "BIND=all omits the host address" has_line fixture-lan odoo.container 'PublishPort=18069:8069'
check "optional gateway binds on loopback" has_line example+optional odoo-gateway.container 'PublishPort=127.0.0.1:18080:8080'
check "tenant profile pins the published cloud image" has_line tenant-pinned odoo.container \
  'Image=jcr-prod.woowtech.io/woow-paas-docker-local/cloud-odoo:20261101.1152@sha256:5a0c0f9bed994688230b0d4869ab7f442381f2953149133842bb16065ed37316'
check "tenant profile pins the published PG17 image" has_line tenant-pinned odoo-db.container \
  'Image=jcr-prod.woowtech.io/woow-paas-docker-local/paas-postgres:17.11-20260928.1549@sha256:dbd1fed8882043f45bf759e8f7c73092505ef0afef7a23a93b177e6f7c2c840f'
check "generic profile keeps its existing database volume" has_line example odoo-db-data.volume \
  'VolumeName=odoo18-db-data'
check "tenant profile uses a postgres-owned isolated volume" has_line tenant-pinned odoo-db-data.volume \
  'VolumeName=odoo18-db-data-isolated'
check "tenant database bootstraps as postgres" has_line tenant-pinned odoo-db.container \
  'Environment=POSTGRES_USER=postgres'
check "tenant database alone mounts its superuser secret" has_line tenant-pinned odoo-db.container \
  'Secret=odoo18-postgres-super-password,type=mount,target=postgres_password,uid=999,gid=999,mode=0400'
check "Odoo never mounts the superuser secret" bash -c \
  "! grep -q 'odoo18-postgres-super-password' '$WORK/tenant-pinned/out/odoo.container'"
check "tenant Odoo gate runs before every service start" has_line tenant-pinned odoo.container \
  "ExecStartPre=%h/${REPO#"$HOME/"}/scripts/upgrade-gate.sh --image jcr-prod.woowtech.io/woow-paas-docker-local/cloud-odoo:20261101.1152@sha256:5a0c0f9bed994688230b0d4869ab7f442381f2953149133842bb16065ed37316"
check "generic Odoo service has no tenant upgrade gate" bash -c \
  "! grep -q '^ExecStartPre=.*upgrade-gate.sh' '$WORK/example/out/odoo.container'"
check "the database publishes no port" bash -c "! grep -q '^PublishPort=' '$WORK/example/out/odoo-db.container'"
check "no unit is named odoo18 (a legacy odoo18.service would shadow it)" \
  bash -c "! ls '$REPO'/quadlet | grep -qE '^odoo18\\.(container|service)$'"

# The odoo.conf template renders completely, and only from its own whitelist.
conf_render() {
  ql_render "$REPO/config/odoo.conf.template" - "$REPO/config/odoo.conf.render-vars" - \
    POSTGRES_PASSWORD=db-dummy ODOO_ADMIN_PASSWORD=admin-dummy WOOW_ODOO_LIST_DB=True \
    WOOW_ODOO_WORKERS=2 WOOW_ODOO_MAX_CRON_THREADS=2 WOOW_ODOO_DB_MAXCONN=8 \
    WOOW_ODOO_LIMIT_TIME_CPU=60 WOOW_ODOO_LIMIT_TIME_REAL=120 \
    WOOW_ODOO_LIMIT_TIME_REAL_CRON=600 WOOW_ODOO_LIMIT_REQUEST=65536 \
    DB_NAME_LINE='db_name = odoo' DB_FILTER_LINE='dbfilter = ^odoo$' SMTP_LINES=''
}
conf=$( (conf_render) 2>/dev/null) || conf=''
check "odoo.conf.template renders" test -n "$conf"
check "the rendered conf carries the database password" grep -qx 'db_password = db-dummy' <<<"$conf"
check "the rendered conf carries the master password" grep -qx 'admin_passwd = admin-dummy' <<<"$conf"
check "the conf points at the Quadlet database container" grep -qx 'db_host = odoo18-db' <<<"$conf"
check "the conf includes curated image and host addons" grep -qx \
  'addons_path = /usr/lib/python3/dist-packages/odoo/addons,/opt/woow/addons,/opt/woow/ha-addons,/mnt/extra-addons' <<<"$conf"
check "worker and cron counts render" bash -c "grep -qx 'workers = 2' <<<\"\$1\" && grep -qx 'max_cron_threads = 2' <<<\"\$1\"" _ "$conf"
check "tenant database and timeout limits render" bash -c "grep -Fqx 'dbfilter = ^odoo$' <<<\"\$1\" && grep -Fqx 'db_maxconn = 8' <<<\"\$1\" && grep -Fqx 'limit_time_real_cron = 600' <<<\"\$1\"" _ "$conf"
check "tenant database name renders" grep -Fqx 'db_name = odoo' <<<"$conf"

# Exercise the installer's real config renderer. A fresh tenant must let init-db.py
# create the database, or Odoo starts it first with the default admin/admin login.
render_tenant_conf() (
  local env_file=$1 out=$2
  # shellcheck source=scripts/common.sh
  . "$REPO/scripts/common.sh"
  # shellcheck source=scripts/odoo-helpers.sh
  . "$REPO/scripts/odoo-helpers.sh"
  # shellcheck disable=SC2317 # These mocks are called by the sourced renderer.
  app_secret_read() { printf '%s' 'test-only-password'; }
  # shellcheck disable=SC2317
  ql_secret_ensure() { printf '%s\n' "$ODOO_CONF" >"$out"; }
  ql_env_load "$env_file"
  odoo_render_conf_secret
)
render_tenant_conf "$tenant_env" "$WORK/tenant-first.conf"
check "fresh tenant leaves db_name unset for controlled bootstrap" \
  bash -c "grep -Fqx 'list_db = True' '$WORK/tenant-first.conf' && ! grep -q '^db_name = ' '$WORK/tenant-first.conf'"
sed -e 's/^WOOW_ODOO_LIST_DB=True/WOOW_ODOO_LIST_DB=False/' \
    -e 's/^WOOW_ODOO_DB_FILTER=.*/WOOW_ODOO_DB_FILTER=^odoo$/' \
    "$tenant_env" >"$WORK/tenant-locked.env"
render_tenant_conf "$WORK/tenant-locked.env" "$WORK/tenant-locked.conf"
check "locked tenant pins the initialized database" \
  bash -c "grep -Fqx 'list_db = False' '$WORK/tenant-locked.conf' && grep -Fqx 'db_name = odoo' '$WORK/tenant-locked.conf' && grep -Fqx 'dbfilter = ^odoo$' '$WORK/tenant-locked.conf'"
check "SMTP is absent until configured" bash -c "! grep -q '^smtp_' <<<\"\$1\"" _ "$conf"
check "no default master password in the template" bash -c "! grep -qE '^admin_passwd *= *admin *\$' '$REPO/config/odoo.conf.template'"

# Invalid knobs must stop the render before any file is written.
reject() { # reject <description> <KEY> <bad value>
  local env=$WORK/bad-$2.env
  sed "s|^$2=.*|$2=$3|" "$REPO/config/odoo18.env.example" >"$env"
  mkdir -p "$WORK/bad-$2/src" "$WORK/bad-$2/out"
  cp -p -- "${base[@]}" "$WORK/bad-$2/src/"
  if (render_variant "$WORK/bad-$2/src" "$env" "$WORK/bad-$2/out") >/dev/null 2>&1; then
    echo "FAIL $1 was accepted"
    failures=$((failures + 1))
  else
    echo "ok   $1 is refused"
  fi
}
reject "an addons dir with a Volume option separator" WOOW_ODOO_ADDONS_DIR '%h/addons:rw'
reject "a relative addons dir" WOOW_ODOO_ADDONS_DIR 'addons'
reject "an addons dir with '..'" WOOW_ODOO_ADDONS_DIR '%h/../etc'
reject "a list_db value other than True/False" WOOW_ODOO_LIST_DB yes
reject "an unpinned Odoo image" WOOW_ODOO_IMAGE 'docker.io/library/odoo:18.0'
reject "an unpinned PostgreSQL image" WOOW_ODOO_DB_IMAGE 'docker.io/library/postgres:17'
reject "an Odoo image containing a unit separator" WOOW_ODOO_IMAGE 'docker.io/library/odoo:18.0;ExecStart=evil'
reject "a database name with a quote" WOOW_ODOO_DEFAULT_DB "odoo'bad"
reject "an admin login without a database" WOOW_ODOO_ADMIN_LOGIN 'operator@example.invalid'
reject "tenant mode without a database and admin login" WOOW_ODOO_TENANT_CLOUD True
reject "too many workers" WOOW_ODOO_WORKERS 17
reject "an unsafe database filter" WOOW_ODOO_DB_FILTER '.*'
reject "an invalid database pool size" WOOW_ODOO_DB_MAXCONN 0
reject "SMTP server config injection" WOOW_ODOO_SMTP_SERVER 'host;password=bad'
reject "SMTP port overflow" WOOW_ODOO_SMTP_PORT 70000
gateway_bad=$WORK/bad-gateway-bypass.env
sed -e 's/^WOOW_ODOO_GATEWAY_ENABLED=.*/WOOW_ODOO_GATEWAY_ENABLED=True/' \
    -e 's/^WOOW_ODOO_BIND=.*/WOOW_ODOO_BIND=all/' \
    "$REPO/config/odoo18.env.example" >"$gateway_bad"
if (render_variant "$WORK/example/src" "$gateway_bad" "$WORK/example/out") >/dev/null 2>&1; then
  echo 'FAIL a gateway with a bypassable Odoo bind was accepted'
  failures=$((failures + 1))
else
  echo 'ok   a gateway with a bypassable Odoo bind is refused'
fi
