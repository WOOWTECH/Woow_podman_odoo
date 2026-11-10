# shellcheck shell=bash
# scripts/odoo-helpers.sh: Odoo-specific helpers, sourced after scripts/common.sh. Every function
# that handles a password keeps it in shell variables and pipes; none of them prints one.

# Podman system reset can remove resources while their generated systemd oneshot units still show
# active. Restart only such stale units; inactive dependencies are started by the normal unit path.
odoo_db_volume_name() {
  if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]]; then
    printf '%s' odoo18-db-data-isolated
  else
    printf '%s' odoo18-db-data
  fi
}

# Refuse to create an empty isolated tenant cluster beside an initialized legacy volume.
# The legacy cluster may be stopped, so a role query against a running container is not enough.
odoo_tenant_guard_legacy_volume() {
  local old_mount new_mount
  [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]] || return 0
  podman volume exists odoo18-db-data || return 0
  old_mount=$(podman volume inspect --format '{{.Mountpoint}}' odoo18-db-data) \
    || ql_die 'cannot inspect legacy Odoo database volume'
  [[ $old_mount == /* && $old_mount != / ]] || ql_die 'unsafe legacy Odoo volume mountpoint'
  podman unshare test -f "$old_mount/PG_VERSION" || return 0
  if podman volume exists odoo18-db-data-isolated; then
    new_mount=$(podman volume inspect --format '{{.Mountpoint}}' odoo18-db-data-isolated) \
      || ql_die 'cannot inspect isolated Odoo database volume'
    [[ $new_mount == /* && $new_mount != / ]] || ql_die 'unsafe isolated Odoo volume mountpoint'
    podman unshare test -f "$new_mount/PG_VERSION" && return 0
  fi
  ql_die 'legacy Odoo database volume has data but isolated tenant volume is empty; run scripts/migrate-tenant-db-role.sh before install'
}

odoo_reconcile_resources() {
  local kind name unit spec
  for spec in \
    network:odoo18-network:odoo-network.service \
    "volume:$(odoo_db_volume_name):odoo-db-data-volume.service" \
    volume:odoo18-web-data:odoo-web-data-volume.service; do
    IFS=: read -r kind name unit <<<"$spec"
    if podman "$kind" exists "$name" >/dev/null 2>&1; then continue; fi
    if systemctl --user is-active --quiet "$unit"; then
      ql_info "$name is missing while $unit is active; recreating it"
      systemctl --user restart "$unit" || ql_die "cannot restart $unit"
      podman "$kind" exists "$name" >/dev/null 2>&1 || ql_die "$unit did not recreate $name"
    fi
  done
}

# A fresh PG17 image may be selected, but a PG16 data directory must never be started by it.
odoo_check_db_volume_major() {
  local image=$1 major mountpoint stored
  major=$(podman run --rm --network=none --entrypoint postgres "$image" --version 2>/dev/null) \
    || ql_die "cannot read PostgreSQL version from $image"
  [[ $major =~ PostgreSQL\)[[:space:]]([0-9]+)\. ]] \
    || ql_die "unexpected PostgreSQL version output from $image"
  major=${BASH_REMATCH[1]}
  if ! podman volume exists "$(odoo_db_volume_name)"; then return 0; fi
  mountpoint=$(podman volume inspect --format '{{.Mountpoint}}' "$(odoo_db_volume_name)") \
    || ql_die 'cannot inspect Odoo database volume'
  [[ $mountpoint == /* && $mountpoint != / ]] || ql_die 'unsafe Odoo database volume mountpoint'
  if podman unshare test -f "$mountpoint/PG_VERSION"; then
    stored=$(podman unshare cat "$mountpoint/PG_VERSION") || ql_die 'cannot read PG_VERSION from Odoo volume'
    [[ $stored == "$major" ]] \
      || ql_die "Odoo volume is PostgreSQL $stored; configured image is PostgreSQL $major. Use a new empty instance/volume; do not point a newer server at existing files"
  fi
}

# odoo_render_conf_secret: render config/odoo.conf.template with both passwords and WOOW_ODOO_LIST_DB
# and store the result as the odoo18-odoo-conf secret (replaced only when it differs). Sets
# QL_SECRET_CHANGED=1 when it changed, so the caller restarts odoo.service.
odoo_render_conf_secret() {
  local xt=0 db admin list workers cron db_name_line db_filter_line smtp_lines smtp_server smtp_user smtp_password ODOO_CONF
  [[ $- == *x* ]] && xt=1 && set +x
  db=$(app_secret_read odoo18-postgres-password || true)
  admin=$(app_secret_read odoo18-admin-password || true)
  list=$(ql_env_get WOOW_ODOO_LIST_DB True)
  workers=$(ql_env_get WOOW_ODOO_WORKERS 0)
  cron=$(ql_env_get WOOW_ODOO_MAX_CRON_THREADS 1)
  db_name_line=''
  # Setting db_name on the first start makes Odoo initialize the database itself with
  # its default admin/admin account, before init-db.py can set the requested login.
  # Pin the name only after the database manager has created and verified it.
  if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True && $list == False ]]; then
    db_name_line="db_name = $(ql_env_get WOOW_ODOO_DEFAULT_DB)"
  fi
  db_filter_line=''
  if [[ -n $(ql_env_get WOOW_ODOO_DB_FILTER '') ]]; then
    db_filter_line="dbfilter = $(ql_env_get WOOW_ODOO_DB_FILTER)"
  fi
  smtp_lines=''
  if [[ -n $(ql_env_get WOOW_ODOO_EMAIL_FROM '') ]]; then
    smtp_lines+="email_from = $(ql_env_get WOOW_ODOO_EMAIL_FROM)"$'\n'
  fi
  smtp_server=$(ql_env_get WOOW_ODOO_SMTP_SERVER '')
  smtp_user=$(ql_env_get WOOW_ODOO_SMTP_USER '')
  if [[ -n $smtp_server ]]; then
    smtp_lines+="smtp_server = $smtp_server"$'\n'
    smtp_lines+="smtp_port = $(ql_env_get WOOW_ODOO_SMTP_PORT 587)"$'\n'
    smtp_lines+="smtp_ssl = $(ql_env_get WOOW_ODOO_SMTP_SSL True)"$'\n'
    if [[ -n $smtp_user ]]; then
      smtp_lines+="smtp_user = $smtp_user"$'\n'
      smtp_password=$(app_secret_read odoo18-smtp-password || true)
      if [[ -z $smtp_password || $smtp_password == *$'\n'* || $smtp_password == *$'\r'* ]]; then
        ((xt)) && set -x
        ql_die 'SMTP user requires a nonempty, single-line Podman secret odoo18-smtp-password'
      fi
      smtp_lines+="smtp_password = $smtp_password"$'\n'
      smtp_password=''
    fi
  fi
  if [[ -z $db || -z $admin ]]; then
    ((xt)) && set -x
    ql_die "secrets odoo18-postgres-password and odoo18-admin-password must exist before the conf is rendered"
  fi
  ODOO_CONF=$(ql_render "$REPO/config/odoo.conf.template" - "$REPO/config/odoo.conf.render-vars" - \
    "POSTGRES_PASSWORD=$db" "ODOO_ADMIN_PASSWORD=$admin" "WOOW_ODOO_LIST_DB=$list" \
    "WOOW_ODOO_WORKERS=$workers" "WOOW_ODOO_MAX_CRON_THREADS=$cron" \
    "WOOW_ODOO_DB_MAXCONN=$(ql_env_get WOOW_ODOO_DB_MAXCONN 64)" \
    "WOOW_ODOO_LIMIT_TIME_CPU=$(ql_env_get WOOW_ODOO_LIMIT_TIME_CPU 600)" \
    "WOOW_ODOO_LIMIT_TIME_REAL=$(ql_env_get WOOW_ODOO_LIMIT_TIME_REAL 1200)" \
    "WOOW_ODOO_LIMIT_TIME_REAL_CRON=$(ql_env_get WOOW_ODOO_LIMIT_TIME_REAL_CRON -1)" \
    "WOOW_ODOO_LIMIT_REQUEST=$(ql_env_get WOOW_ODOO_LIMIT_REQUEST 65536)" \
    "DB_NAME_LINE=$db_name_line" \
    "DB_FILTER_LINE=$db_filter_line" \
    "SMTP_LINES=$smtp_lines") || ODOO_CONF=''
  smtp_lines=''
  db='' admin=''
  if [[ -z $ODOO_CONF ]]; then
    ((xt)) && set -x
    ql_die "could not render config/odoo.conf.template"
  fi
  # shellcheck disable=SC2034 # QL_SECRET_CHANGED is set by ql_secret_ensure and read by the caller
  QL_SECRET_CHANGED=0
  ql_secret_ensure odoo18-odoo-conf env:ODOO_CONF --update
  ODOO_CONF=''
  ((xt)) && set -x
  return 0
}

# Render a query-safe gateway configuration; its only variable is the Odoo websocket port.
odoo_render_gateway_conf_secret() {
  local workers ws ODOO_GATEWAY_CONF
  workers=$(ql_env_get WOOW_ODOO_WORKERS 0)
  ws=8069
  ((workers == 0)) || ws=8072
  ODOO_GATEWAY_CONF=$(ql_render "$REPO/config/odoo-gateway.conf.template" - \
    "$REPO/config/odoo-gateway.conf.render-vars" - "ODOO_WS_PORT=$ws") \
    || ql_die 'could not render Odoo gateway configuration'
  # shellcheck disable=SC2034 # ql_secret_ensure sets this for install.sh to read.
  QL_SECRET_CHANGED=0
  ql_secret_ensure odoo18-gateway-conf env:ODOO_GATEWAY_CONF --update
  # shellcheck disable=SC2034 # erase the rendered secret from this shell variable.
  ODOO_GATEWAY_CONF=''
}

# odoo_check_image_account <image> <account> <uid> <gid>: fail closed unless the pinned image runs
# <account> as uid:gid. The secret mounts (uid=999 / uid=100,gid=101) and the volume ownership depend
# on it. Runs a throwaway container once per image ID; the result is cached in the state dir.
odoo_check_image_account() {
  local image=$1 account=$2 want="$3 $4" id got cache
  cache="$(app_state_dir)/image-accounts"
  id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null) || ql_die "cannot inspect $image"
  if grep -qxF -- "$id $account $want" "$cache" 2>/dev/null; then return 0; fi
  got=$(podman run --rm --network=none --entrypoint sh "$image" -c "id -u $account; id -g $account" 2>/dev/null | tr '\n' ' ' || true)
  got=${got% }
  [[ $got == "$want" ]] || ql_die "$image runs $account as '${got:-?}', expected '$want' (uid gid); refusing to continue"
  mkdir -p "$(app_state_dir)" && printf '%s %s %s\n' "$id" "$account" "$want" >>"$cache"
  ql_info "$image runs $account as uid:gid ${want/ /:}"
}

# odoo_addons_check <dir> <fix 0|1>: Odoo runs as uid 100 inside the rootless user namespace, which
# the host sees as "other", so every file needs o+r and every directory o+rx. Nothing is chowned.
odoo_addons_check() {
  local dir=$1 fix=$2 bad
  bad=$(find "$dir" \( -type f ! -perm -o+r \) -o \( -type d ! -perm -o+rx \) -print -quit 2>/dev/null || true)
  [[ -z $bad ]] && return 0
  if ((fix)); then
    chmod -R o+rX -- "$dir" || ql_die "chmod -R o+rX $dir failed"
    ql_info "made $dir readable for the Odoo user (chmod -R o+rX)"
    return 0
  fi
  ql_die "Odoo cannot read $bad (it runs as another uid inside the rootless namespace). Fix: chmod -R o+rX '$dir' (or run install.sh --fix-addon-perms)"
}

# odoo_databases: the Odoo databases (every database except postgres and the templates), one per line
odoo_databases() {
  if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]]; then
    local actor=odoo
    if podman exec odoo18-db psql -X -U postgres -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
      actor=postgres
    fi
    podman exec odoo18-db psql -X -U "$actor" -d postgres -Atqc \
      "SELECT datname FROM pg_database WHERE datname = 'odoo' AND datallowconn"
    return
  fi
  podman exec odoo18-db psql -X -U odoo -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1"
}

# Tenant cloud's first-run database must use Odoo's template0/C collation and expose both
# extensions before users can install cloud addons. The database name is validated by
# render_args; SQL below contains only that identifier, never a credential.
odoo_ensure_tenant_database() {
  local db=$1 collate extensions
  [[ $db =~ ^[a-z][a-z0-9_]{0,62}$ ]] || ql_die 'unsafe tenant database name'
  collate=$(podman exec odoo18-db psql -X -U odoo -d postgres -Atqc \
    "SELECT datcollate FROM pg_database WHERE datname = '$db'" 2>/dev/null) \
    || ql_die "cannot inspect collation of tenant database $db"
  [[ $collate == C ]] \
    || ql_die "tenant database $db has collation '${collate:-missing}', expected C; start with a new empty database volume"
  podman exec odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U postgres -d "$db" -c \
    'CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS vector; ALTER EXTENSION vector UPDATE;' >/dev/null \
    || ql_die "cannot initialize pg_trgm/vector in tenant database $db"
  extensions=$(podman exec odoo18-db psql -X -U odoo -d "$db" -Atqc \
    "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('pg_trgm','vector')" 2>/dev/null) \
    || ql_die "cannot verify tenant extensions in $db"
  [[ $extensions == pg_trgm,vector ]] \
    || ql_die "tenant database $db is missing pg_trgm/vector ($extensions)"
  ql_info "tenant database $db: C collation, pg_trgm and vector verified"
}

# odoo_check_db_password: the database role "odoo" must accept the password recorded in the
# odoo18-postgres-password secret. POSTGRES_PASSWORD_FILE is read only when an EMPTY volume is
# initialised, so a volume adopted from an older deployment keeps whatever password it was created
# with -- including the value this public repository leaked before 2026-09. Without this check the
# only symptom is Odoo timing out with an authentication error buried in its log. The password
# travels through podman's own environment ("-e PGPASSWORD" with no value), never in argv.
# Returns 1 when the password is refused; 0 when it works.
odoo_check_db_password() {
  local xt=0 rc=0
  [[ $- == *x* ]] && xt=1 && set +x
  PGPASSWORD=$(app_secret_read odoo18-postgres-password || true)
  if [[ -z $PGPASSWORD ]]; then
    unset PGPASSWORD
    ((xt)) && set -x
    ql_die "secret odoo18-postgres-password is missing; run scripts/install.sh again"
  fi
  export PGPASSWORD
  podman exec -i -e PGPASSWORD odoo18-db \
    psql -X -q -w -h 127.0.0.1 -U odoo -d postgres -Atc 'SELECT 1' >/dev/null 2>&1 || rc=$?
  unset PGPASSWORD
  ((xt)) && set -x
  return "$rc"
}

# odoo_set_role_password: make the database role "odoo" use the current odoo18-postgres-password
# secret. The statement travels on psql's stdin, never in argv.
odoo_set_role_password() {
  local xt=0 pw rc=0 actor=odoo
  [[ $- == *x* ]] && xt=1 && set +x
  pw=$(app_secret_read odoo18-postgres-password || true)
  if [[ ! $pw =~ ^[A-Za-z0-9+/=_.-]+$ ]]; then
    ((xt)) && set -x
    ql_die "secret odoo18-postgres-password is missing or has unexpected characters"
  fi
  [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) != True ]] || actor=postgres
  ODOO_DB_PASSWORD=$pw podman exec -i -e ODOO_DB_PASSWORD odoo18-db \
    psql -X -q -v ON_ERROR_STOP=1 -U "$actor" -d postgres >/dev/null <<'SQL' || rc=$?
\getenv pw ODOO_DB_PASSWORD
ALTER ROLE odoo PASSWORD :'pw';
\unset pw
SQL
  pw=''
  ((xt)) && set -x
  return "$rc"
}

# The tenant database superuser is never mounted in the Odoo container. On an existing PG
# cluster the old odoo role may still be superuser; create the replacement before changing
# the Quadlet's POSTGRES_USER. The password is passed to psql through an exec environment.
odoo_tenant_prepare_existing_pg() {
  local pw actor role
  [[ $(podman inspect --format '{{.State.Running}}' odoo18-db 2>/dev/null || true) == true ]] || return 0
  role=$(podman exec odoo18-db psql -X -U odoo -d postgres -Atqc \
    "SELECT rolsuper FROM pg_roles WHERE rolname='postgres'" 2>/dev/null || true)
  if [[ -z $role ]]; then
    [[ $(podman exec odoo18-db psql -X -U odoo -d postgres -Atqc \
      "SELECT rolsuper FROM pg_roles WHERE rolname='odoo'") == t ]] \
      || ql_die 'no PostgreSQL superuser role is available for the tenant migration'
    podman exec odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U odoo -d postgres \
      -c 'CREATE ROLE postgres SUPERUSER LOGIN' >/dev/null
  elif [[ $role != t ]]; then
    ql_die 'existing postgres role is not superuser; inspect before changing the database unit'
  fi
  pw=$(app_secret_read odoo18-postgres-super-password)
  [[ -n $pw ]] || ql_die 'PostgreSQL superuser secret is missing'
  ODOO_PG_SUPER_PASSWORD=$pw podman exec -i -e ODOO_PG_SUPER_PASSWORD odoo18-db \
    psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
\getenv pw ODOO_PG_SUPER_PASSWORD
ALTER ROLE postgres PASSWORD :'pw';
\unset pw
SQL
  pw=''
}

odoo_tenant_bootstrap_db() {
  local db=$1 pw exists initialized
  [[ $db == odoo ]] || ql_die 'tenant profile requires database odoo'
  [[ $(podman exec odoo18-db psql -X -U postgres -d postgres -Atqc \
    "SELECT oid FROM pg_authid WHERE rolname='odoo'") != 10 ]] \
    || ql_die 'odoo is the bootstrap superuser (OID 10); migrate to a postgres-owned cluster before installing'
  pw=$(app_secret_read odoo18-postgres-password)
  [[ -n $pw ]] || ql_die 'Odoo database password secret is missing'
  ODOO_DB_PASSWORD=$pw podman exec -i -e ODOO_DB_PASSWORD odoo18-db \
    psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
\getenv pw ODOO_DB_PASSWORD
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='odoo') THEN
    CREATE ROLE odoo LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END $$;
ALTER ROLE odoo PASSWORD :'pw';
\unset pw
SQL
  pw=''
  exists=$(podman exec odoo18-db psql -X -U postgres -d postgres -Atqc \
    "SELECT count(*) FROM pg_database WHERE datname='odoo'")
  if [[ $exists == 0 ]]; then
    podman exec odoo18-db createdb -U postgres -O odoo --template=template0 --encoding=UTF8 \
      --lc-collate=C odoo
  fi
  podman exec odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c 'ALTER DATABASE odoo OWNER TO odoo' >/dev/null
  odoo_ensure_tenant_database odoo
  podman exec odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c 'ALTER ROLE odoo NOSUPERUSER NOCREATEDB NOCREATEROLE' >/dev/null
  initialized=$(podman exec odoo18-db psql -X -U postgres -d odoo -Atqc \
    "SELECT to_regclass('public.ir_module_module') IS NOT NULL")
  [[ $initialized == t ]] || odoo_tenant_init_base "$db"
}

# First install runs entirely before the web and gateway services. -i base is never run
# against an initialized database because it can reset the administrator's noupdate record.
odoo_tenant_init_base() {
  local db=${1:-odoo} addons login secret log_dir
  [[ $db =~ ^[a-z][a-z0-9_]{0,62}$ ]] || ql_die 'unsafe bootstrap database name'
  addons=$(ql_expand_home "$(ql_env_get WOOW_ODOO_ADDONS_DIR)")
  login=$(ql_env_get WOOW_ODOO_ADMIN_LOGIN)
  secret=odoo18-$db-admin-password
  ql_secret_ensure "$secret" random:44
  log_dir=$(app_state_dir)/bootstrap
  (umask 077 && mkdir -p "$log_dir")
  podman run --rm --network odoo18-network --name odoo18-bootstrap \
    --volume odoo18-web-data:/var/lib/odoo \
    --volume "$addons":/mnt/extra-addons:ro,Z \
    --secret odoo18-odoo-conf,type=mount,target=/etc/odoo/odoo.conf,uid=100,gid=101,mode=0400 \
    --entrypoint odoo "$ODOO_IMAGE" -c /etc/odoo/odoo.conf -d "$db" \
    -i base --stop-after-init --no-http >"$log_dir/$db-init.log" 2>&1 \
    || ql_die "tenant base initialization failed; inspect $log_dir/$db-init.log before retrying"
  podman run --rm -i --network odoo18-network --name odoo18-set-admin \
    --volume odoo18-web-data:/var/lib/odoo \
    --volume "$addons":/mnt/extra-addons:ro,Z \
    --secret odoo18-odoo-conf,type=mount,target=/etc/odoo/odoo.conf,uid=100,gid=101,mode=0400 \
    --secret "$secret",type=mount,target=first_admin_password,uid=100,gid=101,mode=0400 \
    --entrypoint odoo "$ODOO_IMAGE" shell -c /etc/odoo/odoo.conf -d "$db" --no-http >"$log_dir/$db-admin.log" 2>&1 <<PY \
    || ql_die "tenant administrator initialization failed; inspect $log_dir/$db-admin.log"
from pathlib import Path
admin = env.ref('base.user_admin')
admin.write({'login': '$login', 'password': Path('/run/secrets/first_admin_password').read_text().strip()})
env.cr.commit()
PY
  ql_info 'tenant database initialized and first administrator credential set before web start'
  ODOO_TENANT_FRESH=1
}
