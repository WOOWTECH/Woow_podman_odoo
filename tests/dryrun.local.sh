# shellcheck shell=bash
# tests/dryrun.local.sh: Odoo-specific assertions. Sourced at the end of tests/dryrun.sh (vendored),
# which provides run_variant, render_variant, $WORK, $REPO, $base, $failures.
# shellcheck disable=SC2154 # the variables above are defined by tests/dryrun.sh

check() { # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
has_line() { grep -qxF -- "$3" "$WORK/$1/out/$2"; }

check "example publishes Odoo on 127.0.0.1:18069" has_line example odoo.container 'PublishPort=127.0.0.1:18069:8069'
check "example mounts the default addons dir read-only" has_line example odoo.container \
  'Volume=%h/.local/share/odoo18/addons:/mnt/extra-addons:ro,Z'
check "a moved port and a custom addons dir are rendered" has_line fixture-custom odoo.container 'PublishPort=127.0.0.1:28069:8069'
check "the custom addons dir stays read-only" has_line fixture-custom odoo.container 'Volume=%h/src/my-addons:/mnt/extra-addons:ro,Z'
check "BIND=all omits the host address" has_line fixture-lan odoo.container 'PublishPort=18069:8069'
check "the database publishes no port" bash -c "! grep -q '^PublishPort=' '$WORK/example/out/odoo-db.container'"
check "no unit is named odoo18 (a legacy odoo18.service would shadow it)" \
  bash -c "! ls '$REPO'/quadlet | grep -qE '^odoo18\\.(container|service)$'"

# The odoo.conf template renders completely, and only from its own whitelist.
conf_render() {
  ql_render "$REPO/config/odoo.conf.template" - "$REPO/config/odoo.conf.render-vars" - \
    POSTGRES_PASSWORD=db-dummy ODOO_ADMIN_PASSWORD=admin-dummy WOOW_ODOO_LIST_DB=True
}
conf=$( (conf_render) 2>/dev/null) || conf=''
check "odoo.conf.template renders" test -n "$conf"
check "the rendered conf carries the database password" grep -qx 'db_password = db-dummy' <<<"$conf"
check "the rendered conf carries the master password" grep -qx 'admin_passwd = admin-dummy' <<<"$conf"
check "the conf points at the Quadlet database container" grep -qx 'db_host = odoo18-db' <<<"$conf"
check "no default master password in the template" bash -c "! grep -qE '^admin_passwd *= *admin *\$' '$REPO/config/odoo.conf.template'"

# Invalid knobs must stop the render before any file is written.
reject() { # reject <description> <KEY> <bad value>
  local env=$WORK/bad-$2.env
  sed "s|^$2=.*|$2=$3|" "$REPO/config/odoo18.env.example" >"$env"
  mkdir -p "$WORK/bad-$2/src" "$WORK/bad-$2/out"
  cp -p -- "${base[@]}" "$WORK/bad-$2/src/"
  if (render_variant "$WORK/bad-$2/src" "$env" "$WORK/bad-$2/out") >/dev/null 2>&1; then
    echo "FAIL $1 was accepted"
    failures=$((failures + 1))
  else
    echo "ok   $1 is refused"
  fi
}
reject "an addons dir with a Volume option separator" WOOW_ODOO_ADDONS_DIR '%h/addons:rw'
reject "a relative addons dir" WOOW_ODOO_ADDONS_DIR 'addons'
reject "an addons dir with '..'" WOOW_ODOO_ADDONS_DIR '%h/../etc'
reject "a list_db value other than True/False" WOOW_ODOO_LIST_DB yes
