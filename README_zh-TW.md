# Odoo 18：rootless Podman（Quadlet + systemd）部署

[English](README.md)

以 rootless Podman [Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html)
單元在 `systemd --user` 下執行 Odoo 18 Community 與 PostgreSQL 16 + pgvector 0.8.0。兩個容器都透過
linger 開機自動啟動、當機自動重啟。所有密碼都在安裝時產生並存放於 podman secrets：沒有 `admin` 主控密碼，
本倉庫任何檔案裡也沒有密碼。

> **請立即輪替舊的資料庫密碼。** 直到 2026-09 為止，本公開倉庫的 `docs/DEPLOYMENT_RECORD.md` 內含明文
> `POSTGRES_PASSWORD`，且 `config/odoo.conf` 附帶 `admin_passwd = admin`。目前的程式碼已移除兩者，但該
> 密碼自二月起就是公開的，**必須視為已外洩**。若有資料庫叢集曾以該密碼初始化，請立刻輪替：
> `scripts/rotate-secrets.sh --db`。改寫 git 歷史並不能收回已外洩的值，輪替才是真正的修補。若該值再次
> 出現在倉庫中，CI 會失敗（`tests/leaked-value-scan.py`）。

> **Docker 或 podman-compose 使用者：** compose 部署已移除。最後一版保留在 tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_odoo/tree/compose-final)
> （`git clone -b compose-final https://github.com/WOOWTECH/Woow_podman_odoo.git`）。該 tag 不再維護，
> 且仍含有上述兩個問題。

## 安裝內容

| 項目 | 名稱 | 說明 |
|---|---|---|
| Odoo 容器 | `odoo18-web`（單元 **`odoo.service`**） | `odoo:18.0-20260817`，以 digest 釘版 |
| 資料庫容器 | `odoo18-db`（單元 **`odoo-db.service`**） | `pgvector/pgvector:0.8.0-pg16`，以 digest 釘版，**不開主機埠** |
| 網路 | `odoo18-network` | 私有 bridge |
| Volume | `odoo18-db-data`、`odoo18-web-data` | 與 compose 部署同名 |
| 設定 | `~/.config/odoo18/odoo18.env`（0600） | 由 `scripts/install.sh` 建立；不掛載進任何容器 |
| 憑證 | podman secrets `odoo18-postgres-password`、`odoo18-admin-password`、`odoo18-odoo-conf` | 安裝時產生 |
| Addons | 預設 `~/.local/share/odoo18/addons` | 以**唯讀**方式掛載到 `/mnt/extra-addons` |

單元刻意**不**命名為 `odoo18.service`：`~/.config/systemd/user` 內同名的手寫單元（compose 時代的部署會安裝
一個）優先於 Quadlet 產生的單元，會把新單元默默蓋掉。

`odoo.conf` 從不落地。`install.sh` 會把 `config/odoo.conf.template` 與兩組產生的密碼直接算進
`odoo18-odoo-conf` secret，並以唯讀方式掛載到 `/etc/odoo/odoo.conf`（擁有者 `odoo`、權限 0400）。由於檔案中
已設定 `db_password`，官方 entrypoint 不會再附加 `--db_*` 參數，因此兩組密碼不會出現在環境變數、程序參數或
`podman inspect` 之中。

## 需求

- 有 systemd 與 cgroup v2 的 Linux。已在 Ubuntu 24.04 測試。
- Podman 4.9 以上、rootless（Ubuntu 24.04 內建 4.9.3），另需 `python3` 與 `curl`。
- 擁有容器的使用者需以一般登入工作階段操作（ssh 或主控台，不要用 `su` 或 `sudo -u`）。
- 該使用者需啟用 linger；`install.sh` 會自動啟用，polkit 拒絕時會印出需要執行的那一行 `sudo`。
- Odoo 需要一個空閒埠（預設 18069）。資料庫不開任何主機埠，所以主機上已有的 `127.0.0.1:5432` 不會衝突。
- 映像約 3 GB 磁碟；小型資料庫約 1-2 GB 記憶體。

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_odoo.git
cd Woow_podman_odoo
scripts/install.sh                # 第一次：建立 ~/.config/odoo18/odoo18.env 後停下讓你檢查
nano ~/.config/odoo18/odoo18.env  # 選擇性：埠、綁定位址、addons 目錄
scripts/install.sh                # 產生單元、驗證、拉映像、檢查映像帳號、產生 secrets、
                                  # 先啟動資料庫再啟動 Odoo，最後執行 tests/smoke.sh
