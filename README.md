# Secure Odoo 18 Operations / 安全的 Odoo 18 維運

A rootless Podman deployment of Odoo 18 Community, PostgreSQL 16, and pgvector 0.8.0. Images are pinned by release and digest in `docker-compose.yml`.

本專案以 rootless Podman 部署 Odoo 18 Community、PostgreSQL 16 與 pgvector 0.8.0；映像版本與 digest 固定於 `docker-compose.yml`。

## Prerequisites / 前置需求

- Linux user account (do not run lifecycle scripts as root) / Linux 一般使用者（不得以 root 執行生命週期腳本）
- Podman **4.9.3**, podman-compose **1.0.6**, Python 3, OpenSSL, curl, `flock`, and user systemd
- 4 GiB RAM and 10 GiB free disk recommended / 建議 4 GiB 記憶體與 10 GiB 可用空間

Do not create `.env` credentials. The deployment fixes its network boundary and generates credentials privately.
請勿在 `.env` 儲存認證；部署程式固定網路邊界並私下產生認證。

## Deploy / 部署

```bash
scripts/deploy.sh
```

The command is idempotent: it verifies supported tools and image account IDs, generates missing independent secrets, validates exact resource labels, starts the database before Odoo, verifies health, and installs the user unit. Repeating it preserves credentials and named volumes. A fresh PostgreSQL volume intentionally has no Odoo business database: open the local URL to use Odoo's database manager, then create or restore one. The generated config does not force the PostgreSQL `postgres` maintenance database as an Odoo database.
此命令具冪等性：檢查工具與映像帳號 ID、產生兩組獨立密碼、核對資源標籤、依序啟動並驗證服務，再安裝使用者單元；重複執行不會更換密碼或資料卷。全新的 PostgreSQL 資料卷刻意不含 Odoo 業務資料庫；請開啟本機網址，透過 Odoo 資料庫管理介面建立或還原資料庫。產生的設定不會強迫 Odoo 將 PostgreSQL 的 `postgres` 維護資料庫當成業務資料庫。

## Verify and local URL / 驗證與本機網址

```bash
scripts/verify.sh
bash tests/live-local.sh                 # includes a restart-persistence check
```

Odoo is reachable only at `http://127.0.0.1:18069`. PostgreSQL has no host port. The local live gate deploys and restarts services but never restores or purges data.
Odoo 僅可由 `http://127.0.0.1:18069` 存取；PostgreSQL 沒有主機對外連接埠。本機驗收會部署及重啟，但不會還原或清除資料。

## User systemd and lingering / 使用者 systemd 與 lingering

```bash
scripts/install-systemd.sh
systemctl --user status odoo18.service odoo18-health.timer
loginctl show-user "$USER" -p Linger
# An administrator may run once when Linger=no:
loginctl enable-linger "$USER"
```

The installer writes the main service plus a native-healthcheck timer and its triggered oneshot service under `$HOME/.config/systemd/user`. Only the main service and timer are enabled. Routine stop quiesces healthchecks and preserves volumes.
安裝程式會在使用者層級寫入主服務、原生健康檢查計時器及其觸發的 oneshot 服務；只啟用主服務與計時器。一般停止會先停止健康檢查並保留資料卷。

## Generated secrets and ownership / 產生的密碼與擁有權

`.runtime/secrets/postgres_password`, `.runtime/secrets/odoo_admin_password`, and `.runtime/config/odoo.conf` are mode `600`. In the rootless namespace their owners are respectively `999:999`, `0:0`, and `100:101`; the database volume is `999:999`, while the Odoo web volume and filestore are `100:101`. The tracked mode-`755`, namespace-`0:0` `scripts/odoo-healthcheck.py` is verified and mounted read-only. Its simple shell-safe native health command probes only `/web/health`, so it checks the HTTP process without creating a database and rejects HTTP errors. This avoids podman-compose 1.0.6 corrupting an inline Python command. The mandatory pinned-image probe must observe PostgreSQL `uid=999,gid=999` and Odoo `uid=100,gid=101`, otherwise rendering aborts fail-closed. Values never enter Compose environment values, process arguments, or routine logs. To intentionally reveal the Odoo database-manager password, use a private terminal and close its scrollback afterward:
三個執行期檔案權限皆為 `600`，在 rootless namespace 中依序屬於 `999:999`、`0:0`、`100:101`；資料庫資料卷為 `999:999`，Odoo web 資料卷及 filestore 為 `100:101`。版本庫內 mode `755`、namespace `0:0` 的 `scripts/odoo-healthcheck.py` 會經過驗證並以唯讀方式掛載；其簡單且 shell-safe 的原生健康命令只探測 `/web/health`，不建立資料庫即可驗證 HTTP 程序，並拒絕 HTTP 錯誤。此作法避免 podman-compose 1.0.6 破壞行內 Python 命令。固定映像的強制探測必須取得 PostgreSQL `uid=999,gid=999` 與 Odoo `uid=100,gid=101`，否則設定產生會以 fail-closed 中止。密碼不會出現在 Compose 環境、程序參數或一般日誌。如需刻意查看 Odoo 資料庫管理密碼，請在私人終端執行並清除捲動紀錄：

