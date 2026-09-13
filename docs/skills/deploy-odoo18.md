# Odoo 18 Quadlet runbook / Odoo 18 Quadlet 操作手冊

A runbook for AI assistants and operators. The README has the details and the reasons; this page is
the short path. 給 AI 助手與維運人員的操作手冊；細節與理由見 README，這裡是最短路徑。

## Rules / 規則

- Run as the user that owns the containers, in a real login session (ssh or console). Never `sudo`.
  以擁有容器的使用者、在真正的登入工作階段執行，絕不使用 `sudo`。
- Never put a password on a command line, in the env file or in a commit; they live in podman secrets.
  密碼不可出現在指令列、env 檔或 commit，一律存於 podman secrets。
- Never print a secret into a shared log or chat. Read it only in a private terminal.
  不要把 secret 印到共享 log 或對話中，只在私人終端機讀取。
- The units are `odoo.service` and `odoo-db.service`. A unit named `odoo18.service` belongs to the
  retired compose deployment and would shadow them.
  單元是 `odoo.service` 與 `odoo-db.service`；`odoo18.service` 屬於已淘汰的 compose 部署，會蓋掉它們。

## Fresh install / 全新安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_odoo.git ~/Woow_podman_odoo
cd ~/Woow_podman_odoo
bash tests/dryrun.sh                       # static check on this host: same result as CI
scripts/install.sh --accept-defaults       # or run once, edit ~/.config/odoo18/odoo18.env, run again
tests/smoke.sh                             # every check must PASS
podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password   # private terminal
```

Port already taken / 埠已被占用：`scripts/install.sh --set WOOW_ODOO_PORT=28069`.

## Day 2 / 日常維運

| Task | Command |
|---|---|
| Status | `systemctl --user status odoo.service odoo-db.service` |
| Logs | `journalctl --user -u odoo.service -n 100` |
| Change a setting | edit `~/.config/odoo18/odoo18.env` or `config/odoo.conf.template`, then `scripts/install.sh` |
| Add addons | copy into `~/.local/share/odoo18/addons`, `chmod -R o+rX`, restart `odoo.service`, then `-u <module>` |
| Upgrade | `git pull && scripts/upgrade.sh` (automatic unit rollback on failure) |
| Backup | `scripts/backup.sh` |
| Restore | `scripts/restore.sh --archive <file> --confirm-restore odoo18` |
| Rotate passwords | `scripts/rotate-secrets.sh --db --admin` |
| Remove | `scripts/uninstall.sh` (keeps data) or `scripts/uninstall.sh --purge --confirm-purge odoo18` |

Remote host / 遠端主機：`ssh <host> 'cd ~/Woow_podman_odoo && git pull && scripts/upgrade.sh'`.

## Done when / 完成條件

- `tests/smoke.sh` ends with `0 failed`.
- `systemctl --user list-dependencies default.target --plain | grep -wE 'odoo(-db)?\.service'` lists
  both units (they start at boot through linger).
- A second `scripts/install.sh` reports `nothing to restart or start`.