```

接著開啟 `http://127.0.0.1:18069/`，在 Odoo 的資料庫管理介面建立第一個資料庫。主控密碼就是
`odoo18-admin-password` secret：

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password
```

常用選項：

| 選項 | 作用 |
|---|---|
| `--accept-defaults` | 第一次執行時直接採用範例設定繼續。 |
| `--set KEY=VALUE` | 先把設定寫入 env 檔（可重複），例如 `--set WOOW_ODOO_PORT=28069`。 |
| `--fix-addon-perms` | 對 addons 目錄執行 `chmod -R o+rX`，而不是停下來報錯（見下）。 |
| `--dry-run` | 只產生與驗證、列出會變更的內容，不動任何東西。 |
| `--no-start`、`--no-smoke` | 安裝但不啟動；略過 smoke 測試。 |

重複執行 `install.sh` 是安全的：沒有變更時不重啟任何東西，也不會更換任何密碼。

## 設定

| 鍵 | 預設 | 說明 |
|---|---|---|
| `WOOW_ODOO_BIND` | `127.0.0.1` | Odoo 發布的位址：`127.0.0.1`、本機某個 IPv4 位址，或 `all`。 |
| `WOOW_ODOO_PORT` | `18069` | Odoo 的主機埠。 |
| `WOOW_ODOO_ADDONS_DIR` | `%h/.local/share/odoo18/addons` | 以唯讀掛載到 `/mnt/extra-addons` 的主機目錄；`%h` 是你的家目錄。 |
| `WOOW_ODOO_LIST_DB` | `True` | 資料庫建立完成後可設為 `False` 隱藏資料庫管理介面。 |

其他設定（workers、記憶體上限、`proxy_mode` 等）在 `config/odoo.conf.template`。編輯樣板後執行
`scripts/install.sh`，conf secret 會重新算出並重啟 Odoo。

### Addons 與 rootless 權限

在 rootless user namespace 內 Odoo 以 uid 100 執行，主機視之為 *other*，因此每個 addon 檔案需要 `o+r`、
每個目錄需要 `o+rx`；一般 git checkout（0644/0755）本來就符合。addons 以唯讀掛載，而且**不做任何 chown**，
所以你仍以自己的身分編輯與 `git pull`。當 `install.sh` 發現 Odoo 讀不到的檔案時會印出修正指令：

```bash
chmod -R o+rX ~/.local/share/odoo18/addons     # 或：scripts/install.sh --fix-addon-perms
```

刻意不使用 `:U`（podman 對掛載來源做遞迴 chown）：那會在每次啟動時把你的原始碼樹改成 subuid 擁有。舊文件
的 `sudo chown -R 101:101 ./addons` 是雙重錯誤（uid 是 100，且主機 uid 101 不等於容器 uid 101），已移除。

新增或修改 addon 後，重啟 Odoo 並更新模組：

```bash
systemctl --user restart odoo.service
podman exec odoo18-web odoo -c /etc/odoo/odoo.conf -d <資料庫> -u <模組> --stop-after-init --no-http
```

### Secrets

| Podman secret | 內容 | 如何傳入容器 |
|---|---|---|
| `odoo18-postgres-password` | 資料庫角色 `odoo` 的密碼 | 掛載於 `/run/secrets/postgres_password`；初始化資料卷時 PostgreSQL 透過 `POSTGRES_PASSWORD_FILE` 讀取 |
| `odoo18-admin-password` | Odoo 主控（資料庫管理）密碼 | 不掛載，只算進 conf |
| `odoo18-odoo-conf` | 算好的 `/etc/odoo/odoo.conf` | 唯讀掛載，擁有者 `odoo`、權限 0400 |

以 `scripts/rotate-secrets.sh --db` 或 `--admin` 輪替。`--db` 會修改 PostgreSQL 的角色密碼、取代 secret、
重新算出 conf 並重啟 Odoo，全程不把密碼放進指令列。若要自訂值，請在私人終端機執行：

```bash
read -rs -p 'new master password: ' p; printf '%s' "$p" | podman secret create --replace odoo18-admin-password -; unset p
scripts/install.sh
```

## 驗證

```bash
tests/smoke.sh          # 單元、健康、埠、HTTP、密碼外洩檢查、conf 權限、主控密碼、pgvector、addons
tests/smoke.sh --quick  # 只檢查單元、健康、埠與 HTTP
```

`tests/smoke.sh` 會檢查兩組密碼都不出現在 `podman inspect`、程序參數、journal、容器日誌或任何受版控的檔案
中，並確認舊的預設主控密碼 `admin` 會被拒絕。

## 升級

```bash
git pull
scripts/upgrade.sh                     # 需要時加 --update-modules，對每個資料庫執行 odoo -u all
```

流程為：備份 → 保存已安裝的單元 → 執行 `install.sh`（先拉新的釘版映像）→ 對每個資料庫執行
`ALTER EXTENSION vector UPDATE` → smoke 測試。任何一步失敗就放回原本的單元，並以原本的映像重啟 Odoo。
新版 Odoo 已遷移過的資料庫不會自動回復，請用升級前的備份還原。

## 備份與還原

```bash
scripts/backup.sh                      # 停止 Odoo、逐一 dump 每個資料庫、複製 filestore、驗證
scripts/backup.sh --include-secrets    # 另外把兩組密碼放進封存檔（請當成密碼保管）
scripts/restore.sh --archive ~/.local/share/woow-backups/odoo18/odoo18-<stamp>.tar --confirm-restore odoo18
```

封存檔包含 `roles.sql`、每個 Odoo 資料庫一份 custom-format dump、整個 Odoo 資料卷（filestore 與 session）、
含映像 digest 的 `metadata.json`，以及 `SHA256SUMS`。封存前與還原前都會驗證
（`scripts/validate-backup.py`：不得有符號連結、不得路徑穿越、檢查校驗碼與 PostgreSQL dump 格式）。

還原會刪除並重建封存檔中的資料庫、換掉其 filestore、把資料庫角色密碼設回本機目前的 secret，並進行驗證。
若在第一次變更之後失敗，會自動還原它在開始時建立的「還原前封存檔」；若連回復都失敗，Odoo 會保持停止，
以免提供混合狀態。不在封存檔中的資料庫不會被動到，並會列出提醒。

## 解除安裝

```bash
scripts/uninstall.sh                                     # 移除單元；保留資料
scripts/uninstall.sh --purge --confirm-purge odoo18      # 另外刪除兩個 volume、網路、secrets
                                                         # 與 ~/.config/odoo18
