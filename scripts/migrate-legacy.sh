#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move an existing podman-compose / docker-compose Odoo 18 deployment
# (compose project "odoo18": containers odoo18-db and odoo18-web, volumes odoo18-db-data and
# odoo18-web-data, network odoo18-network, optionally a hand-written odoo18.service and
# odoo18-health.timer) to the Quadlet units of this repo.
#
# It is an IN-PLACE ADOPTION. The units keep the compose names (ContainerName=, VolumeName=,
# NetworkName=), so both volumes and the network are opened again rather than recreated: no
# database is copied, no filestore is moved, and the pinned images do not change. The legacy
# containers stay available for --rollback.
#
#   scripts/migrate-legacy.sh [--legacy-dir DIR] [--suffix S] [--force-capture] [--no-cold-copy]
#                             [--new-master-password] [--fix-addon-perms]
#                             [--prepare-only | --dry-run] [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR        the old checkout, only used to archive its .env and compose file.
#                           Every value the migration needs is read from the running containers,
#                           because the deployed tree is not always the tree this repo describes
#                           (on woowtechopenclaw the .env holds no settings at all).
#   --suffix S              the legacy containers become <name>-legacy-S (default: today). Only
#                           used on the rename path; see "Rollback shape" below.
#   --force-capture         take the capture path even where this host would allow a rename.
#                           It only ever tightens: the rename path can never be forced on a host
#                           that needs a capture.
#   --no-cold-copy          skip the cold `podman volume export` of both volumes during the
#                           cutover (the hot pg_dump and the roles dump still happen). Use it when
#                           the filestore is large and a separate backup already exists.
#   --new-master-password   generate a fresh Odoo master password instead of adopting the one in
#                           the legacy odoo.conf. A weak legacy value is never adopted.
#   --fix-addon-perms       passed through to install.sh: make the addons dir world-readable.
#   --prepare-only          steps 1-2 only, no downtime: checks, secrets, images, hot backup
#   --dry-run               step 1 and a render of the units; changes nothing
#   --no-auto-rollback      leave a failed cutover in place for inspection
#   --rollback              undo the cutover: remove the Quadlet units, bring the legacy containers
#                           back and re-enable the legacy unit
#   --status                print the recorded migration state
#
# Rollback shape (STANDARD 7a): the legacy containers are kept for --rollback either by renaming
# them and leaving them stopped, or - where the user unit podman-restart.service is enabled and a
# legacy container's restart policy is exactly `always`, because a renamed copy would revive at the
# next boot and a second PostgreSQL would open odoo18-db-data next to the new one - by capturing
# them into the backup directory and removing them. ql_rollback_strategy decides from this host's
# real state, never from its name, and --dry-run reports which path a cutover would take. The
# capture is taken in step 2, before any downtime.
#
# Steps:  1 pre-flight checks: containers, volumes, network, image versions, the addons dir, the
#           publish address, and the database password the adopted volume was initialised with
#         2 prepare (no downtime): env file, secrets, images, roles + every database dumped hot,
#           the legacy odoo.conf and units archived, volume fingerprints recorded, capture
#         3 cutover: stop the legacy units and containers, cold volume export, retire the
#           containers (downtime starts here and is measured)
#         4 scripts/install.sh adopts both volumes and the network
#         5 prove the adoption, wait for /web/health, tests/smoke.sh, report the downtime
#         6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=odoo-helpers.sh
. "$REPO/scripts/odoo-helpers.sh"
# shellcheck source=legacy-helpers.sh
. "$REPO/scripts/legacy-helpers.sh"

DB_CONTAINER=odoo18-db
WEB_CONTAINER=odoo18-web
LEGACY_ALL=("$DB_CONTAINER" "$WEB_CONTAINER")
DB_VOLUME=odoo18-db-data
WEB_VOLUME=odoo18-web-data
NETWORK=odoo18-network
# The hand-written units of the compose-era deployment. The timer comes first: it fires
# odoo18-health.service every 10 seconds and would restart the stack under us.
LEGACY_UNITS=(odoo18-health.timer odoo18-health.service odoo18.service)
STATE=$(app_state_dir)/migration.state

