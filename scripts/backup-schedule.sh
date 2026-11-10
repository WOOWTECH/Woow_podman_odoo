#!/usr/bin/env bash
# Install or remove an opt-in daily rootless systemd backup timer.
# Usage: scripts/backup-schedule.sh enable|disable|status
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
unit_dir=$HOME/.config/systemd/user
service=$unit_dir/odoo18-backup.service
timer=$unit_dir/odoo18-backup.timer
marker='# Managed by Woow_podman_odoo/scripts/backup-schedule.sh'

[[ $(id -u) != 0 ]] || { echo 'Run as the rootless Odoo operator, not root' >&2; exit 1; }
case ${1:-} in
  enable)
    [[ $# == 1 ]] || { echo 'Usage: backup-schedule.sh enable|disable|status' >&2; exit 2; }
    [[ $REPO =~ ^/[A-Za-z0-9/._+-]+$ ]] || { echo "Repository path contains characters unsafe for a systemd ExecStart: $REPO" >&2; exit 1; }
    systemctl --user is-active --quiet odoo-db.service \
      || { echo 'Start the Odoo database before enabling scheduled backups' >&2; exit 1; }
    [[ $(podman inspect --format '{{.State.Health.Status}}' odoo18-db 2>/dev/null) == healthy ]] \
      || { echo 'Wait for a healthy Odoo database before enabling scheduled backups' >&2; exit 1; }
    for unit in "$service" "$timer"; do
      if [[ -e $unit && $(head -n 1 "$unit") != "$marker" ]]; then
        echo "Refusing to replace an unmanaged unit: $unit" >&2
        exit 1
      fi
    done
    mkdir -p "$unit_dir"
    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    cat >"$temp/odoo18-backup.service" <<EOF
$marker
[Unit]
Description=Woow Odoo 18 verified daily backup
After=odoo-db.service
Requires=odoo-db.service

[Service]
Type=oneshot
ExecStart=$REPO/scripts/backup.sh --automated
TimeoutStartSec=2h
EOF
    cat >"$temp/odoo18-backup.timer" <<EOF
$marker
[Unit]
Description=Daily Woow Odoo 18 backup

[Timer]
OnCalendar=*-*-* 02:00:00 Asia/Taipei
RandomizedDelaySec=3h
Persistent=true
Unit=odoo18-backup.service

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "$temp/odoo18-backup.service" "$service"
    install -m 0644 "$temp/odoo18-backup.timer" "$timer"
    systemctl --user daemon-reload
    systemctl --user enable --now odoo18-backup.timer
    systemctl --user list-timers odoo18-backup.timer --no-pager
    ;;
  disable)
    [[ $# == 1 ]] || { echo 'Usage: backup-schedule.sh enable|disable|status' >&2; exit 2; }
    for unit in "$service" "$timer"; do
      if [[ -e $unit && $(head -n 1 "$unit") != "$marker" ]]; then
        echo "Refusing to remove an unmanaged unit: $unit" >&2
        exit 1
      fi
    done
    systemctl --user disable --now odoo18-backup.timer 2>/dev/null || true
    rm -f -- "$service" "$timer"
    systemctl --user daemon-reload
    echo 'Scheduled backups disabled; existing archives kept.'
    ;;
  status)
    [[ $# == 1 ]] || { echo 'Usage: backup-schedule.sh enable|disable|status' >&2; exit 2; }
    systemctl --user list-timers odoo18-backup.timer --no-pager
    ;;
  *) echo 'Usage: backup-schedule.sh enable|disable|status' >&2; exit 2 ;;
esac