```

`--purge` 是唯一會刪除資料的指令，而且會先對兩個 volume 與 env 檔做最後一次冷備份。映像、備份與你的
addons 目錄一律不刪除。

## 從既有 compose 部署遷移

`scripts/migrate-legacy.sh` 會把執行中的 podman-compose／docker-compose `odoo18` 專案（容器
`odoo18-db`、`odoo18-web`，volume `odoo18-db-data`、`odoo18-web-data`，網路 `odoo18-network`，以及
可能存在的手寫 `odoo18.service` 與 `odoo18-health.timer`）搬到本倉庫的 Quadlet 單元。

這是**原地沿用**：單元保留 compose 的名稱（`ContainerName=`、`VolumeName=`、`NetworkName=`），所以
同樣的 volume 與網路會被再次開啟。資料庫不搬、filestore 不搬、釘版映像也不變。舊容器會保留給
`--rollback`。

```bash
scripts/migrate-legacy.sh --dry-run                 # 只做檢查與產生單元，不改任何東西
scripts/migrate-legacy.sh --prepare-only            # 再加上 secrets、映像、熱備份；不停機
scripts/migrate-legacy.sh                           # 正式切換
scripts/migrate-legacy.sh --status                  # 顯示記錄下來的狀態
scripts/migrate-legacy.sh --rollback                # 回到舊的 compose 堆疊
```

常用選項：`--legacy-dir DIR` 把舊 checkout 的 `.env` 與 compose 檔一併封存進備份；`--suffix S` 指定
保留容器的名字 `<name>-legacy-S`；filestore 很大且已有其他備份時可用 `--no-cold-copy` 略過冷
`podman volume export`；`--new-master-password` 不沿用舊的 Odoo 主控密碼而是重新產生；
`--force-capture` 讓本來可以改名的主機改走 capture 路徑；`--fix-addon-perms` 會轉交給 `install.sh`。

**資料從哪裡讀。** 遷移需要的每個值都取自**執行中的容器**，而不是 checkout：實際部署的目錄未必是本倉庫
描述的那一份——在 `woowtechopenclaw` 上，`.env` 裡根本沒有任何設定。發布位址取自 `odoo18-web` 的
`8069/tcp` 綁定，addons 目錄與兩個 volume 名稱取自它的掛載，`list_db` 與主控密碼取自容器真正讀取的
`odoo.conf`。

**唯一無法重新產生的是資料庫密碼。** `POSTGRES_PASSWORD` 與 `POSTGRES_PASSWORD_FILE` 只有在初始化
**空的** volume 時才會被讀取，所以被沿用的 `odoo18-db-data` 裡的 `odoo` 角色仍然使用當初建立時的密碼。
腳本會從執行中的容器讀出該密碼（兩種形式都支援），並在任何停機開始前，用 TCP 連線**實際驗證**它能通過
認證——這正是新的 `odoo.conf` 的連線方式——再寫入 `odoo18-postgres-password` secret。驗證不過就直接
拒絕，不會只給一則警告。

**主控密碼。** 舊 `odoo.conf` 若是自動產生的 `admin_passwd`，會被沿用到 `odoo18-admin-password`
secret；若缺漏或是眾所周知的預設值（本倉庫 `compose-final` 標籤出貨的就是 `admin`），則**不會**沿用，
改由 `install.sh` 重新產生——`tests/smoke.sh` 會斷言 `admin` 必須被拒絕。新值可用
`podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password` 讀出。

**沒有任何資料庫是正常狀態。** 從未建立過租戶資料庫、只有 `postgres` 與樣板資料庫的堆疊（也就是
`woowtechopenclaw` 目前的樣子）可以正常遷移。角色 dump 仍然會做（那裡面才有被沿用 volume 當初的密碼），
資料庫數量也會記錄下來，好讓遷移後的比對有明確依據。

**它拒絕而不猜測的情況。** 舊容器不存在或沒在執行；舊容器已由本單元管理；Quadlet 單元已經安裝；volume
或網路名稱與單元釘住的不同（沿用會安靜地開在空資料庫上）；addons 目錄不可讀；有別的容器佔用同一個主機
連接埠；舊堆疊停止後連接埠仍被綁住；Odoo 或 PostgreSQL 主版本與釘版不同；資料庫角色不接受該密碼；以及
已經記錄過切換後再跑第二次。

**舊容器如何保留**（STANDARD 7a）。要嘛改名為 `<name>-legacy-<suffix>` 並保持停止，要嘛——當使用者單元
`podman-restart.service` 已啟用**且**某個舊容器的重啟策略剛好是 `always` 時，因為
`podman start --all --filter restart-policy=always` 會在下次開機把它叫醒，讓第二個 PostgreSQL 開啟
`odoo18-db-data`——就先 capture 進備份目錄再移除。`ql_rollback_strategy` 依主機的真實狀態判斷，絕不看
主機名稱，`--dry-run` 也會報告將走哪一條路。capture 在準備階段完成，也就是停機之前。`odoo18-db` 與
`odoo18-web` 目前都是 `unless-stopped`，所以兩台主機現在都判定為 `rename`；`--force-capture` 用來演練
另一條路徑。

**備份內容**（`~/.local/share/woow-backups/odoo18/migrate-<時間戳>/`，0700）：`roles.sql`、
`databases/<db>.dump` 與 `COUNT`、`LIST`，兩個 volume 的冷 `podman volume export`、`inspect.json`、
舊的 `odoo.conf` 與單元檔、`volume-fingerprints`、`precheck.txt` 與 `SHA256SUMS`；走 capture 路徑時
另有 `legacy-container/`。

**沿用會被證明，而不是假設。** 兩個 volume 的 `CreatedAt` 與磁碟 inode 會在切換前記錄、在 `install.sh`
之後比對。若新容器並非開在舊 volume 上，遷移會失敗並自動回復，而不是報告一個健康但坐在空資料庫上的
Odoo。

**停機時間**由腳本自行量測（從停止舊堆疊到 `install.sh` 返回），結束時印出，並記錄成 `--status` 裡的
`DOWNTIME_S`。

### 回復

```bash
scripts/migrate-legacy.sh --rollback
```

它會停止並移除 Quadlet 單元（volume、網路與 secrets 都保留，因為兩邊共用），移除本倉庫單元留下的容器，
把舊容器帶回來——改名回去，或是從 capture 以原本的重啟策略重建——重新啟用先前停用的舊單元，先啟動資料庫
再啟動 web，然後等待舊位址的 `/web/health`。切換失敗時會自動回復，除非指定了 `--no-auto-rollback`。

### 觀察期結束後

Quadlet 堆疊穩定執行一段時間之後，移除舊容器——**先移除 web**，因為 `odoo18-web` 帶著
`--requires=odoo18-db`，podman 會拒絕移除被別人依賴的容器：

```bash
podman rm odoo18-web-legacy-<suffix> odoo18-db-legacy-<suffix>
```

接著移除手寫的 `odoo18.service`、`odoo18-health.service` 與 `odoo18-health.timer`（這也一併淘汰每 10
秒觸發一次的健康檢查），以及舊的 `.runtime/` 目錄——其中的 secret 檔請用 `shred`，密碼現在存放在 podman
secret store。遷移備份請保留到確認無虞為止。

## 檔案

```
quadlet/                      帶 @@VAR@@ 標記的 Quadlet 單元；quadlet/render-vars 為白名單
config/odoo18.env.example     ~/.config/odoo18/odoo18.env 的範本
config/odoo.conf.template     算進 odoo18-odoo-conf secret（不落地）
scripts/install.sh            安裝／更新，也是「套用我的變更」指令
scripts/upgrade.sh            備份、單元快照、安裝、pgvector 更新、smoke、失敗回復
scripts/backup.sh restore.sh  經驗證的封存檔；另有 validate-backup.py、make-roles-idempotent.py
scripts/rotate-secrets.sh     輪替資料庫與主控密碼
scripts/migrate-legacy.sh     沿用執行中的 compose 部署；含 --rollback、--status
scripts/legacy-helpers.sh     migrate-legacy.sh 專用的輔助函式（刻意不放進 common.sh，後者在四個
                              倉庫之間的設定區塊以下是逐位元組相同的）
