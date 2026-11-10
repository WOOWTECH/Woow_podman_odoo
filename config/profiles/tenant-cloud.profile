# PaaS Odoo tenant template snapshot (cluster1, 2026-11-07): chart 0.2.26,
# cloud-odoo 20261101.1152. Use only on a NEW empty database volume with JCR access.
# This is an example, never a credential store. Before installing, set the two first-run fields below.
WOOW_ODOO_BIND=127.0.0.1
WOOW_ODOO_PORT=18069
WOOW_ODOO_GATEWAY_ENABLED=True
WOOW_ODOO_GATEWAY_BIND=127.0.0.1
WOOW_ODOO_GATEWAY_PORT=18080
WOOW_ODOO_WORKERS=0
WOOW_ODOO_MAX_CRON_THREADS=2
WOOW_ODOO_DB_MAXCONN=8
WOOW_ODOO_LIMIT_TIME_CPU=60
WOOW_ODOO_LIMIT_TIME_REAL=120
WOOW_ODOO_LIMIT_TIME_REAL_CRON=600
WOOW_ODOO_LIMIT_REQUEST=65536
WOOW_ODOO_EMAIL_FROM=
WOOW_ODOO_SMTP_SERVER=
WOOW_ODOO_SMTP_PORT=587
WOOW_ODOO_SMTP_USER=
WOOW_ODOO_SMTP_SSL=True
WOOW_ODOO_IMAGE=jcr-prod.woowtech.io/woow-paas-docker-local/cloud-odoo:20261101.1152@sha256:5a0c0f9bed994688230b0d4869ab7f442381f2953149133842bb16065ed37316
WOOW_ODOO_DB_IMAGE=jcr-prod.woowtech.io/woow-paas-docker-local/paas-postgres:17.11-20260928.1549@sha256:dbd1fed8882043f45bf759e8f7c73092505ef0afef7a23a93b177e6f7c2c840f
WOOW_ODOO_ADDONS_DIR=%h/.local/share/odoo18/addons
# First run needs database management locally. After initialization, change to False and ^odoo$.
WOOW_ODOO_LIST_DB=True
WOOW_ODOO_DB_FILTER=
WOOW_ODOO_DEFAULT_DB=
WOOW_ODOO_ADMIN_LOGIN=
WOOW_ODOO_LANG=zh_TW
WOOW_ODOO_TENANT_CLOUD=True
