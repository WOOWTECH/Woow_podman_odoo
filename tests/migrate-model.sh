#!/usr/bin/env bash
# tests/migrate-model.sh: pins the behaviour of scripts/migrate-legacy.sh that decides what happens
# to real data and to the rollback path. The helpers it exercises live in scripts/legacy-helpers.sh,
# which is the only code that:
#   * chooses between "rename and leave stopped" and "capture and remove" (STANDARD 7a),
#   * dumps the legacy databases, including the case where there is none,
#   * proves that the Quadlet containers opened the SAME volumes the compose stack used,
#   * decides whether the legacy Odoo master password may be carried forward.
#
#   tests/migrate-model.sh [name-filter]
#
# podman and systemctl are the doubles in tests/shims, placed first on PATH; every test gets its own
# HOME and shim state. No container is created and the real user manager is never touched. Two host
# shapes are modelled:
#   toypark1234       podman-restart.service disabled -> rename, exactly as the live migrations
#                     there behave today
#   woowtechopenclaw  podman-restart.service enabled and a container with restart-policy `always`
#                     -> capture and remove, because a renamed copy would revive at the next boot
#                     and a second PostgreSQL would open odoo18-db-data
# The Odoo containers are `unless-stopped` on woowtechopenclaw today, so that host resolves to
# `rename`; --force-capture is what lets the capture path be exercised on a host that does not need
# it, and it is pinned here too.
#
# Every test runs in its own subshell on purpose (isolated HOME, shim state, env), so the
# "modified in a subshell" notes do not apply here. Several tests replace a helper of
# scripts/legacy-helpers.sh with a stub so the logic above it can be exercised without podman;
# the linter cannot see that the code under test calls those stubs (SC2329 on 0.10+, SC2317 on 0.9,
# which is what the CI runner ships).
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/odoo18-migrate-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

# ---- fixtures ------------------------------------------------------------------------------------
# mk_legacy <name> <policy>: a podman-compose style legacy container in the shim state. Its
# CreateCommand is a `podman run` that carries -d/--rm/--replace/--cidfile and NO --restart, which is
# how podman-compose 1.0.6 leaves one (the policy lives on the container object only) - verified
# against the real odoo18-db and odoo18-web on woowtechopenclaw.
mk_legacy() {
  local name=$1 policy=$2 image=docker.io/library/odoo:18.0 d
  d=$SHIM_STATE/containers/$name
  mkdir -p "$d" "$SHIM_STATE/image-ids"
  printf '%s' "$policy" >"$d/policy"
  printf '0' >"$d/retries"
  printf 'cid-%s' "$name" >"$d/id"
  printf '%s' "$image" >"$d/image"
  printf 'imgid-odoo' >"$d/image_id"
  printf 'imgid-odoo' >"$SHIM_STATE/image-ids/${image//[\/:@]/_}"
  printf 'bridge' >"$d/netmode"
  printf 'false' >"$d/autoremove"
  printf 'odoo18' >"$d/project"
  printf '%s' "$name" >"$d/service"
  printf '4096' >"$d/sizerw"
  printf 'volume|odoo18-web-data|/vol/odoo18-web-data|/var/lib/odoo|true|rprivate\n' >"$d/mounts"
  printf 'odoo18-network|%s cid-%s |10.89.2.7|aa:bb:cc:dd:ee:03\n' "$name" "$name" >"$d/networks"
  printf '8069/tcp|127.0.0.1:18069 \n' >"$d/ports"
  printf 'io.podman.compose.project=odoo18\n' >"$d/labels"
  : >"$d/label"
  printf '%s\0' /usr/bin/podman run "--name=$name" -d --rm --replace \
    --cidfile "/run/user/1000/$name.cid" --label io.podman.compose.project=odoo18 \
    -v odoo18-web-data:/var/lib/odoo --net odoo18-network -e POSTGRES_USER=odoo \
    docker.io/library/odoo:18.0 >"$d/createcommand.argv0"
}
# mk_dependent <name> <policy> <requires>: like mk_legacy, but the create command carries the
# `--requires=<other>` that podman-compose 1.0.6 writes for a `depends_on:` - which is what both
# odoo18-web and open-design-nginx carry on woowtechopenclaw.
mk_dependent() {
  mk_legacy "$1" "$2"
  printf '%s\0' /usr/bin/podman run "--name=$1" -d "--requires=$3" --rm --replace \
    -v odoo18-web-data:/var/lib/odoo --net odoo18-network \
    docker.io/library/odoo:18.0 >"$SHIM_STATE/containers/$1/createcommand.argv0"
  printf '%s' "$3" >"$SHIM_STATE/containers/$1/requires"
}
# mk_api_created <name> <policy>: a container created through the podman API (docker-compose over
# the socket, podman play): its CreateCommand is empty, so nothing can be replayed.
mk_api_created() {
  mk_legacy "$1" "$2"
  : >"$SHIM_STATE/containers/$1/createcommand.argv0"
}
enable_restart_unit() { # what woowtechopenclaw looks like
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}

