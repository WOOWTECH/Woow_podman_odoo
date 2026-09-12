# Deployment acceptance record / 部署驗收紀錄

Evidence template for a Quadlet deployment of this repo. Record only observed results. Never record
a password, a secret value, an archive's contents, or tunnel/tailnet authentication material — the
commands below are written so that none of them prints one.

本檔為 Quadlet 部署的證據範本。只填寫實際觀察到的結果；絕不可記錄密碼、secret 內容、備份內容或
通道／tailnet 認證資料。下列指令均已避免輸出任何密碼。

Copy this file to `docs/records/<host>-<date>.md` for an actual run; leave this one as the template.
Mark anything you did not run as `NOT RUN — <reason>`. Do not fabricate results.

## Prerequisites / 前置需求

| Item | Command | Result |
|---|---|---|
| Date (UTC) / 日期 | `date -u +%FT%TZ` | |
| Operator / 操作者 | | |
| Commit | `git rev-parse --short HEAD` | |
| Host and OS / 主機與系統 | `hostnamectl \| sed -n '1p;/Operating System/p'` | |
| Podman | `podman --version` (must be >= 4.9) | |
| Quadlet generator | `/usr/libexec/podman/quadlet -version` | |
| Rootless and linger | `id -u` (not 0) and `loginctl show-user $USER -p Linger` | |
| Image digests / 映像 digest | `grep -h '^Image=' quadlet/*.container` | |

## Static acceptance / 靜態驗收

| Check | Command | Result |
|---|---|---|
| Quadlet dry-run + `systemd-analyze verify` | `tests/dryrun.sh` | |
| Repo lint (credentials, D1, READMEs, image pins) | `tests/lint-repo.sh` | |
| Leaked-value scan / 外洩值掃描 | `python3 tests/leaked-value-scan.py` | |
| Vendored library unmodified | `sha256sum -c scripts/lib/quadlet-lib.manifest` | |
| Shell lint | `shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh` | |
| Python tests | `python3 -m pytest tests/ -q` (or `tests/run.sh`) | |

## Install / 安裝

| Step | Command | Result |
|---|---|---|
| Dry run / 試跑 | `scripts/install.sh --dry-run` | |
| First install / 首次安裝 | `scripts/install.sh` | |
| Idempotence / 冪等性 | `scripts/install.sh` again — must report no restart | |
| Port override (isolated test) / 埠覆寫 | `scripts/install.sh --set WOOW_ODOO_PORT=<port>` | |
| Units / 單元 | `systemctl --user list-units 'odoo*'` | |
| Loopback only / 僅限 loopback | `ss -ltnp \| grep <port>` — must show `127.0.0.1`, and the database no port at all | |
| Database password accepted / 資料庫密碼 | install.sh runs `odoo_check_db_password`; an adopted volume that fails needs `scripts/rotate-secrets.sh --db` | |

## Verify / 驗證

| Check | Command | Result |
|---|---|---|
| Smoke | `tests/smoke.sh` | |
| HTTP | `curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/web/health` | |
| Secrets exist (names only) / secret 名稱 | `podman secret ls --format '{{.Name}}'` | |
| No plaintext credential on disk | `grep -rIl 'admin_passwd' ~/.config/odoo18/ ; echo rc=$?` | |

## Reboot and linger / 重開機與 linger

| Check | Command | Result |
|---|---|---|
| Survives logout / 登出後仍執行 | `loginctl terminate-user $USER`, then re-check the units | |
| Survives reboot / 重開機後自動啟動 | reboot, then `systemctl --user is-active odoo.service` | |

## Backup and restore / 備份與還原

| Step | Command | Result |
|---|---|---|
| Backup | `scripts/backup.sh` | |
| Archive permissions / 備份權限 | `stat -c '%a %n' <archive>/*` — files 0600, directory 0700 | |
| Archive validation | `python3 tests/validate-backup.py <archive>` | |
| Restore drill / 還原演練 | `scripts/restore.sh --archive <archive> --confirm-restore odoo18` | |
| Post-restore verification / 還原後驗證 | `tests/smoke.sh` | |

## Upgrade / 升級

| Step | Command | Result |
|---|---|---|
| Upgrade | `git pull && scripts/upgrade.sh` | |
| Rollback exercised? / 是否演練回滾 | | |

## Rotation / 輪替

| Step | Command | Result |
|---|---|---|
| Database role password | `scripts/rotate-secrets.sh --db` | |
| Master password | `scripts/rotate-secrets.sh --admin` | |

## Removal / 移除

| Step | Command | Result |
|---|---|---|
| Default removal keeps data / 一般移除保留資料 | `scripts/uninstall.sh`, then `podman volume ls` | |
| Purge (only if deliberately tested) / 清除 | `scripts/uninstall.sh --purge` | |

## Security boundary / 安全邊界

| Invariant | Result |
|---|---|
| Odoo published on 127.0.0.1 only / Odoo 僅在 loopback | |
| Database publishes no host port / 資料庫不對外開埠 | |
| No plaintext credential in the repo or in any unit / 倉庫與單元無明文憑證 | |
| Master password is the generated secret, not `admin` / master 密碼為產生值 | |
| The previously leaked database password has been rotated on this host / 已輪替外洩的資料庫密碼 | |

## Observations / 觀察

