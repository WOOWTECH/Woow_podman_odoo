# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/odoo18/odoo18.env. Sourced by
# scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is already loaded from <envfile>; sets RENDER_ARGS=(KEY=VALUE...).
# It also validates the values that are rendered straight from the env file, and dies on a bad one.
render_args() {
  local bind port addons prefix image db login lang gateway gateway_bind gateway_port workers cron smtp_port db_image db_filter value key db_user db_secret db_volume prestart unit_repo
  bind=$(ql_env_get WOOW_ODOO_BIND)
  ql_assert_match WOOW_ODOO_BIND "$bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'
  port=$(ql_env_get WOOW_ODOO_PORT)
  ql_assert_match WOOW_ODOO_PORT "$port" '[1-9][0-9]{0,4}'
  ((port <= 65535)) || ql_die "WOOW_ODOO_PORT: $port is not a TCP port"
  gateway=$(ql_env_get WOOW_ODOO_GATEWAY_ENABLED False)
  ql_assert_match WOOW_ODOO_GATEWAY_ENABLED "$gateway" 'True|False'
  gateway_bind=$(ql_env_get WOOW_ODOO_GATEWAY_BIND 127.0.0.1)
  ql_assert_match WOOW_ODOO_GATEWAY_BIND "$gateway_bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'
  gateway_port=$(ql_env_get WOOW_ODOO_GATEWAY_PORT 18080)
  ql_assert_match WOOW_ODOO_GATEWAY_PORT "$gateway_port" '[1-9][0-9]{0,4}'
  ((gateway_port <= 65535)) || ql_die "WOOW_ODOO_GATEWAY_PORT: $gateway_port is not a TCP port"
  workers=$(ql_env_get WOOW_ODOO_WORKERS 0)
  cron=$(ql_env_get WOOW_ODOO_MAX_CRON_THREADS 1)
  ql_assert_match WOOW_ODOO_WORKERS "$workers" '0|[1-9][0-9]?'
  ql_assert_match WOOW_ODOO_MAX_CRON_THREADS "$cron" '0|[1-9][0-9]?'
  ((workers <= 16 && cron <= 16)) || ql_die 'workers/cron threads must be 0..16'
  for key in WOOW_ODOO_DB_MAXCONN WOOW_ODOO_LIMIT_TIME_CPU WOOW_ODOO_LIMIT_TIME_REAL WOOW_ODOO_LIMIT_REQUEST; do
    value=$(ql_env_get "$key" '')
    [[ -n $value ]] || case $key in
      WOOW_ODOO_DB_MAXCONN) value=64 ;;
      WOOW_ODOO_LIMIT_TIME_CPU) value=600 ;;
      WOOW_ODOO_LIMIT_TIME_REAL) value=1200 ;;
      WOOW_ODOO_LIMIT_REQUEST) value=65536 ;;
    esac
    ql_assert_match "$key" "$value" '[1-9][0-9]{0,6}'
    ((value <= 1000000)) || ql_die "$key exceeds 1000000"
  done
  value=$(ql_env_get WOOW_ODOO_LIMIT_TIME_REAL_CRON -1)
  ql_assert_match WOOW_ODOO_LIMIT_TIME_REAL_CRON "$value" '-1|[1-9][0-9]{0,6}'
  [[ $value == -1 ]] || ((value <= 1000000)) || ql_die 'cron time limit exceeds 1000000'
  db_filter=$(ql_env_get WOOW_ODOO_DB_FILTER '')
  if [[ -n $db_filter ]]; then
    ql_assert_match WOOW_ODOO_DB_FILTER "$db_filter" '\^[a-z][a-z0-9_]{0,62}\$'
  fi
  ql_assert_match WOOW_ODOO_EMAIL_FROM "$(ql_env_get WOOW_ODOO_EMAIL_FROM '')" '[A-Za-z0-9_.+@-]*'
  ql_assert_match WOOW_ODOO_SMTP_SERVER "$(ql_env_get WOOW_ODOO_SMTP_SERVER '')" '[A-Za-z0-9.-]*'
  ql_assert_match WOOW_ODOO_SMTP_USER "$(ql_env_get WOOW_ODOO_SMTP_USER '')" '[A-Za-z0-9_.+@-]*'
  ql_assert_match WOOW_ODOO_SMTP_SSL "$(ql_env_get WOOW_ODOO_SMTP_SSL True)" 'True|False'
  smtp_port=$(ql_env_get WOOW_ODOO_SMTP_PORT 587)
  ql_assert_match WOOW_ODOO_SMTP_PORT "$smtp_port" '[1-9][0-9]{0,4}'
  ((smtp_port <= 65535)) || ql_die 'SMTP port is not a TCP port'
  [[ -n $(ql_env_get WOOW_ODOO_SMTP_SERVER '') || -z $(ql_env_get WOOW_ODOO_SMTP_USER '') ]] \
    || ql_die 'SMTP user requires SMTP server'
  if [[ $gateway == True ]]; then
    [[ $bind == 127.0.0.1 ]] || ql_die 'gateway requires WOOW_ODOO_BIND=127.0.0.1 to prevent bypass of its rules'
    [[ $gateway_port != "$port" ]] || ql_die 'gateway and direct Odoo ports must differ'
  fi
  # A host path ("%h/..." or absolute): no ':' or ',' (Volume= separators), no whitespace, no '..'.
  addons=$(ql_env_get WOOW_ODOO_ADDONS_DIR)
  ql_assert_match WOOW_ODOO_ADDONS_DIR "$addons" '(%h|/)[A-Za-z0-9._/+-]*'
  [[ $addons != *..* ]] || ql_die "WOOW_ODOO_ADDONS_DIR: '..' is not allowed"
  ql_assert_match WOOW_ODOO_LIST_DB "$(ql_env_get WOOW_ODOO_LIST_DB)" 'True|False'
  db=$(ql_env_get WOOW_ODOO_DEFAULT_DB '')
  login=$(ql_env_get WOOW_ODOO_ADMIN_LOGIN '')
  lang=$(ql_env_get WOOW_ODOO_LANG zh_TW)
  ql_assert_match WOOW_ODOO_DEFAULT_DB "$db" '([a-z][a-z0-9_]{0,62})?'
  ql_assert_match WOOW_ODOO_ADMIN_LOGIN "$login" '([A-Za-z0-9_.+@-]{3,254})?'
  ql_assert_match WOOW_ODOO_LANG "$lang" '[a-z]{2}_[A-Z]{2}'
  ql_assert_match WOOW_ODOO_TENANT_CLOUD "$(ql_env_get WOOW_ODOO_TENANT_CLOUD False)" 'True|False'
  [[ -z $db || $db != postgres && $db != template0 && $db != template1 ]] \
    || ql_die "WOOW_ODOO_DEFAULT_DB: reserved PostgreSQL database name"
  [[ -z $db && -z $login || -n $db && -n $login ]] \
    || ql_die "WOOW_ODOO_DEFAULT_DB and WOOW_ODOO_ADMIN_LOGIN must be set together"
  if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]]; then
    [[ $db == odoo && -n $login ]] \
      || ql_die 'tenant cloud requires WOOW_ODOO_DEFAULT_DB=odoo and a real WOOW_ODOO_ADMIN_LOGIN'
    [[ $bind == 127.0.0.1 && $gateway == True ]] \
      || ql_die 'tenant cloud first run requires loopback Odoo and the gateway'
  fi
  db_user=odoo
  db_secret=odoo18-postgres-password
  db_volume=odoo18-db-data
  prestart=''
  if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]]; then
    db_user=postgres
    db_secret=odoo18-postgres-super-password
    db_volume=odoo18-db-data-isolated
  fi
  image=$(ql_env_get WOOW_ODOO_IMAGE '')
  [[ -n $image ]] || image=$(sed -n 's/^ODOO_IMAGE=//p' "$REPO/scripts/common.sh")
  # Explicit registry/repository and immutable digest. No whitespace, control characters, Quadlet
  # separators or shell expansion can enter a generated unit through this setting.
  ql_assert_match WOOW_ODOO_IMAGE "$image" '[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}'
  if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]]; then
    ql_assert_match REPO "$REPO" '/[A-Za-z0-9._/+-]+'
    unit_repo=$REPO
    [[ $REPO != "$HOME/"* ]] || unit_repo="%h/${REPO#"$HOME/"}"
    prestart="ExecStartPre=$unit_repo/scripts/upgrade-gate.sh --image $image"
  fi
  db_image=$(ql_env_get WOOW_ODOO_DB_IMAGE '')
  [[ -n $db_image ]] || db_image=$(sed -n 's/^DB_IMAGE=//p' "$REPO/scripts/common.sh")
  ql_assert_match WOOW_ODOO_DB_IMAGE "$db_image" '[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}'
  # "all" publishes on every address family (IPv4 and IPv6): omit the host IP.
  if [[ $bind == all ]]; then prefix=''; else prefix="$bind:"; fi
  [[ $gateway_bind == all ]] && gateway_bind=''
  [[ -z $gateway_bind ]] || gateway_bind+=:
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller.
  RENDER_ARGS=("ODOO_PUBLISH=$prefix$port" "ODOO_IMAGE=$image" "DB_IMAGE=$db_image"
    "DB_BOOTSTRAP_USER=$db_user" "DB_BOOTSTRAP_SECRET=$db_secret" "DB_VOLUME_NAME=$db_volume"
    "ODOO_PRESTART=$prestart"
    "ODOO_GATEWAY_PUBLISH=$gateway_bind$gateway_port")
}
