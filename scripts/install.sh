#!/usr/bin/env bash
# scripts/install.sh: install or update Woow Odoo 18 (Odoo + PostgreSQL/pgvector) as rootless Quadlet
# units (podman >= 4.9, systemd --user, linger). Idempotent: a re-run with nothing changed restarts
# nothing and keeps every password.
#
#   scripts/install.sh [options]
#
#   --set KEY=VALUE     store a per-host setting in ~/.config/odoo18/odoo18.env first (repeatable),
#                       e.g. --set WOOW_ODOO_PORT=28069. Only keys of config/odoo18.env.example.
#   --fix-addon-perms   make the addons dir world-readable (chmod -R o+rX) instead of stopping
#   --accept-defaults   on the first run, continue with the example settings instead of stopping
#   --no-start          install the files and daemon-reload only
#   --no-smoke          skip tests/smoke.sh at the end
#   --dry-run           render and validate, report what would change, touch nothing
#
# Order: preflight -> env -> guards -> addons dir -> render -> dry-run -> pull -> image-account probe
# -> secrets and odoo.conf secret -> install -> start the database -> start Odoo -> smoke.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"

sets=() fix_perms=0 accept=0 no_start=0 no_smoke=0
while (($#)); do
  case $1 in
    --set) (($# >= 2)) || ql_die "--set needs KEY=VALUE"; sets+=("$2"); shift ;;
    --set=*) sets+=("${1#--set=}") ;;
    --fix-addon-perms) fix_perms=1 ;;
    --accept-defaults) accept=1 ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ------------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
ql_lock "$APP"
# ---- 2. per-host settings ---------------------------------------------------------------------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 && $accept == 0 && ${#sets[@]} == 0 ]]; then
  ql_info "review $ENV_FILE, then run $0 again (or pass --accept-defaults)"
  exit 0