# ---- the toypark shape: rename, and nothing else --------------------------------------------------
t_disabled_restart_unit_keeps_the_rename_path() {
  mk_legacy odoo18-db unless-stopped
  mk_legacy odoo18-web unless-stopped
  eq "$(ql_rollback_strategy odoo18-db odoo18-web 2>/dev/null)" rename "strategy on a toypark-like host"
  expect_ok app_legacy_retire rename 20260914 "$T/bk" odoo18-db odoo18-web
  has "$OUT" "renamed odoo18-web -> odoo18-web-legacy-20260914"
  eq "$(ncalls 'podman rename odoo18-db odoo18-db-legacy-20260914')" 1 "rename of the database"
  eq "$(ncalls 'podman rename odoo18-web odoo18-web-legacy-20260914')" 1 "rename of the web container"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed on the rename path"
  eq "$(ncalls 'podman commit')" 0 "nothing is committed on the rename path"
  [[ ! -d $T/bk/legacy-container ]] || die_t "the rename path must not write a capture"
  podman container exists odoo18-web-legacy-20260914 || die_t "the renamed container is missing"
  expect_ok app_legacy_restore 20260914 "$T/bk" odoo18-db odoo18-web
  has "$OUT" "renamed odoo18-web-legacy-20260914 -> odoo18-web"
  podman container exists odoo18-web || die_t "the rollback did not bring odoo18-web back"
  eq "$(ncalls 'podman create')" 0 "a renamed container is not recreated"
}

t_always_policy_with_a_disabled_unit_is_still_rename() {
  mk_legacy odoo18-db always
  mk_legacy odoo18-web always
  eq "$(ql_rollback_strategy odoo18-db odoo18-web 2>/dev/null)" rename "a disabled unit never revives anything"
}

# ---- the openclaw shape: capture, then remove -----------------------------------------------------
t_enabled_restart_unit_and_always_policy_takes_the_capture_path() {
  enable_restart_unit
  mk_legacy odoo18-db always
  mk_legacy odoo18-web always
  eq "$(ql_rollback_strategy odoo18-db odoo18-web 2>/dev/null)" capture "strategy on an openclaw-like host"
  expect_ok app_legacy_capture "$T/bk" odoo18-db odoo18-web
  local c
  for c in odoo18-web odoo18-db; do
    [[ -s $T/bk/legacy-container/$c/meta ]] || die_t "no capture of $c"
    eq "$(sed -n 's/^RECREATABLE=//p' "$T/bk/legacy-container/$c/meta")" 1 "$c is recreatable"
    eq "$(sed -n 's/^RESTART_POLICY=//p' "$T/bk/legacy-container/$c/meta")" always "$c policy recorded"
  done
  eq "$(ncalls 'podman rm ')" 0 "the capture removes nothing"
  eq "$(ncalls 'podman rename')" 0 "the capture renames nothing"
  expect_ok app_legacy_retire capture 20260914 "$T/bk" odoo18-db odoo18-web
  has "$OUT" "removed odoo18-web;"
  eq "$(ncalls 'podman rename')" 0 "the capture path must not rename"
  podman container exists odoo18-web && die_t "odoo18-web was not removed"
  podman container exists odoo18-web-legacy-20260914 && die_t "the capture path must not leave a renamed copy"
  return 0
}

t_unless_stopped_on_an_enabled_host_is_still_rename() {
  # woowtechopenclaw today: the restart unit IS enabled, but odoo18-db/-web are unless-stopped and
  # `podman start --all --filter restart-policy=always` compares the policy string exactly.
  enable_restart_unit
  mk_legacy odoo18-db unless-stopped
  mk_legacy odoo18-web unless-stopped
  eq "$(ql_rollback_strategy odoo18-db odoo18-web 2>/dev/null)" rename "unless-stopped is not matched by the restart filter"
}

