# Deployment acceptance record / 部署驗收紀錄

This is an evidence template. Record only observed results; never record credentials, archive contents, or tailnet authentication material.
本檔僅為證據範本；只填寫實際結果，絕不可記錄密碼、備份內容或 tailnet 認證資料。

## Prerequisites / 前置需求
- Date (UTC) / 日期：`2026-08-27T17:06:33Z`
- Operator / 操作者：`repository implementation agent`
- Commit：`a717843` (implementation tip before this evidence update)
- Host and OS / 主機與系統：`repository test environment; container runtime unavailable`
- Podman version：`NOT RUN — executable unavailable`
- podman-compose version：`NOT RUN — executable unavailable`
- Image IDs / 映像 ID：`NOT RUN — executable unavailable`
- Registry digest verification / registry digest 驗證：`PASS — Docker Registry v2 HEAD returned odoo sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67 and pgvector sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9`

## Static acceptance / 靜態驗收
- `bash tests/run.sh`：`PASS — 36 tests`
- Shell/Python syntax and `git diff --check` / Shell、Python 語法及 diff 檢查：`PASS`
- Secret-pattern scan / 密碼樣式掃描：`PASS — no matches outside plans`
- Compose render / Compose render：`NOT RUN — podman-compose unavailable`

## Deploy / 部署
- First deploy / 首次部署：`NOT RUN — Podman unavailable; no remote host was mutated`
- Idempotent second deploy / 第二次冪等部署：`NOT RUN — Podman unavailable`

## Verify and local URL / 驗證與本機網址
- `scripts/verify.sh`：`NOT RUN — Podman unavailable`
- `bash tests/live-local.sh`：`NOT RUN — Podman unavailable`
- Observed local URL / 實測本機網址：`http://127.0.0.1:18069` (result: `NOT RUN`)

## User systemd and lingering / 使用者 systemd 與 lingering
- Unit status / 單元狀態：`NOT RUN`
- Linger status / linger 狀態：`NOT RUN`

## Tailnet-only remote gate / 僅限 tailnet 遠端驗收
- Result / 結果：`SKIP (exit 77) — ODOO_REMOTE_URL was intentionally unset; no remote gateway/client was used during repository-only implementation`
- Command origin and gateway / 命令來源與 gateway：`<not run>`

## Backup / 備份
- Archive mode/validation / 備份權限與驗證：`NOT RUN`

## Restore / 還原
- Backup/restore drill and post-restore verification / 備份還原演練與驗證：`NOT RUN`

## Safe removal and purge / 安全移除與清除
- Default removal and data preservation / 一般移除與資料保留：`NOT RUN`
- Purge (only if intentionally tested) / 清除（僅限刻意測試）：`NOT RUN`

## Upgrades and digest rotation / 升級與 digest 輪替
- No rotation performed; approved release/digest pins remain in Compose. / 未執行輪替；Compose 保持核准的 release/digest。

## Troubleshooting / 疑難排解
- Observations / 觀察：`none recorded`

## Security boundary / 安全邊界
- Loopback-only Odoo, private database, exact labels, runtime ownership, and secret-leak checks / loopback Odoo、私人資料庫、精確標籤、執行期擁有權及密碼外洩檢查：`NOT RUN`
