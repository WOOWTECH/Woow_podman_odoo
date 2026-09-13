# Changelog

## 2.0.0 — 2026-09-12 (BREAKING)

Quadlet + systemd is now the only deployment in this repo, built on the hardened variant that ran on
the openclaw host and never reached GitHub (recovered in this release).

- **Security, do this first:** the plaintext `POSTGRES_PASSWORD` that `docs/DEPLOYMENT_RECORD.md`
  published in February and the `admin_passwd = admin` in `config/odoo.conf` are gone from HEAD. The
  leaked value has been public for seven months: treat it as compromised and rotate any cluster that
  used it (`scripts/rotate-secrets.sh --db`). `tests/leaked-value-scan.py` (CI) fails if the value
  ever comes back; it stores only the sha256.
- **Quadlet units** `odoo.service` and `odoo-db.service` (deliberately not `odoo18.service`, which a
  hand-written unit of the compose era would shadow). Both start at boot through linger and restart
  on failure. The oneshot `odoo18.service` wrapper and the `odoo18-health.timer` that fired every 10
  seconds are gone: podman's own health checks run under Quadlet.
- **Generated credentials in podman secrets:** `odoo18-postgres-password` (mounted, read through
  `POSTGRES_PASSWORD_FILE`), `odoo18-admin-password`, and `odoo18-odoo-conf`, the rendered
  `/etc/odoo/odoo.conf` mounted read-only as uid 100, mode 0400. No plaintext `.runtime/` files any
  more, and no password in env, argv or `podman inspect`.
- **Images:** `odoo:18.0-20260817` and `pgvector/pgvector:0.8.0-pg16`, both pinned by digest. The
  local `postgres/Dockerfile` build of pgvector 0.7.4 is removed. `install.sh` still probes each
  image fail-closed for the accounts the mounts depend on (postgres 999:999, odoo 100:101).
- **Loopback by default:** Odoo publishes `127.0.0.1:18069` (`WOOW_ODOO_BIND` / `WOOW_ODOO_PORT`),
  and the database publishes no host port at all.
- **Addons** come from a host directory (`WOOW_ODOO_ADDONS_DIR`, default
  `~/.local/share/odoo18/addons`) mounted read-only. `install.sh` checks that Odoo can read them and
  prints the `chmod -R o+rX` fix. The old `sudo chown -R 101:101` advice was wrong and is gone.
- **Backup and restore** now cover **every** Odoo database (the compose variant dumped only the
  `postgres` maintenance database), plus roles, the filestore and image metadata, with the harvested
  archive validator and the transactional restore with full rollback.
- **New scripts:** `install.sh`, `upgrade.sh` (unit snapshot rollback, `ALTER EXTENSION vector
  UPDATE`, optional `-u all`), `uninstall.sh` (`--purge` is the only way to delete data),
  `backup.sh`, `restore.sh`, `rotate-secrets.sh`.
- **Tests and CI:** `tests/dryrun.sh` (Quadlet 4.9.3 dry-run and `systemd-analyze verify`),
  `tests/smoke.sh`, `tests/run.sh` (validator, roles preparer, conf template), `tests/lint-repo.sh`,
  and two GitHub workflows.
- **Removed:** `docker-compose.yml`, `.env.example`, `postgres/Dockerfile`, `config/odoo.conf`, the
  compose lifecycle scripts (`deploy.sh`, `service.sh`, `install-systemd.sh`, `verify.sh`,
  `remove.sh`, `render-config.sh`, `healthcheck.sh`, `odoo-healthcheck.py`), the tailnet remote-gate
  helper and the Portainer instructions. Docker users stay on the `compose-final` tag.

Container, volume and network names are unchanged (`odoo18-web`, `odoo18-db`, `odoo18-db-data`,
`odoo18-web-data`, `odoo18-network`), so an existing host adopts its data in place. See the README
section "Migrating an existing deployment".
