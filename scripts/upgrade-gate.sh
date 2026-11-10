#!/usr/bin/env bash
# Tenant cloud image gate. Called before the web service starts for every image change.
# Adopt an existing verified database once with --adopt-current; fresh bootstrap uses --adopt-fresh.
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$REPO/scripts/lib/quadlet-lib.sh"
. "$REPO/scripts/common.sh"
gate_die() { local code=$1; shift; printf '%s: ERROR: %s\n' "${0##*/}" "$*" >&2; exit "$code"; }
mode=gate image='' db=odoo
while (($#)); do
  case $1 in
    --image) (($# >= 2)) || ql_die '--image needs a value'; image=$2; shift ;;
    --database) (($# >= 2)) || ql_die '--database needs a value'; db=$2; shift ;;
    --adopt-current) mode=adopt-current ;;
    --adopt-fresh) mode=adopt-fresh ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1" ;;
  esac
  shift
done
[[ -n $image ]] || ql_die '--image is required'
[[ $db =~ ^odoo(__restore_[a-z0-9_-]{1,21})?$ ]] || ql_die 'unsafe gate database name'
ql_require_rootless
app_env_load
[[ $(ql_env_get WOOW_ODOO_TENANT_CLOUD False) == True ]] || ql_die 'upgrade gate requires tenant cloud profile'
digest=sha256:$(podman image inspect --format '{{.Id}}' "$image")
[[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || ql_die 'target image has no immutable ID'
raw=$(podman run --rm --network=none --entrypoint dpkg-query "$image" -W -f='${Version}' odoo)
core=${raw#*:}; core=${core%%[-+~]*}; core=$(cut -d. -f1-3 <<<"$core")
[[ $core =~ ^18\.0\.[0-9]{8}$ ]] || ql_die 'target image Odoo core date is unavailable'
done_key=woow_paas_platform.upgrade_done
attempt_key=woow_paas_platform.upgrade_attempt
marker_get() { podman exec odoo18-db psql -X -U odoo -d "$db" -Atqc \
  "SELECT value FROM ir_config_parameter WHERE key='$1'"; }
marker_set() { podman exec -i odoo18-db psql -X -q -v ON_ERROR_STOP=1 -U odoo -d "$db" \
  -v marker="$1" -v value="$2" >/dev/null <<'SQL'
INSERT INTO ir_config_parameter(key,value) VALUES(:'marker',:'value')
ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value;
SQL
}
marker_json() { python3 - "$digest" "$core" "${1:-}" <<'PY'
import json,sys
d={'digest':sys.argv[1],'core_date':sys.argv[2]}
if sys.argv[3]: d['count']=int(sys.argv[3])
print(json.dumps(d,separators=(',',':')))
PY
}
marker_fields() { python3 - "$1" <<'PY'
import json,sys
try: obj=json.loads(sys.argv[1]) if sys.argv[1] else {}
except ValueError: raise SystemExit('corrupt upgrade marker JSON')
for key in ('digest','core_date','count'): print(obj.get(key,''))
PY
}
verify() {
  local stage=$1 addons
  addons=$(ql_expand_home "$(ql_env_get WOOW_ODOO_ADDONS_DIR)")
  podman run --rm --network odoo18-network \
    --volume odoo18-web-data:/var/lib/odoo:ro \
    --volume "$addons":/mnt/extra-addons:ro,Z \
    --volume "$REPO/scripts/verify-modules.py":/tmp/verify-modules.py:ro,Z \
    --secret odoo18-odoo-conf,type=mount,target=/etc/odoo/odoo.conf,uid=100,gid=101,mode=0400 \
    --entrypoint python3 "$image" /tmp/verify-modules.py --database "$db" --mode "$stage"
}
run_upgrade() {
  local modules=$1 addons
  addons=$(ql_expand_home "$(ql_env_get WOOW_ODOO_ADDONS_DIR)")
  timeout -k 60 1200 podman run --rm --name odoo18-upgrade-gate --network odoo18-network \
    --volume odoo18-web-data:/var/lib/odoo \
    --volume "$addons":/mnt/extra-addons:ro,Z \
    --secret odoo18-odoo-conf,type=mount,target=/etc/odoo/odoo.conf,uid=100,gid=101,mode=0400 \
    --entrypoint odoo "$image" -c /etc/odoo/odoo.conf -d "$db" -u "$modules" \
    --stop-after-init --no-http --log-level=info
}
[[ $(podman exec odoo18-db psql -X -U odoo -d "$db" -Atqc \
  "SELECT to_regclass('public.ir_module_module') IS NOT NULL") == t ]] \
  || gate_die 1 'tenant database is not initialized'
done_json=$(marker_get "$done_key")
attempt_json=$(marker_get "$attempt_key")
mapfile -t done_fields < <(marker_fields "$done_json") || ql_die 'invalid done marker'
mapfile -t attempt_fields < <(marker_fields "$attempt_json") || ql_die 'invalid attempt marker'
[[ ${#done_fields[@]} == 3 && ${#attempt_fields[@]} == 3 ]] || gate_die 2 'upgrade marker JSON is invalid'
done_digest=${done_fields[0]}; done_core=${done_fields[1]}
attempt_digest=${attempt_fields[0]}; attempt_core=${attempt_fields[1]}
attempt_count=${attempt_fields[2]}
[[ -z $done_digest || $done_digest =~ ^sha256:[a-f0-9]{64}$ ]] || ql_die 'invalid done digest'
[[ -z $attempt_digest || $attempt_digest =~ ^sha256:[a-f0-9]{64}$ ]] || ql_die 'invalid attempt digest'
[[ -z $done_core || $done_core =~ ^18\.0\.[0-9]{8}$ ]] || ql_die 'invalid done core date'
[[ -z $attempt_core || $attempt_core =~ ^18\.0\.[0-9]{8}$ ]] || ql_die 'invalid attempt core date'
[[ -z $attempt_count || $attempt_count =~ ^[0-9]+$ ]] || ql_die 'invalid attempt count'

if [[ $mode == adopt-current || $mode == adopt-fresh ]]; then
  [[ -z $done_digest ]] || ql_die 'upgrade marker already exists; adoption is one-time'
  if [[ $mode == adopt-current ]]; then
    [[ sha256:$(podman inspect --format '{{.Image}}' odoo18-web 2>/dev/null) == "$digest" ]] \
      || ql_die 'running Odoo image does not match adoption target'
  fi
  verify post || ql_die 'module verification failed; refusing to adopt database'
  marker_set "$done_key" "$(marker_json)"
  ql_info "adopted verified tenant database for $digest ($core)"
  exit 0
fi

if [[ $done_digest == "$digest" ]]; then
  ql_info "upgrade gate: target $digest already completed"
  exit 0
fi
[[ -n $done_digest ]] || gate_die 3 'adopted database has no upgrade marker; run upgrade-gate.sh --adopt-current after verification'
db_core=$done_core
[[ -z $attempt_core || $attempt_core < $db_core ]] || db_core=$attempt_core
[[ $db_core > $core ]] && gate_die 78 "upgrade gate refused older Odoo core ($core < $db_core)"
[[ $attempt_digest != "$digest" || ${attempt_count:-0} -lt 3 ]] \
  || gate_die 78 'upgrade gate attempt limit reached (3); inspect migration before resetting marker'
source_rc=0
verify sources || source_rc=$?
case $source_rc in
  0) ;;
  4) gate_die 4 'target image is missing installed module sources or has older module versions' ;;
  *) gate_die 2 "module source check failed internally (exit $source_rc)" ;;
esac
count=1
[[ $attempt_digest != "$digest" ]] || count=$((attempt_count+1))
marker_set "$attempt_key" "$(marker_json "$count")"
log_dir=$(app_new_backup_dir upgrade-gate)
if ! run_upgrade all >"$log_dir/upgrade.log" 2>&1; then
  podman rm -f odoo18-upgrade-gate >/dev/null 2>&1 || true
  ql_warn "module upgrade failed on attempt $count/3; log: $log_dir/upgrade.log"
  if ((count >= 3)); then exit 78; else exit 6; fi
fi
verify_rc=0
verify post >"$log_dir/verify.json" 2>"$log_dir/verify.err" || verify_rc=$?
if ((verify_rc != 0 && verify_rc != 7)); then
  ql_warn "post-upgrade verification failed internally (exit $verify_rc); logs: $log_dir"
  if ((count >= 3)); then exit 78; else exit 2; fi
fi
if ((verify_rc == 7)); then
  affected=$(python3 - "$log_dir/verify.json" <<'PY'
import json,sys
try: x=json.load(open(sys.argv[1])); print(','.join(sorted(set(x.get('mismatch',[])+x.get('pending',[])))))
except (ValueError,OSError): print('')
PY
)
  if [[ -z $affected ]] || ! run_upgrade "$affected" >"$log_dir/repair.log" 2>&1 \
    || ! verify post >"$log_dir/verify-after-repair.json" 2>"$log_dir/verify-after-repair.err"; then
    ql_warn "post-upgrade verification failed on attempt $count/3; logs: $log_dir"
    if ((count >= 3)); then exit 78; else exit 7; fi
  fi
fi
marker_set "$done_key" "$(marker_json)"
ql_info "upgrade gate released $digest ($core) on attempt $count/3"
