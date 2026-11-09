# Odoo 18 全新 Podman 建置與 HA／PaaS 能力對照（2026-11-10）

## 目標與來源

本次只建立**全新** Odoo 測試實例與資料庫；不搬運 HA、PaaS 或舊 Podman 資料。對照的是使用者可取得的 Odoo 功能及運維能力。HA Supervisor Ingress、Kubernetes RBAC 等平台專屬機制，以對外效果比較，不能宣稱 Podman 原樣具備。

| 來源 | 核對版本 | 證據界線 |
|---|---|---|
| [HA add-on](https://github.com/WOOWTECH/Woow_ha_odoo) | GitHub main `f9d8ce9`；add-on 0.4.12；Odoo deb 18.0.20260930 | 原始碼與設定已讀；本次沒有在 HA Supervisor 上跑 Ingress 驗收 |
| PaaS `woow-paas-charts` | cluster1 本機 main 快照 `9df482f`；chart 0.2.26 | Gitea 即時 main 因 Cloudflare Access／本機 relay 未能再核對；不能視為即時正式環境 |
| PaaS `paas-odoo-ci` | cluster1 本機 main 快照 `5c41784` | `Dockerfile.cloud`、`Dockerfile.official`、模組清單與 PDF 驗證腳本已讀 |
| PaaS `paas-app-bundle-cd` | cluster1 本機 main 快照 `0bf0dbf` | 平台 overlay 已讀；沒有證明正式 PaaS 正在執行這些版本 |
| [Podman Odoo](https://github.com/WOOWTECH/Woow_podman_odoo) | main 基線 `075fd00`；本分支 `feat/odoo-ha-paas-parity` | 下列實測在 `woowtechopenclaw` 的 rootless Podman 完成 |

cluster1 的 K3s 有多個 Odoo deployment，但查到的 `paas-test-odoo` 是測試 Odoo 18，`tenant-test` 是 Odoo 18 + postgres:16；它們不能代表 `woow-odoo` chart 0.2.26 的正式平台 profile。以下 PaaS 欄位是可讀的 chart／CI **設計與原始碼**，不是正式線上行為驗收。

## 功能與能力對照

| 能力 | HA add-on | PaaS chart／image | 新 Podman 實測及差距 |
|---|---|---|---|
| Odoo 核心與中文 | Odoo 18.0.20260930、繁中、CJK PDF | cloud 官方 Odoo 18.0-20260926 lineage、Noto CJK TC | 目前採 PaaS cloud lineage 的本機組合映像；繁中管理員登入、聯絡人、附件實測；原 PaaS cloud PDF 字型驗證腳本通過。與 HA 的 deb 日期**不同** |
| HA 範例 addons | 公開 `odoo-addons` 固定 `51856b0` 的 7 顆 | 不屬於 cloud 清單 | 7/7 加在組合映像的獨立目錄，7/7 在新資料庫可見；`awesome_clicker` 實際安裝並保留於備份／還原 |
| PaaS tenant addons | 不同模組線 | `cloud-addons.list` 有 13 顆，管理員自行啟用 | 13/13 在新資料庫可見；原 cloud 映像的 catalog、相依和 Python 環境驗證通過；此前在另一個測試庫實際安裝 `mail_fetchmail_durable` |
| PaaS platform addons | 非 HA add-on 範圍 | `addons/` 約 40 顆、外部 `woow_paas_platform`、operator／RBAC 等 | **未對齊**。目前組合映像是 tenant cloud profile，沒有外部平台模組與 Kubernetes 控制面；不能把 13 顆 cloud 說成 40 顆平台能力 |
| 資料庫 | 同容器 PG16 | chart 指向 PG17.11 + pgvector 0.8.6、非管理員角色及分工 | 現場 PG16 + pgvector 0.8.0；可選釘版 PG17 映像，安裝器以 `PG_VERSION` 拒絕把 PG16 資料卷交給 PG17。隔離 PG17.11 邏輯還原已測，但不是全新 PG17 正式部署；角色／版本尚未對齊 |
| 首次建庫 | `default_db`、語言與 demo 控制 | tenant bootstrap、extension、初始化及事後驗證 | `init-db.py` 與可選首次自動建庫可建立全新繁中庫；管理員密碼進 Podman secret，重跑只驗證 base/web 狀態。尚無 PaaS 的完整中斷修復／extension bootstrap |
| Web 與即時通道 | HA Ingress 和對外入口，含大量 token 路徑改寫 | nginx sidecar、拒絕 `/web/database/*`、WebSocket、保護日誌 | 可選 nginx gateway 實際代理健康與 XML-RPC，資料庫管理路徑 404，HSTS 和查詢 token 日誌抑制已測；2 個 Odoo workers、8072 WebSocket 轉送已到達。**尚未測真實網頁事件、HA Ingress token 路徑或瀏覽器互動** |
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
- `tests/dryrun.sh` 7 組 Quadlet 渲染通過；`tests/run.sh` 15 個 Python 測試與資源重建回歸測試通過。PG17 映像對 PG16 既有資料卷的拒絕在本機測過；沒有讓 PG17 啟動該卷。

## 使用方式與剩餘驗收

本分支的預設映像仍為公開 Odoo 18 + PG16；**單純安裝本 repo 不會得到上述 20 顆模組**。使用者需要可授權的 PaaS cloud 映像、固定版本的公開 HA addons checkout，執行 `scripts/build-ha-cloud-image.sh`，把產生的 digest 設為 `WOOW_ODOO_IMAGE`，再執行 `scripts/install.sh`。主機上的測試部署已如此設定，但只綁回圈位址，沒有正式對外流量切換。

若要宣稱與 PaaS platform 完全同能力，還需取得 `woow_paas_platform` 來源／映像、建置和驗證 40 顆平台 addons、獨立排程與權限模型；若只需 tenant cloud，仍須取得正式 Gitea main 與正式叢集的版本及行為證據。另需在全新 PG17 空資料卷上完成 Odoo／pgvector 安裝、外部 SMTP TLS、真實 WebSocket／瀏覽器路徑與公開代理層驗收。以上均不涉及搬運既有資料。
