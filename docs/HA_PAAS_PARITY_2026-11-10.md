# Odoo 18 全新 Podman 建置與 HA／PaaS 能力對照（2026-11-10）

## 目標與來源

本次建立**全新** Odoo 實例與資料庫；未搬運 HA、PaaS 或舊 Podman 資料。目標是 **PaaS tenant cloud**，並加入公開 HA 的 7 個範例模組；PaaS platform 控制面不在本次範圍。HA Supervisor Ingress 的特殊路徑尚未在 Podman 驗收。

| 來源 | 核對版本 | 證據界線 |
|---|---|---|
| [HA add-on](https://github.com/WOOWTECH/Woow_ha_odoo) | GitHub main `f9d8ce9`；add-on 0.4.12；Odoo deb 18.0.20260930 | 原始碼與設定已讀；本次沒有在 HA Supervisor 上跑 Ingress 驗收 |
| PaaS `woow-paas-charts` | cluster1 本機 main 快照 `9df482f`；chart 0.2.26 | Gitea 即時 main 因 Cloudflare Access／本機 relay 未能再核對；不能視為即時正式環境 |
| PaaS `paas-odoo-ci` | cluster1 本機 main 快照 `5c41784` | `Dockerfile.cloud`、`Dockerfile.official`、模組清單與 PDF 驗證腳本已讀 |
| PaaS `woow_paas_platform` 租戶範本 | cluster1 本機快照 `af0352e`，`cloud_app_odoo` | 釘 chart `0.2.26`、cloud-odoo `20261101.1152@sha256:5a0c0f9b…`、paas-postgres `17.11-20260928.1549@sha256:dbd1fed8…`；此範本比 chart 預設更能代表租戶選用版本 |
| PaaS `paas-app-bundle-cd` | cluster1 本機 main 快照 `0bf0dbf` | 平台 overlay 已讀；沒有證明正式 PaaS 正在執行這些版本 |
| [Podman Odoo](https://github.com/WOOWTECH/Woow_podman_odoo) | main 基線 `075fd00`；本分支 `feat/odoo-ha-paas-parity` | 下列實測在 `woowtechopenclaw` 的 rootless Podman 完成 |

cluster1 的 PaaS K3s 已核對內部 JFrog Service、現有 imagePullSecret 與正在運作的 PG17.11 digest；指定 cloud Odoo digest 未見於當時的 Pod spec，不能據此宣稱 PaaS 正在運作該 cloud 版本。公開 `jcr-prod.woowtech.io` 入口對本機回 Cloudflare Access 403。透過 cluster1 的 SSH 與 Kubernetes 內部 JCR 服務，用既有 pull secret 只在記憶體／短期 0600 授權檔中鑑權，兩顆映像的 registry manifest 回 200 且 digest 與租戶範本一致；圖層已匯入這台 Podman 主機，授權檔已刪除。PaaS chart／CI／範本來源仍是本機快照，尚未重驗 Gitea 即時 main。

## 功能與能力對照

| 能力 | HA add-on | PaaS chart／image | 新 Podman 實測及差距 |
|---|---|---|---|
| Odoo 核心與中文 | Odoo 18.0.20260930、繁中、CJK PDF | `cloud-odoo:20261101.1152`、Noto CJK TC | 本機以完全相同 digest 的 cloud 映像為底；繁中管理員網頁登入、聯絡人與附件實測，字型 `fc-match` 命中 Noto Sans CJK TC。HA 的 deb 日期不同；此版本未重跑實際 PDF 產生 |
| HA 範例 addons | 公開 `odoo-addons` 固定 `51856b0` 的 7 顆 | 不屬於 cloud 清單 | 7/7 加在衍生映像的獨立目錄並在新資料庫可見；`awesome_clicker` 實際安裝，備份還原後仍為 installed |
| PaaS tenant addons | 不同模組線 | 租戶範本釘住 `cloud-odoo:20261101.1152`，管理員自行啟用；較新 CI main 的 13 顆不是此版 | 從指定 digest 的原映像盤點出 7 顆，7/7 在新資料庫可見；`mail_fetchmail_durable` 實際安裝，還原後仍為 installed |
| 資料庫 | 同容器 PG16 | PG17.11 + pgvector 0.8.6、非管理員 Odoo DB 角色；預設 DB 名 `odoo` | 相同 PG17.11 digest；因舊卷的 Odoo 是不可降權的 bootstrap 超級使用者（OID 10），已重建至 `postgres` 為初始超級使用者的新卷。`odoo` 為非 superuser、不可建庫／建角色，資料校驗、C collation、pg_trgm／vector 均通過；Odoo 容器沒有管理員密鑰 |
| 首次建庫 | `default_db`、語言與 demo 控制 | tenant bootstrap、extension、初始化及事後驗證 | 現行 tenant 安裝先由 `postgres` 建 C collation 資料庫與擴充套件，再由受限 `odoo` 以一次性 CLI 執行 `-i base`，於 web 開放前設定管理員 secret；獨立探針庫已實測 base/web、登入 Email。實際租戶原先由 `init-db.py` 初建，之後已遷移至受限角色且真實登入通過；資料庫管理入口關閉、`dbfilter=^odoo$` |
| Web 與即時通道 | HA Ingress 和對外入口，含 token 路徑改寫 | nginx sidecar、拒絕 `/web/database/*`、WebSocket、保護日誌；`workers=0`、`maxCronThreads=2`、`dbMaxconn=8` | 本機已用租戶範本的 0 workers／2 cron／8 連線；gateway 健康、資料庫管理 404、HTTP 表單登入與 session、cookie 和日誌檢查通過。Cloudflare Access 對未登入外網請求回 302 至登入網域；即時事件、Access 登入後完整 Odoo 頁面與 HA Ingress 路徑尚未實測 |
| SMTP | 可設 SMTP | tenant SMTP | 密碼存 Podman secret；先前候選映像已由 SMTP sink 收信。新 tenant 實例尚未配置外部 SMTP，TLS／帳號授權未測 |
| 備份與還原 | Supervisor 冷備份 | 定時 DB + filestore、保留規則、stage/switch 線上還原 | 受限 `odoo` 角色可建立校驗封存；`restore-online.sh` 已在線上預備、驗證模組與 18 個附件、切換、回退和丟棄旁路資料。切換／回退各快速 smoke 16/16；切換期間需短暫停止 web／gateway。遠端備份目的地尚未提供 |
| 升級 | 版本 gate、資料 hook | digest marker、增量或全量模組更新及驗證 | `upgrade-gate.sh` 已在隔離 DB 用另一顆測試映像實際執行 `-u all`、模組完整核對後寫 done。缺少 addon 來源在寫 attempt 前拒絕；同 digest 三次失敗及 core 降版均以 78 拒絕。正式映像升級仍需有新映像才可驗收；PaaS 的來源差異增量計畫未移植，Podman 採全量更新 |

HA 的 `woow_base_url_guard`、`woow_visitor_url` 是為 Supervisor Ingress 的 canonical URL／訪客來源修正，且以 `server_wide_modules` 載入。目前 Podman 入口沒有 HA Ingress token 路徑，兩顆模組尚未移入組合映像；這不等同於驗證 HA Ingress 的所有頁面／網站功能。

## 釘版 tenant cloud 實測紀錄

- 本機 cloud 基底映像：`jcr-prod.woowtech.io/woow-paas-docker-local/cloud-odoo:20261101.1152@sha256:5a0c0f9bed994688230b0d4869ab7f442381f2953149133842bb16065ed37316`；資料庫：`paas-postgres:17.11-20260928.1549@sha256:dbd1fed8882043f45bf759e8f7c73092505ef0afef7a23a93b177e6f7c2c840f`。兩者 JCR manifest、匯入後 RepoDigest 與 Podman 實際容器映像均已核對。
- 以該 cloud 基底及公開 HA `odoo-addons` commit `51856b0` 建立 `localhost/woow-odoo-tenant-ha@sha256:f259166adad7e28138fb1a5fccb993cd6831b110ae316424162e5baf5227b5a1`。基底 7 顆 tenant 模組與額外 7 顆 HA 模組都可見；各安裝一顆並於還原後核對。衍生映像僅在本機，未推送到公開 registry。
- 空的 PG17 資料卷上建立 `odoo`；管理員登入 Email 為 `woowtech@designsmart.com.tw`，隨機密碼在 `odoo18-odoo-admin-password` Podman secret。XML-RPC 與實際 HTTP 表單／session 登入通過，預設 `admin/admin` 失效。起初發現 `db_name` 過早設定會讓 Odoo 自行初始化預設管理員；已修正並重建空庫驗證。
- 新庫建立聯絡人及二進位附件，讀回後封存。刻意修改聯絡人並刪附件，再以 `--restore-secrets` 還原；內容、管理員登入、兩個已安裝模組、`C` collation 與 `pg_trgm`／`vector` 皆驗證。測試聯絡人與附件事後已移除；乾淨狀態的含密碼校驗封存為 `odoo18-20261110T010008Z.tar`，僅在本機私有備份目錄。
- 新實例完成資料庫角色隔離後完整 smoke **26 通過、0 失敗、1 項因租戶關閉資料庫服務而跳過**；線上還原切換與回退各 quick smoke **16/16**，管理員 XML-RPC 登入也通過。gateway 僅綁 `127.0.0.1:18080`，Odoo 本體僅綁 `127.0.0.1:18069`，資料庫無對外 port。正式外部路由已於 2026-11-10 發布至受保護的 `https://odoo-openclaw.woowtech.io`。

## 先前候選映像實測紀錄（已封存並換成上述實例）

- 新建 `odoo_fresh_20261110`，以獨立的管理員 secret 從 `http://127.0.0.1:18080` XML-RPC 登入，建立聯絡人及二進位附件；更新映像後、還原後均讀回原值。所有資料都是測試資料。
- 組合映像 `localhost/woow-odoo-ha-cloud-parity@sha256:f2ba1a31652b41969033d32fcef064a1458b1897c20433c439b559dfba11c0b0` 建自本機 PaaS cloud 候選映像 `sha256:af2c232f…` 及公開 HA 7 顆模組；這兩顆映像只存在本機，未推到 registry。
- `scripts/upgrade.sh --update-modules` 在三個測試庫完成，最後安裝與完整 smoke **25/25**。新資料庫 13 顆 cloud 與 7 顆 HA 模組都可見，`awesome_clicker` 已安裝。Odoo 的 `werkzeug` 和 `longpolling` INFO 查詢紀錄都抑制 token。
- 發現本機 HTTP gateway 原本會把 session cookie 強制設為 `Secure`；修正為 HTTP 可登入、HTTPS 維持 `Secure`，兩種 cookie 旗標均由 smoke 驗證。另用保留 cookie／CSRF 的網頁表單實際登入，`/web/session/get_session_info` 回傳有效使用者 ID。
- SMTP 以同 Podman 網路的暫時 sink 收到 From、To、Subject 和本文，測試後已停止並移除 sink；未寄外部信。Noto CJK TC PDF 驗證沿用原 cloud 映像測試的同一底層。
- `scripts/backup.sh` 建立約 4.8 MB 校驗封存，停止 Odoo 時保留 DB，再啟動 Odoo 及 nginx gateway。以同檔 `scripts/restore.sh` 還原 3 庫，入口健康與限制快速 smoke **15/15**，管理員、聯絡人及附件再驗通過。此前另已測過修改資料後還原原值。
- 定時備份 service 曾實際執行成功，timer enabled；輪替測試覆蓋最近 7 份與最近 4 個 ISO 週首份、壞檔時拒絕刪除。未做遠端備份目的地測試。
- `tests/dryrun.sh` 現含租戶釘版配置的 Quadlet 渲染；`tests/run.sh` 15 個 Python 測試與資源重建回歸測試通過。PG17 映像對 PG16 既有資料卷的拒絕在本機測過；沒有讓 PG17 啟動該卷。

## 使用方式與剩餘驗收

本分支的預設映像仍為公開 Odoo 18 + PG16；`config/profiles/tenant-cloud.profile` 固定租戶範本的 **cloud-odoo `20261101.1152`、chart `0.2.26` 對應設定及 PG17.11 digest**。本機已在全新空資料卷實際套用，並以指定 cloud 映像建置含 HA 範例模組的衍生映像。舊 PG16 候選測試庫在替換前完成含密碼校驗封存；沒有以 PG17 開啟 PG16 的資料卷。啟動後 `list_db=False` 與 `dbfilter=^odoo$`，定時備份 timer 已恢復。

## 2026-11-10 角色隔離、升級閘與線上還原追加驗收

- 原本 `odoo18-db-data` 的 `odoo` 是 PostgreSQL bootstrap OID 10，直接 `ALTER ROLE ... NOSUPERUSER` 被資料庫拒絕。`scripts/migrate-tenant-db-role.sh` 先停 web／gateway、建立含資料與私密憑證的校驗備份，再用 `postgres` 初始化新卷 `odoo18-db-data-isolated`。在旁路還原並核對模組、upgrade marker、附件與角色權限後才換 Quadlet 資料卷；舊卷保留作回退。新卷 `data_checksums=on`，`odoo` 的 `rolsuper`／`rolcreatedb`／`rolcreaterole` 全為 false，實際建庫也遭拒。Odoo 管理員和資料庫管理員使用獨立 Podman secrets。
- 安裝程式也會檢查停止狀態的舊資料卷：若舊卷已有 PostgreSQL 資料、隔離卷尚未初始化，會先要求執行角色遷移，避免重裝時誤建立另一個空租戶庫。
- 新租戶首裝改由受限角色配合 `postgres` 建庫／擴充套件；`-i base` 僅在尚無 `ir_module_module` 的全新庫執行，管理員登入與密碼在 web 開放前設定。既有庫不重跑 `-i base`。另建獨立 `odoo_bootstrap_probe` 庫，實際跑完一次性 `-i base`、管理員設定並核對 base/web 已安裝及 Email，之後已刪除探針庫、filestore 與其 secret。
- `scripts/upgrade-gate.sh` 記錄映像 digest 與 Odoo deb core 日期，先核對已安裝模組來源與版本，再限制同 digest 三次嘗試，執行 `-u all`，驗證全部模組後才寫完成 marker。tenant Quadlet 的 `ExecStartPre` 每次啟動 web 都先跑此閘；實際 `systemctl --user restart odoo.service` 的 journal 顯示同 digest 跳過，入口恢復 200。隔離庫上用不同 ID、相同模組的測試映像完成一次真實更新；移走 `awesome_clicker` 的測試映像在寫 attempt 前被拒絕，人工注入的三次失敗與較新 core marker 都以 78 拒絕。正式部署仍用既定 cloud/HA digest，沒有切換到測試映像。
- `scripts/restore-online.sh` 將本機受限角色產出的校驗備份還原到旁路資料庫與 filestore，驗證 26 顆已安裝模組、18 個附件引用、映像 digest 與 DB OID；預備階段正式 `/web/health` 持續 200。短暫停 web／gateway 後在同一個 PG transaction 改名兩庫，交換 filestore，重啟並跑 quick smoke。回退再交換回原資料庫與 filestore，原實例恢復健康；加入容量檢查、預備結果 24 小時期限與切換後舊資料至少保留 24 小時的 finalize 閘。兩輪切換／回退各通過 quick smoke 16/16，旁路資料已安全丟棄。這是線上預備、短暫切換，不宣稱零停機。
- Cloudflare Tunnel 連到 PaaS Access 61。新建第五條路由 `odoo-openclaw.woowtech.io` 時先指向 `http_status:503`；設定路由專屬 Cloudflare Access app、Email OTP 及 `woowtech@designsmart.com.tw` 的 allow policy，確認未登入外網請求回 302 至 `woowtech.cloudflareaccess.com` 後，才切到 `http://localhost:18080`。PaaS 與本機 Tunnel 同步狀態均顯示 `protected=True`、目標 URL 正確、無待發布或 Odoo 專屬問題；Tunnel 容器內直連 gateway 的 `/web/login` 回 200，外網未登入的 `/web/login` 仍回 302 到 Access。尚需實際完成 Email OTP 後驗證瀏覽器中的 Odoo 登入頁與管理員操作。

現有差距：PaaS 來源差異增量升級計畫、遠端備份目的地、HA Supervisor Ingress、真實即時事件、外部 SMTP TLS／帳號及 Access 登入後的完整外網操作尚未驗收。PaaS platform 的約 40 顆模組與控制面不列入 tenant cloud 範圍。