fi
((${#sets[@]} == 0)) || app_apply_sets "${sets[@]}"
app_env_load
app_env_overlay "${sets[@]}"
app_refuse_env_secrets
default_odoo_image=$ODOO_IMAGE
ODOO_IMAGE=$(ql_env_get WOOW_ODOO_IMAGE '')
[[ -n $ODOO_IMAGE ]] || ODOO_IMAGE=$default_odoo_image
default_db_image=$DB_IMAGE
DB_IMAGE=$(ql_env_get WOOW_ODOO_DB_IMAGE '')
[[ -n $DB_IMAGE ]] || DB_IMAGE=$default_db_image
gateway_enabled=$(ql_env_get WOOW_ODOO_GATEWAY_ENABLED False)

# ---- 3. legacy guards -------------------------------------------------------------------------
# The compose-era variant ran as odoo18.service plus odoo18-health.timer (hand-written user units).
for u in odoo18.service odoo18-health.timer; do
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then
    ql_die "the compose-era unit $u is active. Migrate first (README: Migrating an existing compose deployment)"
  fi
done
app_guard_containers

# ---- 4. addons dir (read-only for Odoo; the operator keeps owning it) --------------------------
addons=$(ql_expand_home "$(ql_env_get WOOW_ODOO_ADDONS_DIR)")
if [[ ! -d $addons ]]; then
  if [[ $dry == 1 ]]; then ql_info "[dry-run] would create $addons"; else mkdir -p -- "$addons" && chmod 0755 -- "$addons" && ql_info "created $addons"; fi
fi
[[ ! -d $addons ]] || odoo_addons_check "$addons" "$fix_perms"

# ---- 5. stage, render, validate -----------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
ql_cleanup work rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
if [[ $gateway_enabled == True ]]; then
  cp -p "$REPO"/quadlet/optional/odoo-gateway.container "$WORK/src/"
fi
RENDER_ARGS=()
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"
render_args "$RENDER_ENV"
ql_render "$WORK/src" "$RENDER_ENV" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered units failed the Quadlet dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# ---- 6. images, image accounts, secrets -------------------------------------------------------------
ql_pull_images "$WORK/out"
if [[ $dry == 0 ]]; then
  odoo_check_image_account "$DB_IMAGE" postgres 999 999
  odoo_check_db_volume_major "$DB_IMAGE"
  odoo_check_image_account "$ODOO_IMAGE" odoo 100 101
  if [[ $gateway_enabled == True ]]; then
    odoo_check_image_account "$REPO_GATEWAY_IMAGE" nginx 101 101
  fi
fi
ql_secret_ensure odoo18-postgres-password random:44
ql_secret_ensure odoo18-admin-password random:44
restart_web=0
restart_gateway=0
if [[ $dry == 1 ]] && ! podman secret exists odoo18-admin-password; then
  ql_info "[dry-run] would render odoo.conf into secret odoo18-odoo-conf"
else
  odoo_render_conf_secret
  [[ $QL_SECRET_CHANGED == 0 ]] || restart_web=1
fi
if [[ $gateway_enabled == True ]]; then
  odoo_render_gateway_conf_secret
  [[ $QL_SECRET_CHANGED == 0 ]] || restart_gateway=1
fi

# ---- 7. install changed files; start the database, then Odoo -------------------------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if [[ $dry == 1 ]]; then
  ((restart_web)) && ql_info "[dry-run] would restart odoo.service (odoo.conf changed)"
  ((restart_gateway)) && ql_info "[dry-run] would restart odoo-gateway.service (gateway conf changed)"
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
((restart_web == 0)) || ql_mark_changed "$APP" odoo.service
((restart_gateway == 0)) || ql_mark_changed "$APP" odoo-gateway.service
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start odoo-db.service odoo.service"
  exit 0
fi
systemctl --user daemon-reload
odoo_reconcile_resources
ql_apply_units "$APP" odoo-db.service
app_wait_healthy odoo18-db 180 odoo-db.service
odoo_check_db_password || ql_die "the database role odoo does not accept the password in the
odoo18-postgres-password secret. The volume odoo18-db-data already held a cluster, and
POSTGRES_PASSWORD_FILE only applies to an empty volume, so the role still uses whatever password it
was created with -- possibly the one this repository published before 2026-09. Point the role at the
recorded secret with: scripts/rotate-secrets.sh --db"
ql_apply_units "$APP" odoo.service
app_wait_healthy odoo18-web 300 odoo.service
if [[ $gateway_enabled == True ]]; then
  ql_apply_units "$APP" odoo-gateway.service
  app_wait_healthy odoo18-gateway 180 odoo-gateway.service
  gateway_host=$(app_local_host "$(ql_env_get WOOW_ODOO_GATEWAY_BIND 127.0.0.1)")
  gateway_port=$(ql_env_get WOOW_ODOO_GATEWAY_PORT 18080)
  ql_wait_http "http://$gateway_host:$gateway_port/nginx-health" '200' 30 \
    || ql_die "Odoo gateway does not answer on $gateway_host:$gateway_port"
fi
host=$(app_local_host "$(ql_env_get WOOW_ODOO_BIND)")
port=$(ql_env_get WOOW_ODOO_PORT)
ql_wait_http "http://$host:$port/web/health" '200' 120 || ql_die "Odoo does not answer on $host:$port"

# Optional first-run bootstrap. Never re-run -i base on an existing database: it can reset
# noupdate records such as the first administrator. A partial database fails loudly.
default_db=$(ql_env_get WOOW_ODOO_DEFAULT_DB '')
if [[ -n $default_db ]]; then
  dbs=$(odoo_databases) || ql_die "cannot list Odoo databases before bootstrap"
  if grep -qxF "$default_db" <<<"$dbs"; then
    installed=$(podman exec odoo18-db psql -X -U odoo -d "$default_db" -Atc \
      "SELECT string_agg(name || ':' || state, ',' ORDER BY name) FROM ir_module_module WHERE name IN ('base','web')" 2>/dev/null) \
      || ql_die "$default_db exists but its module state cannot be read; refusing to initialize it again"
    [[ $installed == 'base:installed,web:installed' ]] \
      || ql_die "$default_db exists but base/web are not fully installed ($installed); manual recovery is required"
    ql_info "database $default_db already initialized (kept)"
  else
    [[ $(ql_env_get WOOW_ODOO_BIND) == 127.0.0.1 ]] \
      || ql_die "first-run database bootstrap requires loopback binding; change WOOW_ODOO_BIND after initialization"
    [[ $(ql_env_get WOOW_ODOO_LIST_DB) == True ]] \
      || ql_die "first-run database bootstrap requires WOOW_ODOO_LIST_DB=True"
    "$REPO/scripts/init-db.py" --database "$default_db" \
      --admin-login "$(ql_env_get WOOW_ODOO_ADMIN_LOGIN)" \
      --lang "$(ql_env_get WOOW_ODOO_LANG zh_TW)" --url "http://127.0.0.1:$port" \
      || ql_die "database bootstrap failed; inspect the database before retrying"
  fi
fi

# PaaS tenant cloud serves exactly one database. Create/verify it while the Odoo database
# service is temporarily enabled on loopback, then hide the manager and pin the database.
if [[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]]; then
  odoo_ensure_tenant_database "$default_db"
  if [[ $(ql_env_get WOOW_ODOO_LIST_DB) != False || $(ql_env_get WOOW_ODOO_DB_FILTER '') != '^odoo$' ]]; then
    ql_env_set "$ENV_FILE" WOOW_ODOO_LIST_DB False
    ql_env_set "$ENV_FILE" WOOW_ODOO_DB_FILTER '^odoo$'
    odoo_render_conf_secret
    systemctl --user restart odoo.service
    app_wait_healthy odoo18-web 300 odoo.service
    ql_wait_http "http://$host:$port/web/health" '200' 120 \
      || ql_die 'Odoo health failed after tenant database lock-down'
    ql_info "tenant database manager disabled; dbfilter pinned to ^odoo$"
  fi
fi

# ---- 8. smoke ---------------------------------------------------------------------------------------
if ((no_smoke == 0)); then
  "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed; see the FAIL lines above"
fi
entry_url="http://$host:$port/"
entry_note='create the first database in the database manager'
if [[ $gateway_enabled == True ]]; then
  entry_url="http://$gateway_host:$gateway_port/"
  entry_note='gateway; create a database with scripts/init-db.py (database manager is blocked here)'
fi
if [[ -n $default_db ]]; then
  entry_note="database $default_db initialized; sign in with $(ql_env_get WOOW_ODOO_ADMIN_LOGIN)"
fi
cat >&2 <<EOF
$APP is installed and healthy.
  Odoo             $entry_url   ($entry_note)
  Master password  (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password
  Addons           $addons (read-only in the container; restart odoo.service after changes)
  Settings         $ENV_FILE (edit, then run scripts/install.sh again)
EOF