t_the_capture_path_removes_dependents_first() {
  # podman-compose turns `depends_on:` into `--requires=`, and podman then refuses
  #   "container <db> has dependent containers which must be removed before it: <web>".
  # That is exactly what stopped the first capture-path rehearsal on toypark1234, half way through
  # the cutover, with the legacy stack already stopped.
  enable_restart_unit
  mk_legacy odoo18-db always
  mk_dependent odoo18-web always odoo18-db
  expect_ok app_legacy_capture "$T/bk" odoo18-db odoo18-web
  expect_ok app_legacy_retire capture 20260914 "$T/bk" odoo18-db odoo18-web
  # the dependent has to be gone before the one it requires
  local web db
  web=$(grep -n '^podman rm odoo18-web$' "$SHIM_STATE/calls" | cut -d: -f1)
  db=$(grep -n '^podman rm odoo18-db$' "$SHIM_STATE/calls" | cut -d: -f1)
  [[ -n $web && -n $db ]] || die_t "both containers should have been removed"
  ((web < db)) || die_t "odoo18-web (which requires odoo18-db) must be removed first; podman refuses otherwise"
}

t_the_rename_path_keeps_the_order_it_was_given() {
  mk_legacy odoo18-db unless-stopped
  mk_legacy odoo18-web unless-stopped
  expect_ok app_legacy_retire rename 20260914 "$T/bk" odoo18-db odoo18-web
  local web db
  db=$(grep -n '^podman rename odoo18-db ' "$SHIM_STATE/calls" | cut -d: -f1)
  web=$(grep -n '^podman rename odoo18-web ' "$SHIM_STATE/calls" | cut -d: -f1)
  ((db < web)) || die_t "a rename has no dependency constraint and must keep the given order"
}

t_the_restore_recreates_the_dependency_before_the_dependent() {
  enable_restart_unit
  mk_legacy odoo18-db always
  mk_dependent odoo18-web always odoo18-db
  expect_ok app_legacy_capture "$T/bk" odoo18-db odoo18-web
  expect_ok app_legacy_retire capture 20260914 "$T/bk" odoo18-db odoo18-web
  expect_ok app_legacy_restore 20260914 "$T/bk" odoo18-db odoo18-web
  local web db
  db=$(grep -n 'podman create .*--name=odoo18-db' "$SHIM_STATE/calls" | head -n1 | cut -d: -f1)
  web=$(grep -n 'podman create .*--name=odoo18-web' "$SHIM_STATE/calls" | head -n1 | cut -d: -f1)
  [[ -n $db && -n $web ]] || die_t "both containers should have been recreated"
  ((db < web)) || die_t "odoo18-db must be recreated before odoo18-web, which requires it"
}

t_a_cutover_that_failed_before_retiring_can_still_be_rolled_back() {
  # The cutover stops the legacy containers first and retires them afterwards. If it dies in
  # between - as the --requires failure above did - the containers are still there under their own
  # names, merely stopped, and the rollback must accept that instead of trying to recreate a
  # container that already exists.
  enable_restart_unit
  mk_legacy odoo18-db always
  mk_legacy odoo18-web always
  expect_ok app_legacy_capture "$T/bk" odoo18-db odoo18-web
  # no retire at all: this is the half-done cutover
  expect_ok app_legacy_restore 20260914 "$T/bk" odoo18-db odoo18-web
  has "$OUT" "odoo18-db is already present under its own name"
  eq "$(ncalls 'podman create')" 0 "nothing is recreated over a container that is still there"
  podman container exists odoo18-web || die_t "odoo18-web disappeared"
}

t_the_capture_path_never_removes_the_anonymous_volumes() {
  enable_restart_unit
  mk_legacy odoo18-web always
  expect_ok app_legacy_capture "$T/bk" odoo18-web
  expect_ok app_legacy_retire capture 20260914 "$T/bk" odoo18-web
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes the capture expects back"
  hasnt "$(calls)" "podman rm --volumes" "rm --volumes would delete the anonymous volumes"
}

