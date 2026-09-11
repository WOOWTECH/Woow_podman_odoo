# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/odoo18/odoo18.env. Sourced by
# scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is already loaded from <envfile>; sets RENDER_ARGS=(KEY=VALUE...).
# It also validates the values that are rendered straight from the env file, and dies on a bad one.
render_args() {
  local bind port addons prefix
  bind=$(ql_env_get WOOW_ODOO_BIND)
  ql_assert_match WOOW_ODOO_BIND "$bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'
  port=$(ql_env_get WOOW_ODOO_PORT)
  ql_assert_match WOOW_ODOO_PORT "$port" '[1-9][0-9]{0,4}'
  ((port <= 65535)) || ql_die "WOOW_ODOO_PORT: $port is not a TCP port"
  # A host path ("%h/..." or absolute): no ':' or ',' (Volume= separators), no whitespace, no '..'.
  addons=$(ql_env_get WOOW_ODOO_ADDONS_DIR)
  ql_assert_match WOOW_ODOO_ADDONS_DIR "$addons" '(%h|/)[A-Za-z0-9._/+-]*'
  [[ $addons != *..* ]] || ql_die "WOOW_ODOO_ADDONS_DIR: '..' is not allowed"
  ql_assert_match WOOW_ODOO_LIST_DB "$(ql_env_get WOOW_ODOO_LIST_DB)" 'True|False'
  # "all" publishes on every address family (IPv4 and IPv6): omit the host IP.
  if [[ $bind == all ]]; then prefix=''; else prefix="$bind:"; fi
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  RENDER_ARGS=("ODOO_PUBLISH=$prefix$port")
}
