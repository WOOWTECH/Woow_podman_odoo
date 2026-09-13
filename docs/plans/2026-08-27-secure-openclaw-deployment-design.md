# Secure OpenClaw Odoo Deployment Design

## Goal

Harden `Woow_podman_odoo` as a rootless Podman Odoo 18 and PostgreSQL deployment whose web endpoint is host-loopback-only and reachable remotely through the Headscale-managed Tailscale gateway.

## Architecture and network boundary

Run Odoo 18 and PostgreSQL on a project-owned bridge network. PostgreSQL has no host-published port. Publish Odoo only as `127.0.0.1:18069 -> 8069`. The Tailscale gateway forwards tailnet TCP port `18069` to host loopback port `18069`. Nginx Proxy Manager may share a separate internal proxy network later, but Odoo is not configured as a public proxy host in this delivery.

## Secrets and configuration

Replace the tracked `admin_passwd = admin` value with a generated runtime configuration. Generate independent PostgreSQL and Odoo database-manager passwords, store them only in mode-`600` runtime files, and avoid command-line or log disclosure. Mount generated Odoo configuration read-only. Use explicit image releases and digests. Prefer a maintained pgvector PostgreSQL image over an unpinned build-time Git clone when compatibility is verified.

## Reliability and persistence

Add PostgreSQL readiness and Odoo HTTP health checks, startup coordination, exact project-resource ownership checks, named volumes for database and filestore state, and user-systemd startup. Deployment is idempotent and preserves credentials and data across redeployments and restarts.

## Lifecycle and verification

Provide deploy, verify, backup, restore, and scoped removal tools. Backup covers PostgreSQL and Odoo filestore/configuration, uses private archives, and validates extraction against traversal and link attacks. Tests cover configuration rendering, secret permissions, Compose output, readiness ordering, restart persistence, database connectivity, web response, loopback binding, VPN access, backup validation, and no secret leakage.