```bash
podman unshare cat .runtime/secrets/odoo_admin_password
```

## Tailnet-only remote gate / 僅限 tailnet 的遠端驗收

This repository does not create a public proxy. Configure a Headscale/Tailscale gateway separately to forward tailnet TCP 18069 to host loopback 18069, then run from a tailnet client:
本專案不建立公開反向代理。請另行設定 Headscale/Tailscale gateway，將 tailnet TCP 18069 轉送到主機 loopback 18069，再由 tailnet 用戶端執行：

```bash
ODOO_REMOTE_URL=http://<gateway-tailnet-name>:18069 bash tests/live-remote.sh
# For a reviewed gateway outside Tailscale's 100.64.0.0/10 or fd7a:115c:a1e0::/48 ranges:
ODOO_REMOTE_URL=http://gateway.example:18069 ODOO_REMOTE_PEER=192.0.2.10 bash tests/live-remote.sh
```

Every resolved and connected address must be in the approved Tailscale CGNAT/ULA ranges or equal the explicit peer IP. An absent URL exits 77 (SKIP), never PASS. Public Internet exposure is outside the security design.
未提供 URL 時以 77（SKIP）結束，不得視為 PASS；公開網際網路存取不在安全設計內。

## Backup / 備份

```bash
archive=$(scripts/backup.sh)
```

Backups are separate timestamped mode-`600` tar archives under mode-`700` `backups/`. They include a custom-format database dump, roles, Odoo volume, runtime config, admin recovery secret, digest metadata, and checksums. Backup preserves the prior web state, stopping web across the coordinated database/filestore capture and publishing the archive atomically only after validation.
備份是獨立時間戳記壓縮檔，檔案權限 `600`、目錄權限 `700`；包含資料庫、角色、Odoo 資料卷、設定、管理密碼復原副本、digest 中繼資料與校驗碼。備份會保留原有 web 狀態，在資料庫與 filestore 協調擷取期間停止 web，並僅在驗證後以原子方式發布封存檔。

## Restore / 還原

```bash
scripts/validate-backup.py backups/<archive>.tar
scripts/restore.sh --archive backups/<archive>.tar --confirm-restore odoo18
```

Restore privately stages and validates every member, type, size, path, and checksum before any service mutation, then creates a cold pre-restore backup. After role/database mutation begins, failure either restores and verifies the complete pre-state or leaves web stopped and prints the exact recovery command; mixed state is never restarted. The confirmation token prevents accidental destructive operation.
還原會先私下暫存並驗證所有成員、類型、大小、路徑及校驗碼，再建立冷備份。角色／資料庫開始變更後若失敗，只有完整舊狀態成功還原並驗證才會重啟，否則 web 保持停止並輸出精確復原命令，絕不啟動混合狀態。確認參數可防止誤操作。

## Safe removal and purge / 安全移除與清除

```bash
scripts/remove.sh                                      # preserve volumes/runtime/backups
scripts/remove.sh --purge-data --confirm-purge odoo18 # remove volumes/runtime; keep backups
```

Both forms validate exact stack/owner labels and refuse foreign same-named resources. They never perform broad pruning.
兩種操作都先核對 stack/owner 標籤並拒絕同名外部資源，且不會執行廣泛清理。

## Upgrades and digest rotation / 升級與 digest 輪替

Review a new upstream release and its multi-architecture digest, update both tag and digest in Compose plus constants/tests, then run unit, shell syntax, Compose render, local lifecycle, backup/restore, and remote gates. Never automate floating pulls.
審查上游新版本及 multi-architecture digest，同時更新 Compose、常數與測試中的 tag/digest，再執行單元測試、語法、Compose render、本機生命週期、備份還原及遠端驗收；不得自動追蹤浮動標籤。

## Troubleshooting / 疑難排解

- Run `scripts/verify.sh`; inspect only bounded logs with `podman logs --tail 30 odoo18-db` or `odoo18-web`.
- Account-ID mismatch means the pinned image changed unexpectedly: stop and review it; do not bypass ownership checks.
- A foreign-resource refusal requires an operator to identify/rename that resource; scripts will not adopt it.
- If boot startup fails, check user systemd and lingering. If port 18069 is occupied, free it; the port is intentionally not configurable.
- 執行驗證腳本並只查看有限行數日誌；映像帳號 ID 不符時應停止審查，不可略過；同名外部資源須人工辨識；開機失敗時檢查使用者 systemd/lingering；18069 被占用時須釋放，不能改用環境變數覆寫。

## Security boundary / 安全邊界

Only loopback Odoo is published; the database stays on the project bridge. Exact labels prevent cross-stack mutation. Secrets are independent, generated locally, private, ignored by Git, and never logged. SELinux bind mounts are read-only. Tailnet forwarding, host patching, physical security, and archive off-site encryption remain operator responsibilities.
只有 loopback Odoo 對主機開放，資料庫留在專案 bridge。精確標籤避免跨 stack 操作；獨立密碼於本機產生、受權限與 Git ignore 保護且不寫入日誌；SELinux bind mount 為唯讀。Tailnet 轉送、主機更新、實體安全及異地備份加密仍由維運者負責。
