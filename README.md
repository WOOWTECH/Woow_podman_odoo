# Odoo 18 — Docker / Podman Deployment

Production-ready Docker Compose setup for **Odoo 18 Community Edition** with **PostgreSQL 16** and **pgvector** extension.

## Quick Start

```bash
git clone https://github.com/WOOWTECH/Woow_podman_odoo.git
cd Woow_podman_odoo
cp .env.example .env
# Edit .env with your settings
docker compose up -d
```

## Deploy to Portainer

Deploy this project instantly using Portainer's Stack feature with our GitHub repository URL.

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#deploy-to-portainer)

### Via Git Repository (Recommended)

1. Log in to your Portainer dashboard
2. Navigate to **Stacks** → **Add stack**
3. Select **Repository**
4. Fill in the following:

   | Field | Value |
   |-------|-------|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_odoo` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. Click **Deploy the stack**

### Via Web Editor

1. Copy the raw URL of `docker-compose.yml`:

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_odoo/main/docker-compose.yml
   ```

2. Log in to Portainer → **Stacks** → **Add stack** → **Web editor**
3. Fetch the content from the URL above using `curl` or your browser, paste into the editor
4. Set environment variables (refer to `.env.example`)
5. Click **Deploy the stack**

---

## 一鍵部署至 Portainer

使用 Portainer 的 Stack 功能，可透過 GitHub Repository 網址快速部署本專案。

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#一鍵部署至-portainer)

### 使用 Git Repository 部署（推薦）

1. 登入你的 Portainer 管理介面
2. 進入 **Stacks** → **Add stack**
3. 選擇 **Repository**
4. 填入以下資訊：

   | 欄位 | 值 |
   |------|-----|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_odoo` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. 點擊 **Deploy the stack**

### 使用 Web Editor 部署

1. 複製 `docker-compose.yml` 的 Raw URL：

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_odoo/main/docker-compose.yml
   ```

2. 登入 Portainer → **Stacks** → **Add stack** → **Web editor**
3. 使用 `curl` 或瀏覽器取得上述 URL 的內容，貼入編輯器
4. 設定環境變數（參考 `.env.example`）
5. 點擊 **Deploy the stack**

## Files

| File | Description |
|------|-------------|
| `docker-compose.yml` | Service definitions |
| `.env.example` | Environment variable template |
| `config/` | Odoo configuration files |
| `addons/` | Custom Odoo addons |
| `postgres/` | PostgreSQL data |
| `docs/` | Additional documentation |

---

## Other deployment platforms

- **K3s/Kubernetes (Helm chart)** → [Woow_k3s_odoo](https://github.com/WOOWTECH/Woow_k3s_odoo)
- **Home Assistant add-on** → [Woow_ha_odoo](https://github.com/WOOWTECH/Woow_ha_odoo)
