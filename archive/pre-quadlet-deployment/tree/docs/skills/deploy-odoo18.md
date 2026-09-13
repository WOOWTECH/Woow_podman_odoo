# Secure Odoo 18 runbook / 安全 Odoo 18 操作手冊

## Prerequisites / 前置需求
Use a non-root Linux account with Podman 4.9.3, podman-compose 1.0.6, user systemd, Python 3, OpenSSL, and curl. 請使用一般 Linux 帳號及上述固定版本工具。

## Deploy / 部署
Run `scripts/deploy.sh`; reruns preserve credentials and data. On a fresh volume, open the local URL and create or restore an Odoo database; configuration does not force the empty `postgres` maintenance database. 執行部署腳本；重複執行保留密碼及資料。全新資料卷請開啟本機網址建立或還原 Odoo 資料庫；設定不會強迫使用空的 `postgres` 維護資料庫。

## Verify and local URL / 驗證與本機網址
Run `scripts/verify.sh` and open `http://127.0.0.1:18069`. PostgreSQL is not mapped to the host. The read-only standalone health helper probes `/web/health` without initializing a database and fails on HTTP errors. 執行驗證並使用 loopback 網址；資料庫不映射至主機。唯讀的獨立健康檢查程式會探測 `/web/health`，不初始化資料庫，並在 HTTP 錯誤時失敗。

## User systemd and lingering / 使用者 systemd 與 lingering
Run `scripts/install-systemd.sh`, check `systemctl --user status odoo18.service odoo18-health.timer`, and ask an administrator to run `loginctl enable-linger "$USER"` once if needed. The timer drives both containers' native healthchecks; its triggered oneshot is not enabled directly. 安裝使用者單元並檢查主服務及健康檢查計時器；觸發的 oneshot 不會直接啟用，並視需要由管理員啟用 lingering。

## Tailnet-only remote gate / 僅限 tailnet 遠端驗收
After separate gateway configuration, run `ODOO_REMOTE_URL=http://<gateway-tailnet-name>:18069 bash tests/live-remote.sh`. Missing infrastructure is SKIP, not PASS. gateway 須另行設定；無環境時記錄 SKIP。

## Backup / 備份
Run `scripts/backup.sh`; every private timestamped archive is checksum validated. 執行備份腳本；每份私人時間戳記檔都經校驗。

## Restore / 還原
Run `scripts/restore.sh --archive backups/<archive>.tar --confirm-restore odoo18`. Validation and a pre-restore backup precede mutation. 使用明確確認參數；先驗證並建立還原前備份。

## Safe removal and purge / 安全移除與清除
`scripts/remove.sh` preserves data. `scripts/remove.sh --purge-data --confirm-purge odoo18` removes exact labeled data/runtime but preserves backups. 一般移除保留資料；雙重確認才清除資料且仍保留備份。

## Upgrades and digest rotation / 升級與 digest 輪替
Review and change the release tag and digest together, then run the complete static/local/remote matrix. Never use a floating pull. 同時審查更新 tag 與 digest，並執行完整驗收。

## Troubleshooting / 疑難排解
Use bounded `podman logs --tail 30`, never echo secrets, and never bypass account-ID or resource-label failures. 使用有限日誌，不輸出密碼，亦不略過帳號 ID 或標籤檢查。

## Security boundary / 安全邊界
Runtime secrets are independent mode-`600` files with exact namespace ownership. Odoo is loopback-only; remote access requires the separately managed Headscale/Tailscale gateway. 執行期密碼互相獨立且具精確權限；Odoo 僅限 loopback，遠端須經獨立管理的 tailnet gateway。

See `README.md` for commands, ownership details, archive behavior, and operator responsibilities. 完整命令、擁有權、備份行為與責任界線請見 README。
