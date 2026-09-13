# shellcheck shell=bash
# scripts/odoo-helpers.sh: Odoo-specific helpers, sourced after scripts/common.sh. Every function
# that handles a password keeps it in shell variables and pipes; none of them prints one.

# odoo_render_conf_secret: render config/odoo.conf.template with both passwords and WOOW_ODOO_LIST_DB
# and store the result as the odoo18-odoo-conf secret (replaced only when it differs). Sets
# QL_SECRET_CHANGED=1 when it changed, so the caller restarts odoo.service.
odoo_render_conf_secret() {
  local xt=0 db admin list ODOO_CONF
  [[ $- == *x* ]] && xt=1 && set +x
  db=$(app_secret_read odoo18-postgres-password || true)
  admin=$(app_secret_read odoo18-admin-password || true)
  list=$(ql_env_get WOOW_ODOO_LIST_DB True)
  if [[ -z $db || -z $admin ]]; then
    ((xt)) && set -x
    ql_die "secrets odoo18-postgres-password and odoo18-admin-password must exist before the conf is rendered"
  fi
  ODOO_CONF=$(ql_render "$REPO/config/odoo.conf.template" - "$REPO/config/odoo.conf.render-vars" - \
    "POSTGRES_PASSWORD=$db" "ODOO_ADMIN_PASSWORD=$admin" "WOOW_ODOO_LIST_DB=$list") || ODOO_CONF=''
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
  podman exec odoo18-db psql -X -U odoo -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1"
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
  local xt=0 pw rc=0
  [[ $- == *x* ]] && xt=1 && set +x
  pw=$(app_secret_read odoo18-postgres-password || true)
  if [[ ! $pw =~ ^[A-Za-z0-9+/=_.-]+$ ]]; then
    ((xt)) && set -x
    ql_die "secret odoo18-postgres-password is missing or has unexpected characters"
  fi
  printf "ALTER ROLE odoo PASSWORD '%s';\n" "$pw" \
    | podman exec -i odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U odoo -d postgres >/dev/null || rc=$?
  pw=''
  ((xt)) && set -x
  return "$rc"
}