scripts/lib/                  內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh               產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/run.sh                  驗證器、角色前處理與樣板的 Python 單元測試
tests/migrate-model.sh        釘住遷移行為：兩條回復路徑、依賴順序、無資料庫的情況、沿用證明
                              （podman 與 systemctl 皆為測試替身）
tests/smoke.sh                主機上的安裝後檢查
tests/lint-repo.sh            憑證掃描、外洩值閘門、映像釘版一致性、README 檢查（CI）
docs/plans/                   設計歷史，包含本倉庫所承接的加固版部署
```

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| `install.sh` 說 `odoo18.service` 正在執行 | compose 時代的部署仍在跑，請先完成遷移章節。 |
| `install.sh` 說有容器存在且不受管理 | 用印出的指令改名，或備份後移除。 |
| `install.sh` 說資料庫角色不接受記錄的密碼 | volume `odoo18-db-data` 先前已初始化，因此仍沿用當初的密碼（`POSTGRES_PASSWORD_FILE` 只在空 volume 上生效）。請執行 `scripts/rotate-secrets.sh --db`。 |
| Odoo 啟動後因資料庫錯誤結束 | `journalctl --user -u odoo.service -n 100`。首次啟動時資料庫可能仍在初始化，Odoo 會重試，systemd 也會重啟它。 |
| 資料庫管理介面出現 `Access Denied` | 請用 `odoo18-admin-password` secret，而不是 `admin`。 |
| 看不到某個 addon | 對 addons 目錄執行 `chmod -R o+rX`，再重啟 `odoo.service` 並更新模組。 |
| 登出或重開機後單元消失 | `loginctl show-user $USER -p Linger` 必須是 `yes`。 |