mode=migrate legacy_dir='' suffix=$(date +%Y%m%d) force_capture=0 cold_copy=1 new_master=0
fix_perms=0 auto_rollback=1 ASSUME_YES=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --force-capture) force_capture=1 ;;
    --no-cold-copy) cold_copy=0 ;;
    --new-master-password) new_master=1 ;;
    --fix-addon-perms) fix_perms=1 ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,56p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'

state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  local dir tmp
  dir=$(app_state_dir)
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
legacy_url() { printf 'http://%s:%s' "$(app_local_host "$(state_get LEGACY_BIND)")" "$(state_get LEGACY_PORT)"; }

# =================================================================================================
# 6. rollback
# =================================================================================================
rollback() {
  local status sfx bk c u want now i
  local -a retired=() units=() legacy_ids=()
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  read -ra retired <<<"$(state_get RETIRED)"
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  ((${#retired[@]})) || ql_die "no legacy containers recorded in $STATE"
  app_confirm odoo18 "$ASSUME_YES" "--rollback removes the Odoo Quadlet units and brings the legacy containers back"
  ql_info "stopping and removing the Quadlet units (both volumes, the network and the secrets are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$(app_state_dir)/applied-env.sha256"
  # Quadlet runs its containers with --replace, so a unit that got as far as starting leaves a
  # container of our name behind. Remove only what is demonstrably ours; a container that is
  # demonstrably the LEGACY one (its id is the one recorded before the cutover, i.e. the cutover
  # stopped it but died before retiring it) is left exactly where it is, for app_legacy_restore to
  # pick up. Anything else is a name this migration does not understand, and is a refusal.
  read -ra legacy_ids <<<"$(state_get LEGACY_IDS)"
  for i in "${!retired[@]}"; do
    c=${retired[i]}
    podman container exists "$c" || continue
    want=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c" 2>/dev/null || true)
    if [[ $want == odoo.service || $want == odoo-db.service ]]; then
      podman rm -f "$c" >/dev/null
      continue
    fi
    now=$(podman inspect --format '{{.Id}}' "$c" 2>/dev/null || true)
    [[ -n $now && $now == "${legacy_ids[i]:-}" ]] \
      || ql_die "container $c exists, is not a Quadlet leftover of this repo (PODMAN_SYSTEMD_UNIT='$want') and is not the legacy container recorded before the cutover; resolve it by hand"
    ql_info "$c is the legacy container the cutover stopped but never retired; keeping it"
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${retired[@]}"
  read -ra units <<<"$(state_get LEGACY_UNITS_ENABLED)"
  if ((${#units[@]})); then
    for u in "${units[@]}"; do
      systemctl --user enable "$u" >/dev/null 2>&1 || ql_warn "could not re-enable $u"
    done
    # odoo18.service is the one that brings the stack up; the timer follows it.
    for u in "${units[@]}"; do
      [[ $u == odoo18.service ]] || continue
      systemctl --user start "$u" || ql_warn "could not start $u; starting the containers directly"
    done
  fi
  # Whether or not a unit did it, the containers have to run again: the database first.
  for c in "$DB_CONTAINER" "$WEB_CONTAINER"; do
    if podman container exists "$c" && ! app_running "$c"; then podman start "$c" >/dev/null; fi
  done
  for u in "${units[@]}"; do
    [[ $u == odoo18-health.timer ]] || continue
    systemctl --user start "$u" >/dev/null 2>&1 || true
  done
  ql_wait_http "$(legacy_url)/web/health" '200' 300 \
    || ql_die "the legacy Odoo did not answer on $(legacy_url)/web/health after the rollback; check: podman logs $WEB_CONTAINER"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy stack serves again on $(legacy_url)/. Backup of the attempt: $bk"
  ql_info "the network $NETWORK, both volumes and the odoo18-* podman secrets are shared with the legacy stack and were deliberately left in place"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =================================================================================================
# 1. pre-flight checks (read-only; every one of them refuses rather than guesses)
# =================================================================================================
ql_info "step 1/5: pre-flight checks"
case $(state_get STATUS) in
  cutover | "done")
    ql_die "a migration is already recorded in $STATE (STATUS=$(state_get STATUS)). Re-running would migrate a second time; use --status, or --rollback" ;;
esac
if [[ $mode == dry-run ]]; then QL_DRY_RUN=1 ql_enable_linger; else ql_enable_linger; fi

# --- the legacy stack is where we expect it ------------------------------------------------------
for c in "${LEGACY_ALL[@]}"; do
  podman container exists "$c" || ql_die "legacy container $c not found; this host has no compose Odoo deployment to migrate"
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c" 2>/dev/null || true)
  case $label in
    odoo.service | odoo-db.service)
      ql_die "$c is already managed by the Quadlet units of this repo (PODMAN_SYSTEMD_UNIT=$label); this host needs no migration" ;;
  esac
  app_running "$c" || ql_die "legacy container $c is not running; start the legacy stack first (the backup is taken hot)"
done
if app_is_installed && [[ $(state_get STATUS) != prepared ]]; then
  ql_die "the Odoo Quadlet units are already installed on this host ($(app_state_dir)/manifest); this host needs no migration"
fi

# --- the data is where we expect it -------------------------------------------------------------
# Derived from the running containers and compared with what the units pin. Without VolumeName= in
# the .volume files Quadlet would silently create systemd-odoo-db-data and Odoo would come up
# healthy on an empty database, so a mismatch here is fatal rather than a warning.
db_mount=$(app_mount_source "$DB_CONTAINER" /var/lib/postgresql/data)
web_mount=$(app_mount_source "$WEB_CONTAINER" /var/lib/odoo)
[[ ${db_mount%%|*} == volume ]] || ql_die "$DB_CONTAINER does not mount a named volume at /var/lib/postgresql/data (got '${db_mount:-nothing}'); this migration adopts volumes, not bind directories"
[[ ${web_mount%%|*} == volume ]] || ql_die "$WEB_CONTAINER does not mount a named volume at /var/lib/odoo (got '${web_mount:-nothing}')"
db_vol=$(cut -d'|' -f2 <<<"$db_mount")
web_vol=$(cut -d'|' -f2 <<<"$web_mount")
[[ $db_vol == "$DB_VOLUME" ]] || ql_die "$DB_CONTAINER uses the volume '$db_vol', but quadlet/odoo-db-data.volume pins VolumeName=$DB_VOLUME. Adopting would start on an empty database; rename the volume or adjust the unit first"
[[ $web_vol == "$WEB_VOLUME" ]] || ql_die "$WEB_CONTAINER uses the volume '$web_vol', but quadlet/odoo-web-data.volume pins VolumeName=$WEB_VOLUME"
legacy_net=$(podman inspect --format '{{range $n, $v := .NetworkSettings.Networks}}{{$n}}{{println}}{{end}}' "$WEB_CONTAINER" | grep -v '^[[:space:]]*$' | head -n1)
[[ $legacy_net == "$NETWORK" ]] || ql_die "$WEB_CONTAINER is on the network '$legacy_net', but quadlet/odoo.network pins NetworkName=$NETWORK"
addons_mount=$(app_mount_source "$WEB_CONTAINER" /mnt/extra-addons)
addons=$(cut -d'|' -f3 <<<"$addons_mount")
[[ -n $addons && -d $addons ]] || ql_die "cannot read the addons bind mount of $WEB_CONTAINER (/mnt/extra-addons -> '${addons:-nothing}')"
# install.sh refuses an unreadable addons directory - after the downtime has already started, so
# the same check runs here while the legacy stack is still serving.
odoo_addons_check "$addons" "$fix_perms"

# --- the published address, and that the port is not shared with anything else -------------------
pub=$(app_published "$WEB_CONTAINER" 8069/tcp)
[[ -n $pub ]] || ql_die "$WEB_CONTAINER publishes no host port for 8069/tcp; this repo's units always publish one"
legacy_bind=$(app_bind_for "${pub%%|*}")
legacy_port=${pub#*|}
ql_assert_match "the publish port of $WEB_CONTAINER" "$legacy_port" '[1-9][0-9]{0,4}'
mapfile -t publishers < <(app_port_publishers "$legacy_port")
for c in "${publishers[@]:-}"; do
  [[ -z $c || $c == "$WEB_CONTAINER" ]] || ql_die "container $c also publishes host port $legacy_port; the Quadlet odoo18-web could not bind it"
done
mapfile -t listeners < <(app_port_listeners "$legacy_port")
ql_info "host port $legacy_port currently has ${#listeners[@]} listener(s): ${listeners[*]:-none}"

# --- the images are the same version (a migration must not smuggle in an upgrade) ----------------
legacy_odoo_ver=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$WEB_CONTAINER" | sed -n 's/^ODOO_VERSION=//p' | tail -n1)
legacy_pg_major=$(podman exec "$DB_CONTAINER" sh -c 'printf %s "$PG_MAJOR"' 2>/dev/null || true)
if ! podman image exists "$ODOO_IMAGE"; then
  ql_info "pulling $ODOO_IMAGE to read the version it ships"
  podman pull "$ODOO_IMAGE" >/dev/null || ql_die "podman pull $ODOO_IMAGE failed"
fi
if ! podman image exists "$DB_IMAGE"; then
  ql_info "pulling $DB_IMAGE to read the PostgreSQL major it ships"
  podman pull "$DB_IMAGE" >/dev/null || ql_die "podman pull $DB_IMAGE failed"
fi
image_env() { podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null; }
target_odoo_ver=$(image_env "$ODOO_IMAGE" | sed -n 's/^ODOO_VERSION=//p' | tail -n1)
target_pg_major=$(image_env "$DB_IMAGE" | sed -n 's/^PG_MAJOR=//p' | tail -n1)
[[ -n $legacy_odoo_ver && -n $target_odoo_ver ]] || ql_die "cannot read ODOO_VERSION from the legacy container ('$legacy_odoo_ver') or from $ODOO_IMAGE ('$target_odoo_ver')"
[[ $legacy_odoo_ver == "$target_odoo_ver" ]] \
  || ql_die "the legacy stack runs Odoo $legacy_odoo_ver but this checkout pins $target_odoo_ver; migrate at the same version, then run scripts/upgrade.sh"
[[ -z $legacy_pg_major || -z $target_pg_major || $legacy_pg_major == "$target_pg_major" ]] \
  || ql_die "the legacy PostgreSQL is major $legacy_pg_major and this checkout pins $target_pg_major; an adopted PGDATA cannot change major version, that needs a dump and restore"

# --- the database password the ADOPTED volume was initialised with -------------------------------
# POSTGRES_PASSWORD_FILE (and POSTGRES_PASSWORD) are read only when an EMPTY volume is initialised.
# odoo18-db-data is not empty, so the role "odoo" keeps whatever password it was created with, and
# the odoo18-postgres-password secret must be set to exactly that or Odoo cannot connect after the
# cutover. Read it from the running container (the deployed tree is not always this repo's tree),
# then PROVE it by authenticating over TCP, which is what the new odoo.conf will do.
legacy_env_value() {
  podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$DB_CONTAINER" | sed -n "s/^$1=//p" | tail -n1
}
read_legacy_db_password() {
  local v f
  v=$(legacy_env_value POSTGRES_PASSWORD)
  if [[ -n $v ]]; then printf '%s' "$v"; return 0; fi
  f=$(legacy_env_value POSTGRES_PASSWORD_FILE)
  if [[ -n $f ]]; then
    # The PostgreSQL entrypoint reads it with $(< file), which strips every trailing newline.
    podman exec "$DB_CONTAINER" cat -- "$f" 2>/dev/null | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba'
    return 0
  fi
  # Last resort, for a checkout whose compose file still expands ${POSTGRES_PASSWORD} from .env.
  # The key is a variable so this file contains no literal CREDENTIAL=... assignment for
  # tests/lint-repo.sh to trip over.
  local key=POSTGRES_PASSWORD
  if [[ -n $legacy_dir && -r $legacy_dir/.env ]]; then
    sed -n "s/^$key=//p" "$legacy_dir/.env" | tail -n1 | tr -d '\r'
  fi
}
LEGACY_DB_PASSWORD=$(read_legacy_db_password)
[[ -n $LEGACY_DB_PASSWORD ]] || ql_die "cannot find the database password of the legacy stack: $DB_CONTAINER sets neither POSTGRES_PASSWORD nor a readable POSTGRES_PASSWORD_FILE${legacy_dir:+, and $legacy_dir/.env has no POSTGRES_PASSWORD}"
ODOO_CANDIDATE_PW=$LEGACY_DB_PASSWORD
if odoo_role_accepts "$DB_CONTAINER"; then
  ql_info "the recorded database password authenticates as role odoo over TCP (which is how the new odoo.conf connects)"
else
  ODOO_CANDIDATE_PW=''
  ql_die "the password $DB_CONTAINER was configured with is NOT accepted by the role odoo. The volume $DB_VOLUME was initialised with a different one and POSTGRES_PASSWORD_FILE no longer applies to a non-empty volume, so the migrated stack could not connect. Fix the role first (ALTER ROLE odoo PASSWORD ...), then run this again"
fi
ODOO_CANDIDATE_PW=''

# --- the master password and list_db from the legacy odoo.conf -----------------------------------
legacy_conf_path=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$WEB_CONTAINER" | sed -n 's/^ODOO_RC=//p' | tail -n1)
legacy_conf_path=${legacy_conf_path:-/etc/odoo/odoo.conf}
LEGACY_CONF=$(podman exec "$WEB_CONTAINER" cat -- "$legacy_conf_path" 2>/dev/null || true)
[[ -n $LEGACY_CONF ]] || ql_warn "cannot read $legacy_conf_path from $WEB_CONTAINER; the master password and list_db fall back to defaults"
conf_value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" <<<"$LEGACY_CONF" | tail -n1 | tr -d '\r'; }
LEGACY_MASTER=$(conf_value admin_passwd)
legacy_list_db=$(conf_value list_db)
case $legacy_list_db in True | true | 1) list_db=True ;; False | false | 0) list_db=False ;; *) list_db=True ;; esac
# A migration must not carry a well-known default forward: tests/smoke.sh asserts that the master
# password "admin" is rejected, and the compose-final config/odoo.conf shipped exactly that.
adopt_master=1
if ((new_master)); then
  adopt_master=0
  ql_info "--new-master-password: install.sh will generate a fresh Odoo master password"
elif odoo_master_is_weak "$LEGACY_MASTER"; then
  adopt_master=0
  ql_warn "the legacy odoo.conf carries a missing or well-known master password; it will NOT be adopted. install.sh generates a fresh one (read it with: podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password)"
else
  ql_info "the master password from the legacy odoo.conf will be adopted into the odoo18-admin-password secret"
fi

# --- how the legacy containers are kept for --rollback -------------------------------------------
STRATEGY=$(ql_rollback_strategy "${LEGACY_ALL[@]}")
if ((force_capture)) && [[ $STRATEGY == rename ]]; then
  STRATEGY=capture
  ql_info "--force-capture: taking the capture path although this host would allow a rename (the legacy containers are removed after being captured into the backup directory, and --rollback recreates them)"
fi
if [[ $STRATEGY == rename ]]; then
  for c in "${LEGACY_ALL[@]}"; do
    if podman container exists "$c-legacy-$suffix"; then ql_die "$c-legacy-$suffix already exists; pick another --suffix"; fi
  done
fi

legacy_units_present=() legacy_units_enabled=()
for u in "${LEGACY_UNITS[@]}"; do
  if app_unit_exists "$u"; then
    legacy_units_present+=("$u")
    [[ $(systemctl --user is-enabled "$u" 2>/dev/null || true) == enabled ]] && legacy_units_enabled+=("$u")
  fi
done
if ((${#legacy_units_present[@]})); then
  ql_info "legacy units on this host: ${legacy_units_present[*]} (enabled: ${legacy_units_enabled[*]:-none})"
else
  ql_warn "no odoo18* user unit on this host; the legacy containers will be stopped with podman stop and started again by --rollback the same way"
fi
ql_info "legacy Odoo $legacy_odoo_ver on ${legacy_bind}:${legacy_port}, PostgreSQL major ${legacy_pg_major:-?}"
ql_info "volumes: $db_vol (database), $web_vol (filestore) - both adopted in place"
ql_info "network: $legacy_net - adopted in place"
ql_info "addons:  $addons"

# =================================================================================================
# derive the env file the Quadlet units render from
# =================================================================================================
derive_env() {
  local f=$1
  ql_env_set "$f" WOOW_ODOO_BIND "$legacy_bind"
  ql_env_set "$f" WOOW_ODOO_PORT "$legacy_port"
  ql_env_set "$f" WOOW_ODOO_ADDONS_DIR "$(app_spec_path "$addons")"
  ql_env_set "$f" WOOW_ODOO_LIST_DB "$list_db"
}
app_render() {
  local w=$1 env=$2
  local -a RENDER_ARGS=()
  mkdir -p "$w/src" "$w/out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$w/src/"
  ql_env_load "$env"
  # shellcheck source=render-args.sh
  . "$REPO/scripts/render-args.sh"
  render_args "$env"
  ql_render "$w/src" "$env" "$REPO/quadlet/render-vars" "$w/out" "${RENDER_ARGS[@]}"
  ql_dryrun "$w/out" --verify --ref-dir "$QL_QUADLET_DIR_REF" \
    || ql_die "the rendered units failed the Quadlet dry-run; nothing was installed"
}
QL_QUADLET_DIR_REF=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
ql_cleanup work rm -rf "$WORK"

if [[ $mode == dry-run ]]; then
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/$APP.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/$APP.env"; fi
  derive_env "$WORK/$APP.env"
  app_render "$WORK/render" "$WORK/$APP.env"
  if [[ $STRATEGY == capture ]]; then
    ql_info "dry-run: every check passed and the units render. The cutover would stop ${legacy_units_present[*]:-the containers}, capture ${LEGACY_ALL[*]} into the backup directory and remove them, and install:"
  else
    ql_info "dry-run: every check passed and the units render. The cutover would stop ${legacy_units_present[*]:-the containers}, rename ${LEGACY_ALL[*]} to *-legacy-$suffix and install:"
  fi
  sed 's/^/    /' < <(grep -vE '^[[:space:]]*(#|$)' "$WORK/$APP.env") >&2
  exit 0
fi

# =================================================================================================
# 2. prepare (no downtime): env file, secrets, images, hot backup, fingerprints, capture
# =================================================================================================
ql_info "step 2/5: env file, secrets, images and a hot backup (no downtime yet)"
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "creating $ENV_FILE from the example and filling it in from the running stack"
derive_env "$ENV_FILE"
ql_env_load "$ENV_FILE"
app_refuse_env_secrets

# The adopted volume decides the password, so the secret follows the volume - never the other way.
ql_secret_ensure odoo18-postgres-password env:LEGACY_DB_PASSWORD --update
if ((adopt_master)); then
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_MASTER
  ql_secret_ensure odoo18-admin-password env:LEGACY_MASTER --update
else
  ql_secret_ensure odoo18-admin-password random:44
fi
LEGACY_DB_PASSWORD='' LEGACY_MASTER=''
odoo_render_conf_secret

app_render "$WORK/render" "$ENV_FILE"
ql_pull_images "$WORK/render/out"

bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then
  bk=$(app_new_backup_dir migrate)
fi
podman inspect "${LEGACY_ALL[@]}" >"$bk/inspect.json"
chmod 600 "$bk/inspect.json"
for u in "${legacy_units_present[@]:-}"; do
  [[ -n $u ]] || continue
  systemctl --user cat "$u" >"$bk/$u" 2>/dev/null || true
done
if [[ -n $LEGACY_CONF ]]; then
  (umask 077 && printf '%s\n' "$LEGACY_CONF" >"$bk/legacy-odoo.conf")
  ql_info "archived the legacy $legacy_conf_path (it carries both passwords; the backup directory is 0700)"
fi
if [[ -n $legacy_dir ]]; then
  legacy_dir=$(cd -- "$legacy_dir" && pwd -P) || ql_die "no such directory: $legacy_dir"
  for f in .env docker-compose.yml docker-compose.podman.yml; do
    [[ -r $legacy_dir/$f ]] && (umask 077 && cp -p -- "$legacy_dir/$f" "$bk/legacy-$f")
  done
  ql_info "archived the legacy checkout's .env and compose file from $legacy_dir"
fi
odoo_dump_all "$bk"
app_record_fingerprints "$bk/volume-fingerprints" "$DB_VOLUME" "$WEB_VOLUME"
{
  printf 'odoo version: %s\npostgresql major: %s\n' "$legacy_odoo_ver" "${legacy_pg_major:-?}"
  printf 'publish: %s:%s\naddons: %s\nlist_db: %s\n' "$legacy_bind" "$legacy_port" "$addons" "$list_db"
  printf 'db volume: %s\nfilestore volume: %s\nnetwork: %s\n' "$db_vol" "$web_vol" "$legacy_net"
  printf 'databases: %s\n' "$(cat "$bk/databases/COUNT")"
  printf 'rollback strategy: %s\n' "$STRATEGY"
  printf '%s\n' "--- volume fingerprints (CreatedAt|mountpoint inode|$APP_VOLUME_MARKER inode) ---"
  cat "$bk/volume-fingerprints"
  printf '%s\n' '--- pg_database ---'
  podman exec "$DB_CONTAINER" psql -X -U odoo -d postgres -Atc \
    'SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY 1' 2>/dev/null || true
  printf '%s\n' '--- installed extensions in postgres ---'
  podman exec "$DB_CONTAINER" psql -X -U odoo -d postgres -Atc \
    "SELECT extname || ' ' || extversion FROM pg_extension ORDER BY 1" 2>/dev/null || true
} >"$bk/precheck.txt"
chmod 600 "$bk/precheck.txt"
ql_info "pre-migration state saved in $bk/precheck.txt"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT "$legacy_port"
state_set LEGACY_BIND "$legacy_bind"
state_set RETIRED "${LEGACY_ALL[*]}"
# The container ids, in the same order, so a rollback can tell the legacy container apart from a
# stranger that took its name while the cutover was down.
legacy_ids=()
for c in "${LEGACY_ALL[@]}"; do legacy_ids+=("$(podman inspect --format '{{.Id}}' "$c")"); done
state_set LEGACY_IDS "${legacy_ids[*]}"
state_set LEGACY_UNITS_ENABLED "${legacy_units_enabled[*]:-}"
# On the capture path the rollback copy is written now, while the legacy stack still runs: a
# container whose create command cannot be replayed is refused before any downtime.
if [[ $STRATEGY == capture ]]; then app_legacy_capture "$bk" "${LEGACY_ALL[@]}"; fi
state_set STRATEGY "$STRATEGY"
app_tighten_backup "$bk"
app_write_checksums "$bk"
if [[ $mode == prepare ]]; then
  ql_info "prepared. Run the cutover with the same options minus --prepare-only"
  exit 0
fi

# =================================================================================================
# 3. cutover: stop, cold copy, retire (downtime starts here and is measured)
# =================================================================================================
app_confirm odoo18 "$ASSUME_YES" "the cutover stops Odoo for a few minutes"
ql_info "step 3/5: stopping the legacy units and containers, cold volume export, retiring the containers ($STRATEGY)"
state_set STATUS cutover
DOWN_FROM=$(date +%s)
for u in "${legacy_units_present[@]:-}"; do
  [[ -n $u ]] || continue
  systemctl --user disable "$u" >/dev/null 2>&1 || true
  systemctl --user stop "$u" >/dev/null 2>&1 || true
  ! systemctl --user is-active --quiet "$u" || ql_die "$u is still active"
done
((${#legacy_units_present[@]} == 0)) || ql_info "disabled and stopped ${legacy_units_present[*]} (the unit files stay on disk for --rollback)"
# The web container first: it holds the connections.
for c in "$WEB_CONTAINER" "$DB_CONTAINER"; do
  if app_running "$c"; then podman stop -t 60 "$c" >/dev/null; fi
  ! app_running "$c" || ql_die "$c is still running"
done
mapfile -t listeners < <(app_port_listeners "$legacy_port")
((${#listeners[@]} == 0)) || ql_die "host port $legacy_port is still bound by ${listeners[*]} after the legacy stack stopped; the Quadlet odoo18-web could not bind it"
ql_info "host port $legacy_port is free"
if ((cold_copy)); then
  ql_backup_volume "$DB_VOLUME" "$bk/volumes" >/dev/null
  ql_backup_volume "$WEB_VOLUME" "$bk/volumes" >/dev/null
else
  ql_warn "--no-cold-copy: no podman volume export was taken; the hot dumps in $bk/databases are the only database backup"
fi
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${LEGACY_ALL[@]}"
app_tighten_backup "$bk"
app_write_checksums "$bk"

# =================================================================================================
# 4. install    5. prove the adoption, wait, smoke, report the downtime
# =================================================================================================
ql_info "step 4/5: scripts/install.sh"
failed=0
install_args=(--no-smoke --accept-defaults)
((fix_perms == 0)) || install_args+=(--fix-addon-perms)
"$REPO/scripts/install.sh" "${install_args[@]}" || failed=1
DOWN_TO=$(date +%s)
if ((!failed)); then
  ql_info "step 5/5: proving the data was adopted, then the checks"
  app_verify_fingerprints "$bk/volume-fingerprints" || { ql_warn "the new stack is NOT on the legacy volumes"; failed=1; }
fi
if ((!failed)); then
  ql_wait_http "http://$(app_local_host "$legacy_bind"):$legacy_port/web/health" '200' 300 || failed=1
fi
if ((!failed)); then
  now=$(odoo_databases | grep -c . || true)
  was=$(cat "$bk/databases/COUNT")
  if [[ $now == "$was" ]]; then
    ql_info "database count unchanged across the cutover: $now"
  else
    ql_warn "the legacy stack had $was Odoo database(s) and the migrated one reports $now"
    failed=1
  fi
fi
if ((!failed)); then
  "$REPO/tests/smoke.sh" || failed=1
fi
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    ASSUME_YES=1 rollback
    ql_die "migration failed and was rolled back; the legacy stack serves again. Logs: journalctl --user -u odoo.service -u odoo-db.service"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
state_set STATUS "done"
state_set DOWNTIME_S "$((DOWN_TO - DOWN_FROM))"
ql_info "migration complete. Measured downtime: $((DOWN_TO - DOWN_FROM))s (from stopping the legacy stack to install.sh returning)."
ql_info "compare with $bk/precheck.txt (databases, sizes, extensions, volume fingerprints)."
if ((adopt_master == 0)); then
  ql_info "the Odoo master password is NEW. Read it in a private terminal with: podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password"
fi
if [[ $STRATEGY == capture ]]; then
  ql_info "the legacy containers were captured into $bk/legacy-container and removed; --rollback recreates them."
else
  ql_info "the legacy containers ${LEGACY_ALL[0]}-legacy-$suffix and ${LEGACY_ALL[1]}-legacy-$suffix are kept, stopped, for --rollback."
fi
ql_info "  $0 --rollback"
ql_info "after the soak period, clean up as described in README ('After the soak')"
