#!/usr/bin/env bash
# tests/smoke.sh: post-install checks for Woow Odoo 18, run on the host where it is installed
# (install.sh, upgrade.sh and restore.sh call it too). It creates and drops one throwaway database for
# the pgvector check and otherwise only reads.
#
#   tests/smoke.sh [--quick]
#
#   --quick   units, health, published ports and HTTP only
#
# Secrets are read with `podman secret inspect --showsecret` into variables and compared in-process;
# nothing secret is printed, and the master password reaches curl through a 0600 file.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=../scripts/odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"
export QL_LOG_PREFIX=smoke

quick=0
while (($#)); do
  case $1 in
    --quick) quick=1 ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done

npass=0 nfail=0 nwarn=0
pass() { printf 'PASS %s\n' "$*"; npass=$((npass + 1)); }
fail() { printf 'FAIL %s\n' "$*"; nfail=$((nfail + 1)); }
warn() { printf 'WARN %s\n' "$*"; nwarn=$((nwarn + 1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/odoo-smoke.XXXXXX")
chmod 700 "$TMP"
probe_db=''
cleanup() {
  [[ -z $probe_db ]] || podman exec odoo18-db dropdb -U odoo --if-exists "$probe_db" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE not found; is Odoo installed?"
app_env_load
bind=$(ql_env_get WOOW_ODOO_BIND)
port=$(ql_env_get WOOW_ODOO_PORT)
host=$(app_local_host "$bind")
url=http://$host:$port

# A1 units
for u in odoo-db.service odoo.service; do
  if systemctl --user is-active --quiet "$u"; then pass "A1 $u is active"; else fail "A1 $u is not active"; fi
done

# A2 health (native podman health checks; there is no custom health timer any more)
for c in odoo18-db odoo18-web; do
  if ql_wait_container_healthy "$c" 300 2>/dev/null; then pass "A2 $c is healthy"; else fail "A2 $c is not healthy"; fi
done

# A3 Odoo publishes exactly the configured address; the database publishes nothing
want="8069/tcp -> $bind:$port"
[[ $bind == all ]] && want="8069/tcp -> 0.0.0.0:$port"
got=$(podman port odoo18-web 2>/dev/null || true)
if [[ $got == "$want" ]]; then pass "A3 odoo18-web publishes only $want"; else fail "A3 odoo18-web publishes '${got//$'\n'/, }', want '$want'"; fi
got=$(podman port odoo18-db 2>/dev/null || true)
if [[ -z $got ]]; then pass "A3 odoo18-db publishes no port"; else fail "A3 odoo18-db publishes '$got'"; fi

# A4 HTTP
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url/web/health" || true)
if [[ $code == 200 ]]; then pass "A4 /web/health returns 200"; else fail "A4 /web/health returned $code"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$url/" || true)
if [[ $code =~ ^(200|30[1237])$ ]]; then pass "A4 / returns $code"; else fail "A4 / returned $code"; fi

if ((quick)); then
  printf '%s passed, %s failed, %s warnings (quick)\n' "$npass" "$nfail" "$nwarn"
  ((nfail == 0))
  exit
fi

db_pw=$(app_secret_read odoo18-postgres-password || true)
admin_pw=$(app_secret_read odoo18-admin-password || true)
[[ -n $db_pw && -n $admin_pw ]] || fail "A5 secrets odoo18-postgres-password / odoo18-admin-password are missing"

# A5 secret hygiene: inspect, process arguments, journal, container logs, tracked files
leaks=()
contains() { [[ -n $db_pw && $1 == *"$db_pw"* ]] || [[ -n $admin_pw && $1 == *"$admin_pw"* ]]; }
contains "$(podman inspect odoo18-db odoo18-web 2>/dev/null || true)" && leaks+=("podman inspect")
contains "$(podman top odoo18-db args 2>/dev/null; podman top odoo18-web args 2>/dev/null)" && leaks+=("process arguments")
contains "$(journalctl --user -u odoo.service -u odoo-db.service -o cat --no-pager 2>/dev/null || true)" && leaks+=("journal")
contains "$(podman logs --tail 2000 odoo18-db 2>&1; podman logs --tail 2000 odoo18-web 2>&1)" && leaks+=("container logs")
while IFS= read -r -d '' f; do
  [[ -f $REPO/$f ]] || continue
  if contains "$(<"$REPO/$f")"; then leaks+=("tracked file $f"); fi
done < <(git -C "$REPO" ls-files -z 2>/dev/null || true)
if ((${#leaks[@]} == 0)); then pass "A5 no password in inspect, argv, journal, logs or tracked files"; else fail "A5 a password appears in: ${leaks[*]}"; fi

# A6 the conf secret is private to Odoo; the database was initialised through POSTGRES_PASSWORD_FILE
perm=$(podman exec odoo18-web stat -c '%a %U' /etc/odoo/odoo.conf 2>/dev/null || true)
if [[ $perm == '400 odoo' ]]; then pass "A6 /etc/odoo/odoo.conf is 0400 odoo"; else fail "A6 /etc/odoo/odoo.conf is '${perm:-missing}', want '400 odoo'"; fi
if [[ $(podman exec odoo18-db psql -X -U odoo -d postgres -Atqc 'SELECT 1' 2>/dev/null) == 1 ]]; then
  pass "A6 PostgreSQL answers as role odoo"
else
  fail "A6 PostgreSQL does not answer"
fi

# A7 the generated master password works, the old default "admin" does not. Uses the database
# service's "drop" on a name that does not exist: the password is checked, nothing is dropped.
if [[ $(ql_env_get WOOW_ODOO_LIST_DB True) != True ]]; then
  warn "A7 skipped: WOOW_ODOO_LIST_DB=False blocks the database service"
elif [[ -n $admin_pw ]]; then
  absent=woow_smoke_absent_$$_$RANDOM
  rpc() { # rpc <master password> -> response body
    local body=$TMP/rpc.json pw=${1//\\/\\\\}
    pw=${pw//\"/\\\"}
    (umask 077 && printf '{"jsonrpc":"2.0","method":"call","id":1,"params":{"service":"db","method":"drop","args":["%s","%s"]}}' \
      "$pw" "$absent" >"$body")
    curl -s -m 20 -H 'Content-Type: application/json' --data @"$body" "$url/jsonrpc" || true
    rm -f "$body"
  }
  out=$(rpc "$admin_pw")
  if [[ $out == *'"result": false'* || $out == *'"result":false'* ]]; then pass "A7 the generated master password is accepted"; else fail "A7 the generated master password was not accepted"; fi
  out=$(rpc admin)
  if [[ $out == *AccessDenied* || $out == *'Access Denied'* ]]; then pass "A7 master password 'admin' is rejected"; else fail "A7 master password 'admin' was not rejected"; fi
fi
unset db_pw admin_pw

# A8 pgvector is available at the pinned version (throwaway database, dropped again)
want_vec=${DB_IMAGE#*pgvector:}
want_vec=${want_vec%%-*}
probe_db=woow_smoke_vector_$$
if podman exec odoo18-db createdb -U odoo "$probe_db" >/dev/null 2>&1 \
  && got=$(podman exec odoo18-db psql -X -U odoo -d "$probe_db" -v ON_ERROR_STOP=1 -Atqc \
    "CREATE EXTENSION vector; SELECT extversion FROM pg_extension WHERE extname = 'vector'" 2>/dev/null) \
  && [[ $got == "$want_vec" ]]; then
  pass "A8 pgvector $want_vec works"
else
  fail "A8 pgvector: expected $want_vec, got '${got:-error}'"
fi
podman exec odoo18-db dropdb -U odoo --if-exists "$probe_db" >/dev/null 2>&1 && probe_db=''

# A9 addons are mounted read-only and the host directory keeps its owner
rw=$(podman inspect --format '{{range .Mounts}}{{if eq .Destination "/mnt/extra-addons"}}{{.RW}}{{end}}{{end}}' odoo18-web 2>/dev/null || true)
if [[ $rw == false ]]; then pass "A9 /mnt/extra-addons is mounted read-only"; else fail "A9 /mnt/extra-addons mount RW=${rw:-missing}"; fi
addons=$(ql_expand_home "$(ql_env_get WOOW_ODOO_ADDONS_DIR)")
owner=$(stat -c %U "$addons" 2>/dev/null || true)
if [[ $owner == "$(id -un)" ]]; then pass "A9 $addons is still owned by $owner"; else fail "A9 $addons is owned by '${owner:-?}', not $(id -un)"; fi

printf '%s passed, %s failed, %s warnings\n' "$npass" "$nfail" "$nwarn"
((nfail == 0))