t_the_rollback_recreates_a_captured_container_with_its_policy() {
  enable_restart_unit
  mk_legacy odoo18-web always
  expect_ok app_legacy_capture "$T/bk" odoo18-web
  expect_ok app_legacy_retire capture 20260914 "$T/bk" odoo18-web
  expect_ok app_legacy_restore 20260914 "$T/bk" odoo18-web
  has "$OUT" "recreated odoo18-web"
  podman container exists odoo18-web || die_t "the rollback did not recreate odoo18-web"
  eq "$(ql_container_restart_policy odoo18-web)" always "the original restart policy comes back"
}

t_capture_refuses_a_container_the_library_cannot_replay() {
  enable_restart_unit
  mk_api_created odoo18-web always
  expect_fail app_legacy_capture "$T/bk" odoo18-web
  has "$OUT" "podman API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
}

t_retire_refuses_to_remove_without_a_capture() {
  enable_restart_unit
  mk_legacy odoo18-web always
  expect_fail app_legacy_retire capture 20260914 "$T/bk" odoo18-web
  has "$OUT" "no rollback copy of odoo18-web"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed without a capture"
}

t_capture_is_idempotent_between_prepare_only_and_the_cutover() {
  enable_restart_unit
  mk_legacy odoo18-web always
  expect_ok app_legacy_capture "$T/bk" odoo18-web # --prepare-only
  expect_ok app_legacy_capture "$T/bk" odoo18-web # the cutover reuses the same backup dir
  has "$OUT" "already in"
}

t_the_capture_path_works_with_an_empty_suffix() {
  # A capture-path cutover renames nothing, so it has no <name>-legacy-<suffix> to name and may pass
  # an empty suffix. `${2:?}` would abort the script there; `${2-}` must not.
  enable_restart_unit
  mk_legacy odoo18-web always
  expect_ok app_legacy_capture "$T/bk" odoo18-web
  expect_ok app_legacy_retire capture "" "$T/bk" odoo18-web
  podman container exists odoo18-web && die_t "odoo18-web was not removed"
  expect_ok app_legacy_restore "" "$T/bk" odoo18-web
  has "$OUT" "recreated odoo18-web"
  expect_fail app_legacy_restore "" "$T/empty" odoo18-absent
  hasnt "$OUT" "-legacy- " "an empty suffix must not be spelled into the message"
  return 0
}

# ---- the per-app lock, as quadlet-lib 1.5.0 defines it ---------------------------------------
# Up to 1.4.0 the lock was an flock on a descriptor opened with `exec {fd}>`, which bash does not
# mark close-on-exec. Rootless podman leaves children behind by design - conmon, slirp4netns,
# rootlessport, the catatonit pause process - and every one of them inherited that descriptor and
# held the flock for as long as the container lived. The next install, upgrade, uninstall or
# --rollback then died with "another install/upgrade/uninstall is running". Reproduced live on
# toypark1234, where /proc named conmon and slirp4netns as the two holders, and worked around here
# with an app_unlocked wrapper that closed the descriptor for one command.
#
# 1.5.0 deletes the descriptor instead. The lock is the DIRECTORY <state>/<app>/lock.d holding an
# owner record of boot id, pid and that pid's start time, and "held" means that owner is still
# alive: a crashed lock is taken over, not waited on. QL_LOCK_FD survives as an always-empty
# variable so that scripts written against <= 1.4.0 still parse under `set -u`, which makes every
# app_unlocked wrapper a no-op. The wrapper is therefore gone, and what follows pins the property
# it was standing in for instead of pinning the wrapper.

