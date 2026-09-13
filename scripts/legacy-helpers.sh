# shellcheck shell=bash
# scripts/legacy-helpers.sh: everything scripts/migrate-legacy.sh needs that is not already in
# scripts/common.sh or scripts/odoo-helpers.sh. It is a separate file on purpose: common.sh is kept
# byte-identical below its settings block across Woow_podman_emqx, _hermes, _odoo and _opendesign,
# and the migration is not part of that shared surface.
#
# Sourced after scripts/lib/quadlet-lib.sh, scripts/common.sh and scripts/odoo-helpers.sh.
# tests/rollback-model.sh sources the same file, which is what pins these helpers.

# ---- small predicates --------------------------------------------------------------------------
app_running() { [[ $(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }
app_is_installed() { [[ -s "$(app_state_dir)/manifest" ]]; }
app_unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }

# app_unlocked <command...>: run a command without this script's per-app lock file descriptor.
#
# ql_lock holds the lock through a file descriptor that stays open for the rest of the script
# (`exec {fd}>lock; flock -n $fd`), and bash does not mark it close-on-exec. A container that this
# script starts ITSELF therefore inherits that descriptor into conmon, rootlessport and the
# container's own process - all of which outlive the script - and the flock is held for as long as
# the container runs. The next scripts/install.sh, backup.sh, upgrade.sh or
# `migrate-legacy.sh --rollback` then dies with "another install/upgrade/uninstall is running".
#
# Verified live on toypark1234, podman 4.9.3: after a rollback that ran `podman start odoo18-db
# odoo18-web`, `fuser` showed conmon, rootlessport and the container process holding
# ~/.local/state/woow-quadlet/odoo18/lock, and the UNMODIFIED scripts/install.sh and
# scripts/backup.sh both refused; `podman restart` on the two containers freed it again.
#
# Containers started through systemd are not affected - the user manager forks those, not us - so
# this only matters where the migration starts a legacy container directly, which is the rollback.
# `cmd {QL_LOCK_FD}>&-` closes the descriptor for that one command and leaves the variable (and the
# lock) intact.
app_unlocked() {
  if [[ -n ${QL_LOCK_FD:-} ]]; then "$@" {QL_LOCK_FD}>&-; else "$@"; fi
}

# app_spec_path <abs path>: rewrite $HOME/... as %h/... so a rendered unit carries no literal home
# path (systemd expands %h when it starts the unit; STANDARD section 2).
app_spec_path() {
  local p=$1
  [[ $p == "$HOME"/* ]] && p="%h/${p#"$HOME"/}"
  printf '%s' "$p"
}

# app_mount_source <container> <destination>: the host path or volume name mounted there.
# Prints "<type>|<name>|<source>"; empty when the container does not mount that destination.
# The template addresses Go FIELD names, never the lowercase JSON tags (STANDARD section 8).
app_mount_source() {
  podman inspect --format '{{range .Mounts}}{{.Destination}}|{{.Type}}|{{.Name}}|{{.Source}}{{println}}{{end}}' "$1" 2>/dev/null \
    | sed -n "s#^$2|##p" | tail -n1
}

# app_published <container> <port/proto>: "<host ip>|<host port>" of the first binding.
# `.HostIP` is the Go field name; the JSON tag is `HostIp` and a template using that spelling
# fails the WHOLE template with exit 125 and no stdout (STANDARD section 8, seen live in W2).
app_published() {
  podman inspect --format "{{range \$p, \$bs := .NetworkSettings.Ports}}{{if eq \$p \"$2\"}}{{range \$bs}}{{.HostIP}}|{{.HostPort}}{{println}}{{end}}{{end}}{{end}}" "$1" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | head -n1
}

# app_bind_for <host ip>: the WOOW_ODOO_BIND value that reproduces a podman port binding.
# podman reports the host IP of an all-interfaces publish as the EMPTY STRING, not as 0.0.0.0:
# `podman ps` prints "0.0.0.0:38069->8069/tcp" while `{{.HostIP}}` on the same container returns "".
# Verified live on podman 4.9.3 with a podman-compose `"${ODOO_PORT}:8069"` mapping, which is what
# the compose-final docker-compose.yml of this repo produces. Feeding that empty string straight
# into the env file makes render_args refuse WOOW_ODOO_BIND before anything is installed.
app_bind_for() {
  case ${1:-} in
    '' | 0.0.0.0 | '::' | '[::]') printf 'all' ;;
    *) printf '%s' "$1" ;;
  esac
}

# app_port_listeners <port>: every listening socket on that TCP port, one "addr" per line
app_port_listeners() { ss -ltnH "sport = :$1" 2>/dev/null | awk '{print $4}' | LC_ALL=C sort -u; }

# app_port_publishers <port>: the containers publishing that host port, one name per line
app_port_publishers() {
  local c
  local -a names=()
  mapfile -t names < <(podman ps --format '{{.Names}}' 2>/dev/null || true)
  for c in "${names[@]}"; do
    [[ -n $c ]] || continue
    if podman port "$c" 2>/dev/null | grep -qE "(^|:)$1\$"; then printf '%s\n' "$c"; fi
  done
}

# odoo_role_accepts <container>: does the password in $ODOO_CANDIDATE_PW authenticate as the role
# "odoo" over TCP? The new odoo.conf connects that way, while `psql -U odoo` on the container's own
# socket is trusted and proves nothing. The value travels through podman's own environment
# ("-e PGPASSWORD" with no value), never in argv, and xtrace is suspended around it.
odoo_role_accepts() {
  local xt=0 rc=0
  [[ $- == *x* ]] && xt=1 && set +x
  PGPASSWORD=${ODOO_CANDIDATE_PW:-}
  export PGPASSWORD
  podman exec -i -e PGPASSWORD "$1" \
    psql -X -q -w -h 127.0.0.1 -U odoo -d postgres -Atc 'SELECT 1' >/dev/null 2>&1 || rc=$?
  unset PGPASSWORD
  ((xt)) && set -x
  return "$rc"
}

# ---- backup bookkeeping ------------------------------------------------------------------------
# app_tighten_backup <dir>: 0700 directories, 0600 files. The backup holds the legacy odoo.conf and
# the legacy .env, both of which carry passwords. `app_new_backup_dir` already creates the top
# directory 0700, but podman writes `volume export` archives with its own mode (0644 on 4.9.3) and
# a plain `printf >file` follows the caller's umask, so the files inside are not private by
# themselves. Ownership of the tree is never changed.
app_tighten_backup() {
  find "$1" -type d -exec chmod 700 {} + || ql_warn "could not tighten the directories under $1"
  find "$1" -type f -exec chmod 600 {} + || ql_warn "could not tighten the files under $1"
}

# app_write_checksums <dir>: SHA256SUMS over every file in <dir>, relative paths, sorted.
app_write_checksums() {
  local list
  list=$(cd -- "$1" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.sha256' -printf '%P\n' | LC_ALL=C sort) \
    || ql_die "cannot list $1"
  (cd -- "$1" && umask 077 && while IFS= read -r f; do if [[ -n $f ]]; then sha256sum -- "$f"; fi; done <<<"$list" >SHA256SUMS.tmp \
    && mv -f SHA256SUMS.tmp SHA256SUMS) || ql_die "cannot write $1/SHA256SUMS"
}

# ---- the database dumps ------------------------------------------------------------------------
# odoo_dump_roles <file>: pg_dump does not carry roles, and the role "odoo" owns the password the
# adopted volume was initialised with, so it has to be in the backup on its own.
odoo_dump_roles() {
  (umask 077 && podman exec odoo18-db pg_dumpall -U odoo --roles-only >"$1.partial") \
    || { rm -f -- "$1.partial"; ql_die "pg_dumpall --roles-only failed"; }
  [[ -s $1.partial ]] || { rm -f -- "$1.partial"; ql_die "pg_dumpall --roles-only produced nothing"; }
  mv -f -- "$1.partial" "$1"
}

# odoo_dump_one <database> <file>: one custom-format dump. --file=- would create a file literally
# named "-" in this image, so the dump is streamed on stdout (same as scripts/backup.sh).
odoo_dump_one() {
  (umask 077 && podman exec odoo18-db pg_dump -U odoo --format=custom "$1" >"$2.partial") \
    || { rm -f -- "$2.partial"; ql_die "pg_dump of $1 failed"; }
  [[ $(head -c 5 "$2.partial") == PGDMP ]] || { rm -f -- "$2.partial"; ql_die "the dump of $1 is not in PostgreSQL custom format"; }
  mv -f -- "$2.partial" "$2"
}

# odoo_dump_all <backup dir>: dump the roles and EVERY Odoo database into <dir>/databases/, and
# record how many there were in <dir>/databases/COUNT.
#
# "No Odoo database at all" is a normal state, not an error: a freshly deployed stack has only the
# maintenance database `postgres` plus the templates, and that is exactly what woowtechopenclaw
# looks like today (`select datname from pg_database` -> postgres, template0, template1). A
# migration that treated an empty list as a failure would refuse to migrate the very host it was
# written for. The count is recorded either way so the post-migration comparison is explicit.
odoo_dump_all() {
  local bk=${1:?usage: odoo_dump_all <backup dir>} db raw
  local -a dbs=()
  mkdir -p "$bk/databases"
  odoo_dump_roles "$bk/roles.sql"
  raw=$(odoo_databases) || ql_die "cannot list the databases of the legacy stack"
  mapfile -t dbs < <(printf '%s' "$raw" | grep -v '^[[:space:]]*$' || true)
  if ((${#dbs[@]} == 0)); then
    ql_info "no Odoo database exists on the legacy stack (only 'postgres' and the templates); there is nothing to dump, which is a normal state and not an error"
  fi
  for db in "${dbs[@]}"; do
    [[ $db =~ ^[A-Za-z0-9_.-]+$ ]] || ql_die "refusing to dump a database with an unusual name: $db"
    odoo_dump_one "$db" "$bk/databases/$db.dump"
    ql_info "dumped database $db -> $bk/databases/$db.dump"
  done
  printf '%s\n' "${#dbs[@]}" >"$bk/databases/COUNT"
  printf '%s\n' "${dbs[@]:-}" | grep -v '^$' >"$bk/databases/LIST" || true
}

# ---- proving the data was adopted, never assuming it -------------------------------------------
# The units keep the compose names (VolumeName=odoo18-db-data / odoo18-web-data), so the new
# containers are supposed to open the SAME volumes. Without VolumeName= Quadlet would have made
# systemd-odoo-db-data and Odoo would have come up on an empty database looking perfectly healthy.
# So the fingerprint of each volume is recorded before the cutover and compared afterwards.
#
# A file inside the volume whose inode is a second, content-level proof that the SAME data came
# back. PG_VERSION is the one file a PostgreSQL data directory always has.
APP_VOLUME_MARKER=PG_VERSION

# app_volume_fingerprint <volume>: "<CreatedAt>|<mountpoint inode>|<marker inode or ->".
# `podman unshare` is needed because a PGDATA volume belongs to a container subuid.
app_volume_fingerprint() {
  local vol=$1 created mp ino mino=-
  created=$(podman volume inspect --format '{{.CreatedAt}}' "$vol" 2>/dev/null) || return 1
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$vol" 2>/dev/null) || return 1
  [[ $mp == /* && $mp != / ]] || return 1
  ino=$(podman unshare stat -c %i -- "$mp" 2>/dev/null) || return 1
  if podman unshare test -f "$mp/$APP_VOLUME_MARKER"; then
    mino=$(podman unshare stat -c %i -- "$mp/$APP_VOLUME_MARKER" 2>/dev/null || echo -)
  fi
  printf '%s|%s|%s' "$created" "$ino" "$mino"
}

# app_record_fingerprints <file> <volume>...
app_record_fingerprints() {
  local f=${1:?} v fp
  shift
  : >"$f"
  for v in "$@"; do
    fp=$(app_volume_fingerprint "$v") || ql_die "cannot fingerprint volume $v"
    printf '%s=%s\n' "$v" "$fp" >>"$f"
  done
}

# app_verify_fingerprints <file>: every recorded volume must still be the same volume, with the
# same on-disk directory. Returns 1 and names the volume when it is not.
app_verify_fingerprints() {
  local f=${1:?} v want got rc=0
  [[ -f $f ]] || { ql_warn "no volume fingerprint recorded in $f"; return 1; }
  while IFS='=' read -r v want; do
    [[ -n $v ]] || continue
    got=$(app_volume_fingerprint "$v") || got='(missing)'
    if [[ $got == "$want" ]]; then
      ql_info "volume $v was adopted in place (CreatedAt and inode unchanged: $want)"
    else
      ql_warn "volume $v is NOT the volume the legacy stack used: recorded [$want], now [$got]"
      rc=1
    fi
  done <"$f"
  return "$rc"
}

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -----------------------------
# Keeping the legacy containers renamed and stopped is a rollback path only while nothing starts
# them again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled a renamed,
# stopped container whose policy is exactly `always` revives and fights the new Quadlet container
# for its name, ports and volumes. podman 4.9.3 cannot defuse that in place (`podman update` is
# cgroup-only; a restart policy is fixed at create time), so there the answer is to capture the
# container and remove it. ql_rollback_strategy asks this host - is that unit enabled, what is each
# container's policy - and answers `rename` or `capture`; it never looks at a host name.
#
# odoo18-db and odoo18-web are `unless-stopped` on woowtechopenclaw today, so that host resolves to
# `rename`. That is a fact about today, not a property of the stack: --force-capture exercises the
# other path, and a host that later recreates them with `always` gets it automatically.
#
# Neither Odoo container is given --commit: odoo18-web keeps its filestore and sessions in
# odoo18-web-data and reads /etc/odoo/odoo.conf from a mount, odoo18-db keeps PGDATA in
# odoo18-db-data, so neither stack writes anything it needs into its own writable layer.

# app_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime: a
# container the library cannot replay (an empty CreateCommand - created through the podman API
# rather than the CLI) is refused here, while the legacy stack is still running.
app_legacy_capture() {
  local bk=${1:?usage: app_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# app_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy containers out
# of the new stack's way, in the shape the strategy asked for.
#
# The containers are listed DEPENDENCY FIRST (the database, then the web container). The rename
# path does not care, but the capture path removes them in REVERSE, dependents first, because
# podman-compose 1.0.6 turns `depends_on:` into `--requires=<name>` and podman then refuses to
# remove a container that something else requires:
#
#   Error: container <db> has dependent containers which must be removed before it: <web>
#
# Reproduced on toypark1234 against a podman-compose stack built from this repo's own compose-final
# tag, and it is the shape woowtechopenclaw runs today: its odoo18-web carries `--requires=odoo18-db`
# (and its open-design-nginx carries `--requires=open-design`). `podman rm --depend` would remove the
# dependent too, which is not what we want - each container has its own capture and its own removal.
app_legacy_retire() {
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c i
  shift 3
  local -a order=("$@")
  case $strategy in
    rename)
      for c in "${order[@]}"; do
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)"
      done ;;
    capture)
      for ((i = ${#order[@]} - 1; i >= 0; i--)); do
        c=${order[i]}
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the capture
        # records and expects to find again, and `--depend` would remove a container that has its
        # own capture without going through it.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c"
      done ;;
    *) ql_die "unknown rollback strategy '$strategy'" ;;
  esac
}

# app_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its original
# restart policy; the caller starts it, exactly as it starts a renamed one.
app_legacy_restore() {
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  # Dependency first (the database before the web container): a captured container is recreated
  # with the `--requires=` its create command carried, and podman refuses that if the container it
  # requires does not exist yet.
  for c in "$@"; do
    if podman container exists "$c"; then
      # The cutover did not get as far as retiring this one - it failed between the stop and the
      # rename/removal - so it is already back under its own name, merely stopped. The caller has
      # already removed any container of this name that belonged to the Quadlet units.
      ql_info "$c is already present under its own name; nothing to restore"
    elif [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}

# ---- the Odoo master password -------------------------------------------------------------------
# odoo_master_is_weak <value>: true for a value a migration must not carry forward. The compose-era
# config/odoo.conf of this repo shipped `admin_passwd = admin`, and tests/smoke.sh asserts that the
# master password "admin" is rejected - so adopting one would fail the smoke test and roll the whole
# migration back. A value containing a newline is refused too: it would corrupt the rendered
# odoo.conf, which is a line-oriented file.
odoo_master_is_weak() {
  case ${1,,} in '' | admin | admin123 | password | odoo | changeme | secret | odoo18) return 0 ;; esac
  [[ $1 == *$'\n'* ]]
}
