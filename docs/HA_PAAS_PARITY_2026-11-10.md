# Odoo 18 全新 Podman 建置與 HA／PaaS 能力對照（2026-11-10）

## 目標與來源

本次只建立**全新** Odoo 測試實例與資料庫；不搬運 HA、PaaS 或舊 Podman 資料。使用者已選定 **PaaS tenant cloud** 作為對齊目標；PaaS platform 控制面不在本次範圍。HA Supervisor Ingress 的特殊路徑以對外效果比較，不能宣稱 Podman 原樣具備。

| 來源 | 核對版本 | 證據界線 |
|---|---|---|
| [HA add-on](https://github.com/WOOWTECH/Woow_ha_odoo) | GitHub main `f9d8ce9`；add-on 0.4.12；Odoo deb 18.0.20260930 | 原始碼與設定已讀；本次沒有在 HA Supervisor 上跑 Ingress 驗收 |
| PaaS `woow-paas-charts` | cluster1 本機 main 快照 `9df482f`；chart 0.2.26 | Gitea 即時 main 因 Cloudflare Access／本機 relay 未能再核對；不能視為即時正式環境 |
| PaaS `paas-odoo-ci` | cluster1 本機 main 快照 `5c41784` | `Dockerfile.cloud`、`Dockerfile.official`、模組清單與 PDF 驗證腳本已讀 |
| PaaS `woow_paas_platform` 租戶範本 | cluster1 本機快照 `af0352e`，`cloud_app_odoo` | 釘 chart `0.2.26`、cloud-odoo `20261101.1152@sha256:5a0c0f9b…`、paas-postgres `17.11-20260928.1549@sha256:dbd1fed8…`；此範本比 chart 預設更能代表租戶選用版本 |
| PaaS `paas-app-bundle-cd` | cluster1 本機 main 快照 `0bf0dbf` | 平台 overlay 已讀；沒有證明正式 PaaS 正在執行這些版本 |
| [Podman Odoo](https://github.com/WOOWTECH/Woow_podman_odoo) | main 基線 `075fd00`；本分支 `feat/odoo-ha-paas-parity` | 下列實測在 `woowtechopenclaw` 的 rootless Podman 完成 |

cluster1 的 K3s 有多個 Odoo deployment，但查到的 `paas-test-odoo` 是測試 Odoo 18，`tenant-test` 是 Odoo 18 + postgres:16；它們不能代表上述租戶範本的正式部署。以下 PaaS 欄位是可讀的 chart／CI／範本**設計與原始碼**，不是正式線上行為驗收。租戶映像位於 JCR；本機讀取 registry 得 403，尚未取得該映像的 layer 或 digest 驗證。

## 功能與能力對照

| 能力 | HA add-on | PaaS chart／image | 新 Podman 實測及差距 |
|---|---|---|---|
| Odoo 核心與中文 | Odoo 18.0.20260930、繁中、CJK PDF | cloud 官方 Odoo 18.0-20260926 lineage、Noto CJK TC | 目前採 PaaS cloud lineage 的本機組合映像；繁中管理員登入、聯絡人、附件實測；原 PaaS cloud PDF 字型驗證腳本通過。與 HA 的 deb 日期**不同** |
| HA 範例 addons | 公開 `odoo-addons` 固定 `51856b0` 的 7 顆 | 不屬於 cloud 清單 | 7/7 加在組合映像的獨立目錄，7/7 在新資料庫可見；`awesome_clicker` 實際安裝並保留於備份／還原 |
| PaaS tenant addons | 不同模組線 | 已選租戶範本釘住 `cloud-odoo:20261101.1152`；範本註解指出當時 7 顆候選 addon，由管理員自行啟用。CI main 快照較新，清單已增至 13 顆 | 目前本機組合映像來自**較新的 CI main**，13/13 可見、`mail_fetchmail_durable` 曾實際安裝；**不能宣稱等於已釘的 20261101.1152**。該 tag 的 blob 未在 cluster1 的 partial clone，registry 又回 403，精確模組清單需從原 image／tag 再盤點 |
| 資料庫 | 同容器 PG16 | 租戶範本釘 PG17.11 + pgvector 0.8.6、非管理員 Odoo DB 角色；預設 DB 名 `odoo` | 現場仍是 PG16 + pgvector 0.8.0；已加入完整 digest 釘版設定與 `PG_VERSION` 防誤用，尚未能從 JCR 拉下精確 PG17 映像，因此未宣稱版本對齊 |
| 首次建庫 | `default_db`、語言與 demo 控制 | tenant bootstrap、extension、初始化及事後驗證 | tenant 模式把 `db_name` 固定為 `odoo`，建庫後查 C 排序規則、建立 `pg_trgm`／`vector`，並自動關閉資料庫管理入口；管理員密碼進 Podman secret。尚無 PaaS 的角色隔離及完整中斷修復 |
| Web 與即時通道 | HA Ingress 和對外入口，含大量 token 路徑改寫 | nginx sidecar、拒絕 `/web/database/*`、WebSocket、保護日誌；租戶範本 `workers=0`、`maxCronThreads=2`、`dbMaxconn=8` | gateway、HSTS、登入表單、cookie 和日誌已測；目前測試機開 2 workers，**尚未切換到租戶範本的 0**，真實即時事件與 HA Ingress 路徑尚未測 |
| SMTP | 可設 SMTP | tenant SMTP | 設定與密碼分別由環境設定／Podman secret 管；本機 SMTP sink 實際收到 Odoo 發出的信。外部服務 TLS／帳號授權尚未測 |
| 備份與還原 | Supervisor 冷備份 | 定時 DB + filestore、保留規則、stage/switch 線上還原 | 全庫 + filestore 冷備份、校驗、定時器、輪替及同檔還原實測；還原後入口恢復、資料可讀。沒有 PaaS 的不中斷 stage/switch 或遠端目的地 |
| 升級 | 版本 gate、資料 hook | digest marker、增量或全量模組更新及驗證 | 映像釘 digest、升級前備份與 unit 快照、`-u all` 在 3 庫成功；失敗可回退 unit，資料則需由封存檔還原。缺自動版本 gate 與完整模組驗證 |

HA 的 `woow_base_url_guard`、`woow_visitor_url` 是為 Supervisor Ingress 的 canonical URL／訪客來源修正，且以 `server_wide_modules` 載入。目前 Podman 入口沒有 HA Ingress token 路徑，兩顆模組尚未移入組合映像；這不等同於驗證 HA Ingress 的所有頁面／網站功能。

## 本機實測紀錄

- 新建 `odoo_fresh_20261110`，以獨立的管理員 secret 從 `http://127.0.0.1:18080` XML-RPC 登入，建立聯絡人及二進位附件；更新映像後、還原後均讀回原值。所有資料都是測試資料。
- 組合映像 `localhost/woow-odoo-ha-cloud-parity@sha256:f2ba1a31652b41969033d32fcef064a1458b1897c20433c439b559dfba11c0b0` 建自本機 PaaS cloud 候選映像 `sha256:af2c232f…` 及公開 HA 7 顆模組；這兩顆映像只存在本機，未推到 registry。
- `scripts/upgrade.sh --update-modules` 在三個測試庫完成，最後安裝與完整 smoke **25/25**。新資料庫 13 顆 cloud 與 7 顆 HA 模組都可見，`awesome_clicker` 已安裝。Odoo 的 `werkzeug` 和 `longpolling` INFO 查詢紀錄都抑制 token。
- 發現本機 HTTP gateway 原本會把 session cookie 強制設為 `Secure`；修正為 HTTP 可登入、HTTPS 維持 `Secure`，兩種 cookie 旗標均由 smoke 驗證。另用保留 cookie／CSRF 的網頁表單實際登入，`/web/session/get_session_info` 回傳有效使用者 ID。
- SMTP 以同 Podman 網路的暫時 sink 收到 From、To、Subject 和本文，測試後已停止並移除 sink；未寄外部信。Noto CJK TC PDF 驗證沿用原 cloud 映像測試的同一底層。
- `scripts/backup.sh` 建立約 4.8 MB 校驗封存，停止 Odoo 時保留 DB，再啟動 Odoo 及 nginx gateway。以同檔 `scripts/restore.sh` 還原 3 庫，入口健康與限制快速 smoke **15/15**，管理員、聯絡人及附件再驗通過。此前另已測過修改資料後還原原值。
- 定時備份 service 曾實際執行成功，timer enabled；輪替測試覆蓋最近 7 份與最近 4 個 ISO 週首份、壞檔時拒絕刪除。未做遠端備份目的地測試。
- `tests/dryrun.sh` 現含租戶釘版配置的 Quadlet 渲染；`tests/run.sh` 15 個 Python 測試與資源重建回歸測試通過。PG17 映像對 PG16 既有資料卷的拒絕在本機測過；沒有讓 PG17 啟動該卷。

## 使用方式與剩餘驗收

本分支的預設映像仍為公開 Odoo 18 + PG16。已新增 `config/profiles/tenant-cloud.profile`，固定租戶範本的 **cloud-odoo `20261101.1152`、chart `0.2.26` 對應設定及 PG17.11 映像 digest**；這是可重現的安裝輸入，還不是成功部署。使用者需先授權 JCR 讀取，並在**新的空資料卷／獨立實例**套用；既有 PG16 測試卷不能原地改成 PG17。若另要 HA 7 顆範例模組，再以已授權的 cloud image 當底層執行 `scripts/build-ha-cloud-image.sh`，得到另外一顆組合映像。主機目前跑的是較新 13 顆候選映像，只綁回圈位址，沒有正式對外流量切換。

要宣稱與**選定的 tenant cloud** 同能力，還需取得釘版映像並盤點其實際 addon、在全新 PG17 空資料卷上實測 tenant bootstrap 與 `list_db=False`／`dbfilter=^odoo$`，補齊非管理員 Odoo DB 角色、升級 gate、備份／還原契約與公開入口實測；外部 SMTP TLS 亦未驗。PaaS platform 的 40 顆模組與控制面不列入這次驗收。以上均不涉及搬運既有資料。
