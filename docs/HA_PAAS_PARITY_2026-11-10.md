# Odoo 18：HA add-on、PaaS 與 Podman 對照（2026-11-10）

## 來源與驗證界線

| 來源 | 已讀版本 | 性質 |
|---|---|---|
| [Woow_ha_odoo](https://github.com/WOOWTECH/Woow_ha_odoo) `main` | `f9d8ce9`，add-on `0.4.12` | GitHub main，已用 `ls-remote` 核對 |
| [Woow_podman_odoo](https://github.com/WOOWTECH/Woow_podman_odoo) `main` | `075fd00`，Quadlet 2.0.0 系列 | GitHub main，已 fetch |
| Gitea `woow-paas-charts` `origin/main` | `9df482f`，`woow-odoo` chart `0.2.26` | cluster1 的本機 Git 快照；工作樹在 Omnigent 分支，但 Odoo chart 與快照 main 無差異 |
| Gitea `paas-odoo-ci` `origin/main` | `5c41784` | cluster1 的本機 Git 快照；含 `Dockerfile.cloud`、`Dockerfile.official`、addon 清單 |
| Gitea `paas-app-bundle-cd` `origin/main` | `0bf0dbf` | cluster1 的本機 Git 快照；平台發布 overlay |

cluster1 的 Gitea 本機 relay `127.0.0.1:3301` 當時未運行，公開網域則被 Cloudflare Access 轉向登入頁。因此上述 Gitea SHA 是**可讀的快照**，尚不能視為 2026-11-10 即時遠端 main。cluster1 的 K3s 另有 Odoo 部署，但不是 `paas-system` 平台 chart 的線上驗證證據。正式 PaaS 的運行狀態仍須透過正確叢集／Access 查證。

## 已確認的差異

| 能力 | HA add-on | PaaS `woow-odoo` | 目前 Podman | 待辦 |
|---|---|---|---|---|
| Odoo 核心 | Odoo deb `18.0.20260930`；單容器內含 PG16 | `cloud-odoo` 官方 `odoo:18.0-20260926` lineage；PG17 | 預設官方 Odoo `18.0-20260817`；PG16 + pgvector 0.8.0；本機另以 PaaS cloud 候選映像及隔離 PG17.11 實測邏輯還原 | 尚未把正式 Quadlet 切到 PG17；絕不可把 PG16 資料卷直接交給 PG17 |
| 模組與相依 | `WOOWTECH/odoo-addons` 固定 `51856b0` 烤進映像（該 commit 的 `addons/` 有 7 個模組目錄）；另有 HA share | `paas-odoo-ci` 的 cloud 清單有 13 個模組、platform 清單有 40 個；image 內建清單選定的 addons、catalog 和 Python venv | 本分支支援 digest 釘版的預建模組映像、映像內 `/opt/woow/addons` 與本機唯讀 addons 目錄；尚未選定模組映像 | 選定 tenant／platform 模組集合，驗證映像依賴及實際安裝 |
| 首次資料庫 | `default_db` 可自動建立，`without_demo` 可控 | tenant bootstrap 建庫、擴充、初始化與驗證；platform 不自動初始化 | 本分支可選首次自動建庫、產生管理員登入 secret，重跑會核對 base/web 安裝狀態 | 仍缺 PaaS 的中斷後自動修復與 PG17 擴充初始化 |
| 升級守門 | Release 的升級測試與資料 hook；可設 `auto_update_module` | image digest marker、`-u all`／可選增量更新、事後模組驗證、次數限制 | 先備份並可回退 unit；`-u all` 是手動選項，沒有模組版本驗證 | 增加資料相容性與升級結果檢查；沿用現有備份邊界 |
| 網路入口 | HA Ingress + nginx 雙入口；Cloudflare 路徑限制與啟動自檢 | nginx sidecar；資料庫管理路徑 404；查詢字串不寫入一般 access log | 預設只綁 `127.0.0.1:18069`；可開 LAN，沒有入口代理；本分支已加 `werkzeug:WARNING` 抑制含查詢字串的 Odoo INFO 請求紀錄 | 依實際公開需求設 Podman gateway、路徑限制與日誌驗證 |
| 備份／還原 | Supervisor 冷備份，排除 cache、log、session | 定時 DB + filestore 備份、保留 daily/weekly、驗證、stage/switch 還原 | 手動冷備份所有 DB + filestore，校驗檔和回復失敗回退；本分支另有可選每日 systemd timer，僅輪替自動備份 | 尚未支援 PaaS 的不中斷 stage/switch、完整 manifest、獨立目的主機還原 |
| SMTP / PDF | SMTP 選項、CJK 字型與 wkhtmltopdf | tenant SMTP、Noto CJK TC fallback 和 PDF 驗證 | 沒有 SMTP 設定介面或專用 CJK 字型層 | 提供設定與實印 PDF 驗證 |
| 多租戶平台 | 非目標 | operator、平台 profile、獨立 cron、身分與 RBAC/NetworkPolicy | 單機 Odoo | 是否要實作 Podman 多租戶，待使用者確定；Kubernetes 專用機制應以相同效果而非原樣移植 |

### 先保留的安全邊界

- Podman 密碼目前由 `podman secret` 管，DB 沒有對主機公開埠；新增功能不能把秘密放到 `.env`、映像層、argv 或 Git。
- 舊 Podman Quadlet 單元仍存在且服務停止；資料卷及密鑰皆未發現。另有約 56 MB 的舊遷移備份，尚未檢查其中資料內容；不得擅自當作目前生產資料。
- 首輪建置使用隔離的全新測試資料，不直接改 PaaS 或 HA 生產資料。正式資料搬運要先指定來源 DB、filestore、addons、目的主機及可接受的停機窗口。

## 實作與驗收順序

1. 選定單機／多租戶範圍與資料來源；記錄 Odoo、PostgreSQL、addons 的實際目標版本。
2. 在 Podman 建立隔離測試環境，驗證初始化、模組清單與 Python 依賴、登入、websocket、PDF 字型及 SMTP。
3. 驗證入口限制：公開路徑的 `/web/database/*` 無法存取，重設密碼 token 不出現在 access log。
4. 實測備份、空主機還原、升級及模組資料保留，留下可核對的版本／健康證據。
5. 取得正確的 PaaS 叢集與 Gitea 即時 main 後重做差異檢查；通過後推送 Podman 分支並依 GitHub CI 結果合併。

## 本機實測（2026-11-10，測試資料庫）

- 原本 Odoo Quadlet 單元仍 active/exited，但 Podman 網路和兩個 volume 已不存在；首次安裝因 `network not found` 失敗。本分支加入資源核對後重跑成功。這個修正有專門的回歸測試。
- 先以官方 `odoo:18.0-20260926@sha256:eea33387…` + PG16/pgvector 0.8.0 建立空白實例；健康端點 200、登入頁 200，完整版 smoke 16/16 通過。`scripts/init-db.py` 建立 `odoo_parity_20261110`，管理員可透過 XML-RPC 驗證。
- 寫入 `res.partner` 和二進位 `ir.attachment`，冷備份、修改原紀錄並刪除附件後執行還原。第一次還原因角色 SQL 含 `\gexec`，與 PG dump 的 `\restrict` 衝突而失敗；本分支改成純 SQL 冪等建立角色，第二次完整還原成功，聯絡人與 filestore 內容均恢復，快速 smoke 8/8 通過。
- 用 Gitea `paas-odoo-ci` 快照 `5c41784` 的 `Dockerfile.cloud` 在本機建出候選映像 `localhost/woow-odoo-cloud-parity:20261110`，本機 digest `sha256:af2c232f…`。原來源的 `verify-cloud-image.sh` 通過：13 個模組、catalog、Python 依賴、uid/gid 100:101 及 wkhtmltopdf 繁中 Noto CJK TC 內嵌字型。
- Podman `scripts/upgrade.sh --update-modules` 切至該候選映像成功，完整版 smoke 16/16 通過，原資料與附件可讀；13 個 cloud 模組在 Odoo 中可見且未自動安裝。另實際安裝 `mail_fetchmail_durable`，資料庫顯示 `installed 18.0.1.0.1`，登入與原資料仍正常。
- 可選的安裝器 bootstrap 另外建立 `odoo_auto_20261110`；其管理員登入驗證成功，`base`／`web` 均為 installed。重跑安裝器只報告既有庫已初始化，沒有重做資料。角色 dump 的 `\restrict`／純 SQL 轉換也以實際 PostgreSQL 建立一個暫時角色並重放兩次，兩次都成功，測後已刪除該角色。
- 此映像只在本機，未推到 registry。PaaS source 的 `requirements-cloud.txt` 未鎖定全部 pip 版本，本次建置解析的 `pycryptodomex`、`websockets` 等版本以這顆本機 digest 為準。尚未驗證 PaaS 正式叢集或 HA ingress，也未演練 PG16→PG17 資料搬運與平台多租戶能力。
- 另增加可選 `odoo18-backup.timer`：台北時間 02:00 加最多三小時延遲，每日執行 `backup.sh --automated`。驗證封存後只輪替 `odoo18-auto-*.tar`；保留最新七份及最近四個 ISO 週的首份成功備份。先核對所有自動封存與 sidecar 的 SHA256，有一份壞檔就停止整批清理。手動、升級前與還原前封存檔不受輪替影響；uninstall 會停用計時器。
- 本機以 `backup.sh --automated` 與 `systemctl --user start odoo18-backup.service` 各實際建立一份約 3.4 MB 封存檔，後者 `Result=success`；`validate-backup.py` 對後者驗證通過，內含兩個測試 DB 的 custom-format dump，沒有 `secrets/`。`odoo18-backup.timer` 為 enabled，下一次執行排程可由 `systemctl --user list-timers` 查看；快速 smoke 8/8 通過。留存刪除行為另以 15 個造樣自動封存檔測過，包含校驗錯誤時不刪任何檔案。

## PG16 → PG17 隔離還原實測

- 先在現有 PG16 的測試庫 `odoo_parity_20261110` 啟用 `vector 0.8.0` 與 `pg_trgm 1.6`，再次執行冷備份並驗證封存檔。沒有直接掛載或修改 PG16 資料卷。
- 依 cluster1 可讀的 PaaS `paas-odoo-ci` `Dockerfile.postgres`（快照 `5c41784`）在本機建置 PG17.11 隔離候選映像 `localhost/woow-paas-postgres-parity:17.11`，image ID `fa598fee842f…`。官方底圖使用 Dockerfile 指定的 digest `sha256:639ab7ce…`，初始化開啟 data checksums（`pg_controldata` 顯示 1）。建置當天 PGDG 套件庫給的是 pgvector **0.8.7**，而 chart 快照的 PaaS 發布映像是 **0.8.6**；此候選映像**不是** PaaS registry 的相同 digest。
- 隔離 Podman network／DB volume／web volume 名為 `odoo-pg17-parity-*`；PG17 DB 無主機公開埠。用封存檔的 roles dump 經純 SQL 冪等轉換後建角色，以 `pg_restore --single-transaction --exit-on-error` 還原測試庫，再複製 filestore 到新 web volume。來源與目標資料庫 locale 均為 `en_US.utf8`。目標擴充為 `vector 0.8.7`、`pg_trgm 1.6`。
- 用本機 PaaS cloud Odoo 候選映像在 `127.0.0.1:28069` 起隔離 web，`/web/health` 200、指定資料庫的 `/web/login` 200。`tests/live-api.py verify` 以原管理員登入成功，聯絡人紀錄、二進位附件和 filestore 內容完整；`mail_fetchmail_durable` 仍為 `installed 18.0.1.0.1`。再於隔離 PG17 將 `odoo` 角色降為 `NOSUPERUSER NOCREATEDB NOCREATEROLE`，同一組登入與資料讀取驗證仍通過。
- 這是**測試資料的邏輯還原驗收**，目前正式 Quadlet 仍在 PG16，未做正式來源的停機切換、全量模組升級或 PaaS 叢集相同 digest 的驗收。PG16 來源角色原本是 superuser，PaaS 目標設計為非 superuser；正式遷移需先確定資料來源、目標映像與擴充版本、停機窗口、回退方式。驗收後已停止並移除隔離測試的容器、volume、network 與本機 PG17 候選映像，以釋放主機空間；冷備份與正式 PG16 實例均保留。