t_the_lock_keeps_no_descriptor_for_a_child_to_inherit() {
  local dir rec f n=0
  ql_lock odoo18
  eq "${QL_LOCK_FD:-}" '' "QL_LOCK_FD (1.5.0 keeps it only so <= 1.4.0 callers still parse)"
  dir=$(_ql_state_dir odoo18)/lock.d
  [[ -d $dir ]] || die_t "ql_lock did not create the lock directory $dir"
  read -r rec <"$dir/owner" || die_t "the lock directory carries no owner record"
  eq "$rec" "$(_ql_owner_record)" "the owner record of the lock this shell holds"
  for f in /proc/self/fd/*; do
    if [[ $(readlink -- "$f" 2>/dev/null) == "$dir"* ]]; then n=$((n + 1)); fi
  done
  eq "$n" 0 "descriptors in this shell pointing at the lock"
  # ... and the same seen from an ordinary child, which is what conmon is
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  eq "$(bash -c 'n=0
    for f in /proc/self/fd/*; do
      if [[ $(readlink -- "$f" 2>/dev/null) == "$1"* ]]; then n=$((n + 1)); fi
    done
    printf %s "$n"' _ "$dir")" 0 "lock descriptors an ordinary child inherits"
  return 0
}

t_a_rollback_can_take_the_lock_after_an_earlier_run_left_processes_behind() {
  # The user-visible property app_unlocked was faking. A run takes the lock, leaves a process
  # running that outlives it - conmon's stand-in, and the reason the old descriptor leaked - and
  # exits normally. The rollback is this shell, and it must be able to take the same lock while
  # that process is still alive. Under 1.4.0 it could not: the flock was still held.
  local lingerer
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  bash -c '
    . "$1/scripts/lib/quadlet-lib.sh"
    ql_lock odoo18
    sleep 30 &
    printf "%s" "$!" >"$2"
  ' _ "$REPO" "$T/lingerer.pid" || die_t "the first run could not take the lock"
  lingerer=$(cat "$T/lingerer.pid")
  kill -0 "$lingerer" 2>/dev/null || die_t "the fixture is wrong: the lingering child is already gone"
  ql_lock odoo18
  eq "$(head -n1 "$(_ql_state_dir odoo18)/lock.d/owner")" "$(_ql_owner_record)" \
    "the owner record after the rollback took the lock"
  kill -0 "$lingerer" 2>/dev/null \
    || die_t "the lingering child died first; the test proved nothing"
  kill -9 "$lingerer" 2>/dev/null || true
  return 0
}

t_a_crashed_run_does_not_block_the_lock_for_ever() {
  # The same thing with no chance to tidy up: SIGKILL, so no EXIT trap runs and the lock directory
  # is left behind while a child of the dead run is still alive. Ownership is decided by the owner
  # record, not by the directory, so the next run takes the lock over and says so.
  local lingerer dir err
  dir=$(_ql_state_dir odoo18)/lock.d
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  bash -c '
    . "$1/scripts/lib/quadlet-lib.sh"
    ql_lock odoo18
    sleep 30 &
    printf "%s" "$!" >"$2"
    kill -9 $$
  ' _ "$REPO" "$T/crashed.pid" || true
  lingerer=$(cat "$T/crashed.pid" 2>/dev/null) || die_t "the fixture never started the lingering child"
  kill -0 "$lingerer" 2>/dev/null || die_t "the fixture is wrong: the lingering child is already gone"
  [[ -d $dir ]] || die_t "the fixture is wrong: the killed run still tidied its own lock away"
  err=$T/takeover.err
  ql_lock odoo18 2>"$err" # a ql_die here would end the test, which is exactly the 1.4.0 behaviour
  has "$(cat "$err")" "taking over the lock left behind by pid" "the takeover warning"
  eq "$(head -n1 "$dir/owner")" "$(_ql_owner_record)" "the owner record after the takeover"
  kill -9 "$lingerer" 2>/dev/null || true
  return 0
}

t_a_second_live_run_is_still_refused() {
  # Dropping app_unlocked must not turn the lock into a no-op. While the owner is ALIVE the lock
  # is still exclusive and a second run dies, rather than cutting over on top of the first.
  local holder dir n=0
  dir=$(_ql_state_dir odoo18)/lock.d
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  bash -c '. "$1/scripts/lib/quadlet-lib.sh"; ql_lock odoo18; sleep 30' _ "$REPO" &
  holder=$!
  while ((n++ < 200)) && [[ ! -s $dir/owner ]]; do sleep 0.05; done
  [[ -s $dir/owner ]] || { kill -9 "$holder" 2>/dev/null; die_t "the holder never took the lock"; }
  # a fresh process with no QL_LOCK_HELD to inherit: it must be refused outright
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  expect_fail env -u QL_LOCK_HELD bash -c '. "$1/scripts/lib/quadlet-lib.sh"; ql_lock odoo18' _ "$REPO"
  has "$OUT" "another install/upgrade/uninstall of odoo18 is running"
  kill -9 "$holder" 2>/dev/null || true
  return 0
}

t_a_child_script_reuses_the_lock_its_caller_holds() {
  # 1.5.0 exports QL_LOCK_HELD, so a wrapper can hold the lock and still call install.sh: the
  # nested ql_lock keeps the caller's lock instead of dying on it. That is the library contract
  # which replaces every local "skip ql_lock when the wrapper already holds it" hack.
  ql_lock odoo18
  [[ -n ${QL_LOCK_HELD:-} ]] || die_t "ql_lock did not publish QL_LOCK_HELD for child scripts"
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  expect_ok bash -c '. "$1/scripts/lib/quadlet-lib.sh"; ql_lock odoo18' _ "$REPO"
  has "$OUT" "keeping the lock held by the calling script"
  [[ -d $(_ql_state_dir odoo18)/lock.d ]] || die_t "the child released the lock its caller holds"
  return 0
}

t_no_1_4_0_lock_workaround_survives_in_the_scripts() {
  # app_unlocked closed a descriptor 1.5.0 never opens, and WOOW_QL_LOCK_HELD skipped a nested
  # ql_lock the library now resolves itself - and would silently stop install.sh locking at all
  # whenever that variable is stale in the environment. Neither may come back.
  local hit
  hit=$(grep -rnE 'app_unlocked|QL_LOCK_FD|WOOW_QL_LOCK_HELD' "$REPO/scripts" --include='*.sh' \
    | grep -v '/lib/quadlet-lib\.sh:') || true
  [[ -z $hit ]] || die_t "a quadlet-lib 1.4.0 lock workaround is back:"$'\n'"$hit"
  return 0
}

# ---- the empty-database case, which is what woowtechopenclaw actually is ---------------------------
t_no_odoo_database_is_a_normal_case() {
  # `select datname from pg_database` on woowtechopenclaw returns postgres, template0, template1 and
  # nothing else, so odoo_databases prints an empty list. That must produce a complete backup with
  # zero dumps, not a failure.
  odoo_databases() { printf ''; }
  odoo_dump_roles() { printf 'CREATE ROLE odoo;\n' >"$1"; }
  odoo_dump_one() { die_t "odoo_dump_one must not be called when there is no database"; }
  expect_ok odoo_dump_all "$T/bk"
  has "$OUT" "no Odoo database exists on the legacy stack"
  eq "$(cat "$T/bk/databases/COUNT")" 0 "recorded database count"
  eq "$(cat "$T/bk/databases/LIST")" "" "recorded database list"
  [[ -s $T/bk/roles.sql ]] || die_t "the roles dump must be taken even with no database: it carries the password the adopted volume was initialised with"
  eq "$(find "$T/bk/databases" -name '*.dump' | wc -l)" 0 "no dump files"
}

t_every_odoo_database_is_dumped() {
  odoo_databases() { printf 'prod\nstaging\n'; }
  odoo_dump_roles() { printf 'CREATE ROLE odoo;\n' >"$1"; }
  odoo_dump_one() { printf 'PGDMP-%s' "$1" >"$2"; }
  expect_ok odoo_dump_all "$T/bk"
  eq "$(cat "$T/bk/databases/COUNT")" 2 "recorded database count"
  eq "$(cat "$T/bk/databases/prod.dump")" "PGDMP-prod" "prod dump"
  eq "$(cat "$T/bk/databases/staging.dump")" "PGDMP-staging" "staging dump"
  has "$OUT" "dumped database staging"
}

t_a_database_with_an_unusual_name_is_refused() {
  odoo_databases() { printf 'prod\nweird; drop\n'; }
  odoo_dump_roles() { printf 'CREATE ROLE odoo;\n' >"$1"; }
  odoo_dump_one() { printf 'PGDMP-%s' "$1" >"$2"; }
  expect_fail odoo_dump_all "$T/bk"
  has "$OUT" "refusing to dump a database with an unusual name"
}

t_a_roles_dump_that_produced_nothing_is_fatal() {
  # pg_dumpall silently producing an empty file would hide the role password from the backup.
  odoo_databases() { printf ''; }
  expect_fail odoo_dump_all "$T/bk"
  has "$OUT" "pg_dumpall --roles-only produced nothing"
}

t_the_backup_is_private() {
  # The backup holds the legacy odoo.conf and the legacy .env, both of which carry passwords.
  # podman writes `volume export` archives 0644 and a plain redirect follows the umask, so the
  # files inside a 0700 directory are not private by themselves.
  mkdir -p "$T/bk/volumes" "$T/bk/databases"
  : >"$T/bk/legacy-odoo.conf"
  : >"$T/bk/volumes/odoo18-db-data.tar"
  chmod 755 "$T/bk/volumes"
  chmod 644 "$T/bk/legacy-odoo.conf" "$T/bk/volumes/odoo18-db-data.tar"
  expect_ok app_tighten_backup "$T/bk"
  eq "$(stat -c %a "$T/bk/legacy-odoo.conf")" 600 "the archived odoo.conf"
  eq "$(stat -c %a "$T/bk/volumes/odoo18-db-data.tar")" 600 "the exported volume"
  eq "$(stat -c %a "$T/bk/volumes")" 700 "a directory inside the backup"
}

# ---- proving the volumes were adopted, rather than assuming it -------------------------------------
t_matching_volume_fingerprints_prove_the_adoption() {
  app_volume_fingerprint() { printf '2026-08-28 04:38:10 +0800|4242|4343'; }
  expect_ok app_record_fingerprints "$T/fp" odoo18-db-data odoo18-web-data
  expect_ok app_verify_fingerprints "$T/fp"
  has "$OUT" "volume odoo18-db-data was adopted in place"
  has "$OUT" "volume odoo18-web-data was adopted in place"
}

t_a_freshly_created_volume_is_detected_as_not_adopted() {
  # Exactly what a .volume without VolumeName= would cause: Quadlet makes systemd-odoo-db-data, Odoo
  # comes up healthy on an EMPTY database, and nothing else in the migration would notice.
  app_volume_fingerprint() { printf '2026-08-28 04:38:10 +0800|4242|4343'; }
  expect_ok app_record_fingerprints "$T/fp" odoo18-db-data
  app_volume_fingerprint() { printf '2026-09-14 02:00:00 +0800|9999|8888'; }
  expect_fail app_verify_fingerprints "$T/fp"
  has "$OUT" "volume odoo18-db-data is NOT the volume the legacy stack used"
}

t_a_missing_fingerprint_file_is_not_a_pass() {
  expect_fail app_verify_fingerprints "$T/does-not-exist"
  has "$OUT" "no volume fingerprint recorded"
}

t_a_volume_that_cannot_be_fingerprinted_stops_the_recording() {
  app_volume_fingerprint() { return 1; }
  expect_fail app_record_fingerprints "$T/fp" odoo18-db-data
  has "$OUT" "cannot fingerprint volume odoo18-db-data"
}

# ---- the publish address ---------------------------------------------------------------------------
t_an_all_interfaces_publish_is_read_as_bind_all() {
  # podman 4.9.3 reports the host IP of an all-interfaces publish as the EMPTY STRING, while
  # `podman ps` prints 0.0.0.0. Feeding "" into the env file makes render_args refuse
  # WOOW_ODOO_BIND and the migration dies after the pre-flight has already passed - which is
  # exactly what happened on the first live rehearsal against a compose-final stack.
  eq "$(app_bind_for '')" all "an empty HostIP is an all-interfaces publish"
  eq "$(app_bind_for 0.0.0.0)" all "0.0.0.0 is an all-interfaces publish"
  eq "$(app_bind_for '::')" all "the IPv6 wildcard is an all-interfaces publish"
  eq "$(app_bind_for 127.0.0.1)" 127.0.0.1 "a loopback publish is kept verbatim"
  eq "$(app_bind_for 192.168.2.191)" 192.168.2.191 "a LAN publish is kept verbatim"
}

# ---- the Odoo master password ----------------------------------------------------------------------
t_a_weak_legacy_master_password_is_never_adopted() {
  # compose-final's config/odoo.conf shipped `admin_passwd = admin`, and tests/smoke.sh asserts that
  # "admin" is REJECTED - adopting it would fail the smoke test and roll the migration back.
  local w
  for w in '' admin ADMIN admin123 password odoo changeme secret odoo18; do
    odoo_master_is_weak "$w" || die_t "master password '$w' should be refused"
  done
  odoo_master_is_weak $'line1\nline2' || die_t "a multi-line master password would corrupt odoo.conf"
}

t_a_generated_legacy_master_password_is_adopted() {
  # woowtechopenclaw's .runtime/secrets/odoo_admin_password is a 45-character generated value.
  odoo_master_is_weak 'Qp4nN7vTz2LsA9xB3kR6yH1uJ0wE5cM8dF' && die_t "a generated master password must be adoptable"
  return 0
}

# ---- what the script itself must keep doing ---------------------------------------------------------
t_the_rollback_tells_the_legacy_container_from_a_stranger() {
  # A cutover that died between "stop" and "retire" leaves the legacy container in place under its
  # own name. The rollback must keep that one (it is the thing being rolled back to), remove a
  # container this repo's Quadlet units created, and refuse anything else - so the container id
  # recorded before the cutover has to be in the state file and has to be consulted.
  local s=$REPO/scripts/migrate-legacy.sh
  grep -q 'state_set LEGACY_IDS' "$s" || die_t "the prepare phase does not record the legacy container ids"
  grep -q 'state_get LEGACY_IDS' "$s" || die_t "the rollback does not read the recorded legacy container ids"
  grep -q 'is the legacy container the cutover stopped but never retired' "$s" \
    || die_t "the rollback has no branch for a legacy container that was never retired"
  grep -q 'is not the legacy container recorded before the cutover' "$s" \
    || die_t "the rollback does not refuse a stranger that took the name"
  return 0
}

t_migrate_legacy_asks_the_host_instead_of_hardcoding_a_path() {
  local s=$REPO/scripts/migrate-legacy.sh
  # An invocation, not just the word: a comment mentioning it would satisfy a bare grep.
  grep -qE '^STRATEGY=\$\(ql_rollback_strategy ' "$s" \
    || die_t "scripts/migrate-legacy.sh does not set STRATEGY from ql_rollback_strategy"
  grep -q 'is-enabled podman-restart.service' "$s" \
    && die_t "scripts/migrate-legacy.sh decides from podman-restart.service by itself instead of asking the library"
  grep -q 'app_legacy_retire' "$s" || die_t "the cutover does not go through app_legacy_retire"
  grep -q 'app_legacy_restore' "$s" || die_t "the rollback does not go through app_legacy_restore"
  grep -q 'app_legacy_capture' "$s" || die_t "the prepare phase does not capture"
  return 0
}

t_force_capture_only_ever_tightens() {
  # --force-capture may turn rename into capture and must never turn capture into rename.
  local s=$REPO/scripts/migrate-legacy.sh
  # shellcheck disable=SC2016 # a grep pattern, not a string to expand
  grep -qE 'force_capture\)\) *&& *\[\[ \$STRATEGY == rename \]\]' "$s" \
    || die_t "--force-capture is not guarded by 'the host said rename'"
  grep -qE 'STRATEGY=rename' "$s" && die_t "scripts/migrate-legacy.sh assigns STRATEGY=rename somewhere; only the library may choose rename"
  return 0
}

t_no_printf_format_starts_with_a_dash() {
  # bash's printf builtin reads a format string that begins with "-" as an OPTION:
  # `printf '--- pg_database ---\n'` dies with "printf: --: invalid option". That killed the first
  # live rehearsal of this script half way through writing precheck.txt, after the secrets had
  # already been created - so the whole prepare phase has to be re-runnable, and this must not
  # come back.
  local hits
  hits=$(grep -nE "printf +['\"]-" "$REPO/scripts/migrate-legacy.sh" "$REPO/scripts/legacy-helpers.sh" || true)
  [[ -z $hits ]] || die_t "printf format string starting with a dash:"$'\n'"$hits"
}

t_the_cutover_refuses_to_run_twice() {
  grep -qE 'cutover \| "done"\)' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "a recorded cutover/done state does not stop a second migration"
  return 0
}

t_the_adoption_is_proved_before_the_smoke_test() {
  local s=$REPO/scripts/migrate-legacy.sh a b
  a=$(grep -n 'app_verify_fingerprints' "$s" | tail -n1 | cut -d: -f1)
  b=$(grep -n 'tests/smoke.sh' "$s" | tail -n1 | cut -d: -f1)
  [[ -n $a && -n $b ]] || die_t "migrate-legacy.sh must both verify the fingerprints and run the smoke test"
  ((a < b)) || die_t "the volume adoption must be proved before tests/smoke.sh, which would pass on an empty database"
  return 0
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/bk"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=migrate-model
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/common.sh
    . "$REPO/scripts/common.sh"
    # shellcheck source=../scripts/odoo-helpers.sh
    . "$REPO/scripts/odoo-helpers.sh"
    # shellcheck source=../scripts/legacy-helpers.sh
    . "$REPO/scripts/legacy-helpers.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
