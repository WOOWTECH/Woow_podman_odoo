#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
[[ $(id -u) -ne 0 ]] || die "root/system-scope installation is forbidden"
require_command "$SYSTEMCTL_BIN"
[[ "$PROJECT_ROOT" != *[[:space:]]* && "$PROJECT_ROOT" != *'%'* && "$PROJECT_ROOT" != *'$'* && "$PROJECT_ROOT" != *'"'* && "$PROJECT_ROOT" != *'\\'* ]] || die "repository path contains unsupported systemd characters"
: "${HOME:?HOME must be set for user systemd installation}"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$unit_dir"; chmod 700 "$unit_dir"

main_changed=false
health_changed=false
timer_changed=false
for name in odoo18.service odoo18-health.service odoo18-health.timer; do
  template="$PROJECT_ROOT/systemd/$name.in"
  unit="$unit_dir/$name"
  tmp=$(mktemp "$unit_dir/.$name.XXXXXX")
  python3 - "$PROJECT_ROOT" "$template" >"$tmp" <<'PY'
import pathlib, sys
root, template = sys.argv[1:]
print(pathlib.Path(template).read_text().replace('@PROJECT_ROOT@', root), end='')
PY
  chmod 644 "$tmp"
  if [[ ! -f "$unit" ]] || ! cmp -s "$tmp" "$unit"; then
    mv -f "$tmp" "$unit"
    case "$name" in
      odoo18.service) main_changed=true ;;
      odoo18-health.service) health_changed=true ;;
      odoo18-health.timer) timer_changed=true ;;
    esac
  else
    rm -f "$tmp"
  fi
done

if $main_changed || $health_changed || $timer_changed; then
  "$SYSTEMCTL_BIN" --user daemon-reload
fi
main_enabled=$($SYSTEMCTL_BIN --user is-enabled odoo18.service 2>/dev/null || true)
timer_enabled=$($SYSTEMCTL_BIN --user is-enabled odoo18-health.timer 2>/dev/null || true)
main_active=$($SYSTEMCTL_BIN --user is-active odoo18.service 2>/dev/null || true)
timer_active=$($SYSTEMCTL_BIN --user is-active odoo18-health.timer 2>/dev/null || true)
if [[ "$main_enabled" != enabled || "$timer_enabled" != enabled ]]; then
  # The triggered health service is deliberately static and is never enabled.
  "$SYSTEMCTL_BIN" --user enable odoo18.service odoo18-health.timer
fi
main_restarted=false
if $main_changed || [[ "$main_active" != active ]]; then
  "$SYSTEMCTL_BIN" --user restart odoo18.service
  main_restarted=true
fi
# Restart the timer after the main service because main's stop path quiesces it.
# A health-service content change also needs a fresh timer schedule after reload.
if $timer_changed || $health_changed || $main_restarted || [[ "$timer_active" != active ]]; then
  "$SYSTEMCTL_BIN" --user restart odoo18-health.timer
fi

loginctl_bin=${LOGINCTL_BIN:-loginctl}
if command -v "$loginctl_bin" >/dev/null 2>&1; then
  linger=$($loginctl_bin show-user "${USER:?}" -p Linger --value 2>/dev/null || true)
  [[ "$linger" == yes ]] || log "Boot startup needs administrator action: loginctl enable-linger $USER"
fi
log "User units installed at $unit_dir (odoo18.service and odoo18-health.timer enabled)"
