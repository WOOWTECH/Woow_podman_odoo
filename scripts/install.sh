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
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ------------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
app_lock

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
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
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
  odoo_check_image_account "$ODOO_IMAGE" odoo 100 101
fi
ql_secret_ensure odoo18-postgres-password random:44
ql_secret_ensure odoo18-admin-password random:44
restart_web=0
if [[ $dry == 1 ]] && ! podman secret exists odoo18-admin-password; then
  ql_info "[dry-run] would render odoo.conf into secret odoo18-odoo-conf"
else
  odoo_render_conf_secret
  [[ $QL_SECRET_CHANGED == 0 ]] || restart_web=1
fi

# ---- 7. install changed files; start the database, then Odoo -------------------------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if [[ $dry == 1 ]]; then
  ((restart_web)) && ql_info "[dry-run] would restart odoo.service (odoo.conf changed)"
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
((restart_web == 0)) || ql_mark_changed "$APP" odoo.service
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start odoo-db.service odoo.service"
  exit 0
fi
ql_apply_units "$APP" odoo-db.service
app_wait_healthy odoo18-db 180 odoo-db.service
ql_apply_units "$APP" odoo.service
app_wait_healthy odoo18-web 300 odoo.service
host=$(app_local_host "$(ql_env_get WOOW_ODOO_BIND)")
port=$(ql_env_get WOOW_ODOO_PORT)
ql_wait_http "http://$host:$port/web/health" '200' 120 || ql_die "Odoo does not answer on $host:$port"

# ---- 8. smoke ---------------------------------------------------------------------------------------
if ((no_smoke == 0)); then
  "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed; see the FAIL lines above"
fi
cat >&2 <<EOF
$APP is installed and healthy.
  Odoo             http://$host:$port/   (create the first database in the database manager)
  Master password  (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password
  Addons           $addons (read-only in the container; restart odoo.service after changes)
  Settings         $ENV_FILE (edit, then run scripts/install.sh again)
EOF
