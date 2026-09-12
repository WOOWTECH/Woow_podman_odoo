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

## 從既有部署遷移

容器、volume 與網路名稱都與 compose 部署相同，因此是原地沿用：不需複製資料，映像也不變。

1. **先用舊工具備份**（compose checkout 的 `scripts/backup.sh`），並保存
   `podman inspect odoo18-db odoo18-web > legacy-inspect.json`。
2. **匯入既有密碼**，避免被新產生的取代。一律用管線，不要 echo；並去掉結尾換行（PostgreSQL entrypoint
   也是這樣處理的）：
   ```bash
   podman unshare cat .runtime/secrets/postgres_password | tr -d '\n' | podman secret create odoo18-postgres-password -
   tr -d '\n' < .runtime/secrets/odoo_admin_password | podman secret create odoo18-admin-password -
   ```
3. **停止舊的監管單元：** `systemctl --user disable --now odoo18-health.timer odoo18.service`
   （這也會執行 `compose stop`）。只要其中之一還在執行，`install.sh` 就會拒絕繼續。
4. **把舊容器改名**，避免被 Quadlet 取代：
   `podman rename odoo18-db odoo18-db-legacy-$(date +%Y%m%d)`，`odoo18-web` 亦同。它們的重啟策略是
   `unless-stopped`，所以 `podman-restart.service` 不會再啟動它們。
5. **把 addons 設定指向既有目錄**後安裝：
   ```bash
   scripts/install.sh --set WOOW_ODOO_ADDONS_DIR=%h/Woow_podman_odoo/addons
   tests/smoke.sh
   ```
6. **需要回復時**：停止 Quadlet 單元、把舊容器改回原名，再重新啟用 `odoo18.service`。兩條路徑使用同樣的
   volume。
7. **觀察期結束後**：移除舊容器、三個手寫的 `odoo18*` 單元與舊的 `.runtime/` 目錄（其中的 secret 請用
   `shred`，它們現在存放在 podman secret store）。這也會一併淘汰每 10 秒觸發一次的健康檢查計時器。

## 檔案

```
quadlet/                      帶 @@VAR@@ 標記的 Quadlet 單元；quadlet/render-vars 為白名單
config/odoo18.env.example     ~/.config/odoo18/odoo18.env 的範本
config/odoo.conf.template     算進 odoo18-odoo-conf secret（不落地）
scripts/install.sh            安裝／更新，也是「套用我的變更」指令
scripts/upgrade.sh            備份、單元快照、安裝、pgvector 更新、smoke、失敗回復
scripts/backup.sh restore.sh  經驗證的封存檔；另有 validate-backup.py、make-roles-idempotent.py
scripts/rotate-secrets.sh     輪替資料庫與主控密碼
scripts/lib/                  內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh               產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/run.sh                  驗證器、角色前處理與樣板的 Python 單元測試
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
