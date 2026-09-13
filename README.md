# Odoo 18 on rootless Podman (Quadlet + systemd)

[繁體中文](README_zh-TW.md)

Odoo 18 Community with PostgreSQL 16 + pgvector 0.8.0, as rootless Podman
[Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html) units under
`systemd --user`. Both containers start at boot through linger and restart when they crash. Every
password is generated at install time and lives in podman secrets: there is no `admin` master
password and no password in any file in this repository.

> **Rotate the old database password.** Until 2026-09 this public repository contained a plaintext
> `POSTGRES_PASSWORD` in `docs/DEPLOYMENT_RECORD.md`, and `config/odoo.conf` shipped
> `admin_passwd = admin`. Both are gone from the current code, but the old value has been public since
> February and **must be treated as compromised**. If a database cluster was ever initialised with it,
> rotate it now: `scripts/rotate-secrets.sh --db`. Rewriting git history would not un-leak it;
> rotation is what closes the hole. CI fails if the value ever comes back (`tests/leaked-value-scan.py`).

> **Docker or podman-compose users:** the compose deployment was removed. The last compose version is
> kept at the tag [`compose-final`](https://github.com/WOOWTECH/Woow_podman_odoo/tree/compose-final)
> (`git clone -b compose-final https://github.com/WOOWTECH/Woow_podman_odoo.git`). It is not
> maintained, and the `compose-final` tree still contains the two problems above.

## What gets installed

| Item | Name | Notes |
|---|---|---|
| Odoo container | `odoo18-web` (unit **`odoo.service`**) | `odoo:18.0-20260817`, pinned by digest |
| Database container | `odoo18-db` (unit **`odoo-db.service`**) | `pgvector/pgvector:0.8.0-pg16`, pinned by digest, **no host port** |
| Network | `odoo18-network` | private bridge |
| Volumes | `odoo18-db-data`, `odoo18-web-data` | the same names the compose deployment used |
| Settings | `~/.config/odoo18/odoo18.env` (0600) | created by `scripts/install.sh`; not mounted anywhere |
| Credentials | podman secrets `odoo18-postgres-password`, `odoo18-admin-password`, `odoo18-odoo-conf` | generated at install time |
| Addons | `~/.local/share/odoo18/addons` by default | mounted **read-only** at `/mnt/extra-addons` |

The units are deliberately **not** called `odoo18.service`: a hand-written unit of that name in
`~/.config/systemd/user` (the compose-era deployment installed one) outranks the Quadlet generator and
would silently shadow the new unit.

`odoo.conf` never touches the disk. `install.sh` renders `config/odoo.conf.template` with the two
generated passwords straight into the `odoo18-odoo-conf` podman secret, which is mounted read-only at
`/etc/odoo/odoo.conf` (owner `odoo`, mode 0400). Because the file sets `db_password`, the stock
entrypoint adds no `--db_*` arguments, so neither password appears in an environment variable, in
process arguments, or in `podman inspect`.

## Requirements

- Linux with systemd and cgroup v2. Tested on Ubuntu 24.04.
- Podman 4.9 or newer, rootless (4.9.3 is the version in Ubuntu 24.04), plus `python3` and `curl`.
- A normal login session for the user who owns the containers (ssh or console, not `su` or `sudo -u`).
- Linger for that user; `install.sh` enables it, or prints the one `sudo` command when polkit refuses.
- A free port for Odoo (18069 by default). The database publishes nothing, so a PostgreSQL already
  running on `127.0.0.1:5432` is not a conflict.
- About 3 GB of disk for the images, and 1-2 GB of RAM for a small database.

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_odoo.git
cd Woow_podman_odoo
scripts/install.sh                # first run: creates ~/.config/odoo18/odoo18.env and stops for review
nano ~/.config/odoo18/odoo18.env  # optional: port, bind address, addons directory
scripts/install.sh                # render, validate, pull, probe the image accounts, generate the
                                  # secrets, start the database, then Odoo, then tests/smoke.sh
```

Then open `http://127.0.0.1:18069/`, and create your first database in Odoo's database manager. The
master password is the `odoo18-admin-password` secret:

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password
```

Useful options:

| Option | Effect |
|---|---|
| `--accept-defaults` | On the first run, keep going with the example settings instead of stopping. |
| `--set KEY=VALUE` | Store a setting in the env file first (repeatable), e.g. `--set WOOW_ODOO_PORT=28069`. |
| `--fix-addon-perms` | Run `chmod -R o+rX` on the addons directory instead of stopping (see below). |
| `--dry-run` | Render and validate, show what would change, touch nothing. |
| `--no-start`, `--no-smoke` | Install without starting; skip the smoke test. |

Re-running `install.sh` is safe: with nothing changed it restarts nothing and keeps every password.

## Configure

| Key | Default | Meaning |
|---|---|---|
| `WOOW_ODOO_BIND` | `127.0.0.1` | Address Odoo is published on: `127.0.0.1`, an IPv4 address of this host, or `all`. |
| `WOOW_ODOO_PORT` | `18069` | Host port for Odoo. |
| `WOOW_ODOO_ADDONS_DIR` | `%h/.local/share/odoo18/addons` | Host directory mounted read-only at `/mnt/extra-addons`. `%h` is your home. |
| `WOOW_ODOO_LIST_DB` | `True` | `False` hides the database manager once your databases exist. |

Everything else (workers, memory limits, `proxy_mode`, ...) is in `config/odoo.conf.template`. Edit the
template, then run `scripts/install.sh`: the conf secret is re-rendered and Odoo restarts.

### Addons and rootless permissions

Inside the rootless user namespace Odoo runs as uid 100, which the host sees as *other*. So every
addon file needs `o+r` and every directory `o+rx`; a normal git checkout (0644/0755) already does. The
addons are mounted read-only and **nothing is chowned**, so you keep editing and `git pull`ing them as
yourself. When `install.sh` finds a file Odoo cannot read it prints the fix:

```bash
chmod -R o+rX ~/.local/share/odoo18/addons     # or: scripts/install.sh --fix-addon-perms
```

`:U` (podman's recursive chown of the mount source) is deliberately not used: it would re-own your
source tree to a subuid on every start. The old advice `sudo chown -R 101:101 ./addons` was wrong
twice over (the uid is 100, and host uid 101 is not container uid 101) and is gone.

After adding or changing an addon, restart Odoo and update the module:

```bash
systemctl --user restart odoo.service
podman exec odoo18-web odoo -c /etc/odoo/odoo.conf -d <database> -u <module> --stop-after-init --no-http
```

### Secrets

| Podman secret | What it is | How it reaches the container |
|---|---|---|
| `odoo18-postgres-password` | password of the database role `odoo` | mounted at `/run/secrets/postgres_password`; PostgreSQL reads it through `POSTGRES_PASSWORD_FILE` when the volume is initialised |
| `odoo18-admin-password` | Odoo master (database-manager) password | not mounted; it is rendered into the conf |
| `odoo18-odoo-conf` | the rendered `/etc/odoo/odoo.conf` | mounted read-only, owner `odoo`, mode 0400 |

Rotate them with `scripts/rotate-secrets.sh --db` and/or `--admin`. `--db` changes the role password
in PostgreSQL, replaces the secret, re-renders the conf and restarts Odoo, all without putting a
password on a command line. To set a value of your own, use a private terminal:

```bash
read -rs -p 'new master password: ' p; printf '%s' "$p" | podman secret create --replace odoo18-admin-password -; unset p
scripts/install.sh
```

## Verify

```bash
tests/smoke.sh          # units, health, ports, HTTP, secret hygiene, conf mode, master password, pgvector, addons
tests/smoke.sh --quick  # units, health, ports and HTTP only
```

`tests/smoke.sh` checks, among other things, that neither password appears in `podman inspect`, in
process arguments, in the journal, in the container logs or in a tracked file, and that the old
default master password `admin` is rejected.

## Upgrade

```bash
git pull
scripts/upgrade.sh                     # add --update-modules to run `odoo -u all` per database
```

It backs up, saves the installed units, runs `install.sh` (which pulls the new pinned images first),
brings pgvector forward in every database (`ALTER EXTENSION vector UPDATE`) and runs the smoke test.
If anything fails, the previous units come back and Odoo restarts on the previous images. A database
that a newer Odoo has already migrated is not rolled back: restore the pre-upgrade archive.

## Backup and restore

```bash
scripts/backup.sh                      # stops Odoo, dumps every database, copies the filestore, validates
scripts/backup.sh --include-secrets    # also stores both passwords in the archive (keep it private)
scripts/restore.sh --archive ~/.local/share/woow-backups/odoo18/odoo18-<stamp>.tar --confirm-restore odoo18
```

An archive holds `roles.sql`, one custom-format dump per Odoo database, the whole Odoo volume
(filestore and sessions), `metadata.json` with the image digests, and `SHA256SUMS`. It is validated
before it is published and again before it is restored (`scripts/validate-backup.py`; no symlinks, no
path traversal, checksums, real PostgreSQL dumps).

Restore drops and recreates the databases that are in the archive, swaps their filestores, sets the
database role back to this host's password, and verifies. A failure after the first change restores
the pre-restore archive it took at the start, and leaves Odoo stopped if even that fails, so it can
never serve mixed state. Databases that are not in the archive are left alone and reported.

## Uninstall

```bash
scripts/uninstall.sh                                     # remove the units; keep the data
scripts/uninstall.sh --purge --confirm-purge odoo18      # also delete both volumes, the network,
                                                         # the secrets and ~/.config/odoo18
```

`--purge` is the only command that deletes data, and it takes a final cold backup of both volumes plus
the env file first. Images, backups and your addons directory are never deleted.

## Migrating an existing compose deployment

`scripts/migrate-legacy.sh` moves a running podman-compose / docker-compose deployment of the
`odoo18` project (containers `odoo18-db` and `odoo18-web`, volumes `odoo18-db-data` and
`odoo18-web-data`, network `odoo18-network`, optionally the hand-written `odoo18.service` and
`odoo18-health.timer`) onto the Quadlet units of this repo.

It is an **in-place adoption**: the units keep the compose names (`ContainerName=`, `VolumeName=`,
`NetworkName=`), so the same volumes and the same network are opened again. No database is copied,
no filestore is moved and the pinned images do not change. The legacy containers are kept for
`--rollback`.

```bash
scripts/migrate-legacy.sh --dry-run                 # checks + render, changes nothing
scripts/migrate-legacy.sh --prepare-only            # + secrets, images, hot backup; no downtime
scripts/migrate-legacy.sh                           # the cutover
scripts/migrate-legacy.sh --status                  # what was recorded
scripts/migrate-legacy.sh --rollback                # back to the legacy stack
```

Useful options: `--legacy-dir DIR` archives the old checkout's `.env` and compose file into the
backup; `--suffix S` names the kept containers `<name>-legacy-S`; `--no-cold-copy` skips the cold
`podman volume export` when the filestore is large and a separate backup exists;
`--new-master-password` generates a fresh Odoo master password instead of adopting the legacy one;
`--force-capture` takes the capture path on a host that would allow a rename; `--fix-addon-perms`
is passed through to `install.sh`.

**What it reads from where.** Everything the migration needs is taken from the *running containers*,
not from the checkout, because the deployed tree is not always the tree this repo describes — on
`woowtechopenclaw` the `.env` contains no settings at all. The publish address comes from
`odoo18-web`'s `8069/tcp` binding, the addons directory and both volume names from its mounts, and
`list_db` plus the master password from the `odoo.conf` the container actually reads.

**The database password is the one thing that cannot be regenerated.** `POSTGRES_PASSWORD` and
`POSTGRES_PASSWORD_FILE` are only read when an *empty* volume is initialised, so the role `odoo`
inside the adopted `odoo18-db-data` keeps whatever password it was created with. The script reads
that password from the running container (either form) and **proves it** by authenticating over TCP
— which is how the new `odoo.conf` connects — before any downtime starts. It then writes it into
the `odoo18-postgres-password` secret. A password that does not authenticate is a refusal, not a
warning.

**The master password.** A generated legacy `admin_passwd` is adopted into the
`odoo18-admin-password` secret. A missing or well-known one (`admin`, which is what this repo's own
`compose-final` tag shipped) is **not**: `install.sh` generates a fresh one instead, and
`tests/smoke.sh` asserts that `admin` is rejected. Read the new value with
`podman secret inspect --showsecret --format '{{.SecretData}}' odoo18-admin-password`.

**No database is a normal case.** A stack that has never had a tenant database created — only
`postgres` and the templates, which is exactly `woowtechopenclaw` today — migrates normally. The
roles dump is still taken (it carries the password the adopted volume was initialised with) and the
database count is recorded so the post-migration comparison is explicit.

**What it refuses rather than guesses.** A legacy container that is missing or not running; one that
is already managed by these units; Quadlet units that are already installed; a volume or network
whose name differs from what the units pin (adopting would silently start on an empty database); an
unreadable addons directory; another container publishing the same host port; a host port still
bound after the legacy stack stopped; an Odoo or PostgreSQL major version that differs from the pins;
a database password the role does not accept; and a second run after a recorded cutover.

**How the legacy containers are kept** (STANDARD 7a). Either renamed to `<name>-legacy-<suffix>` and
left stopped, or — where the user unit `podman-restart.service` is enabled *and* a legacy container's
restart policy is exactly `always`, because `podman start --all --filter restart-policy=always` would
then revive it at the next boot and a second PostgreSQL would open `odoo18-db-data` — captured into
the backup directory and removed. `ql_rollback_strategy` decides from the host's real state, never
from its name, and `--dry-run` reports which path a cutover would take. The capture is taken in the
prepare phase, before any downtime, so a container that cannot be replayed is discovered while the
legacy stack is still serving. `odoo18-db` and `odoo18-web` are `unless-stopped` today, so both
hosts currently resolve to `rename`; `--force-capture` exercises the other path.

**What the backup holds** (`~/.local/share/woow-backups/odoo18/migrate-<stamp>/`, 0700):
`roles.sql`, `databases/<db>.dump` plus `COUNT` and `LIST`, a cold `podman volume export` of both
volumes, `inspect.json`, the legacy `odoo.conf` and unit files, `volume-fingerprints`,
`precheck.txt` and `SHA256SUMS` — and `legacy-container/` on the capture path.

**Adoption is proved, not assumed.** The `CreatedAt` and the on-disk inode of both volumes are
recorded before the cutover and compared after `install.sh`. If the new containers are not on the
legacy volumes the migration fails and rolls back, rather than reporting a healthy Odoo sitting on
an empty database.

**Downtime** is measured by the script, from stopping the legacy stack to `install.sh` returning,
and printed at the end (and recorded as `DOWNTIME_S` in `--status`).

### Rolling back

```bash
scripts/migrate-legacy.sh --rollback
```

It stops and removes the Quadlet units (volumes, network and secrets are kept, because both stacks
share them), removes any container this repo's units left behind, brings the legacy containers back
— renamed back, or recreated from the capture with their original restart policy — re-enables the
legacy units it disabled, starts the database before the web container, and waits for
`/web/health` on the legacy address. A failed cutover rolls itself back automatically unless
`--no-auto-rollback` was given.

### After the soak

Once the Quadlet stack has run long enough, remove the legacy containers
(`podman rm odoo18-db-legacy-<suffix> odoo18-web-legacy-<suffix>`), the hand-written `odoo18.service`,
`odoo18-health.service` and `odoo18-health.timer` (that also retires the health check that fired
every 10 seconds), and the old `.runtime/` directory — `shred` its secret files; the passwords now
live in podman's secret store. Keep the migration backup until you are sure.

## Files

```
quadlet/                      Quadlet units with @@VAR@@ tokens; quadlet/render-vars is the whitelist
config/odoo18.env.example     template for ~/.config/odoo18/odoo18.env
config/odoo.conf.template     rendered into the odoo18-odoo-conf secret (never onto disk)
scripts/install.sh            install/update; also the "apply my changes" command
scripts/upgrade.sh            backup, unit snapshot, install, pgvector update, smoke, rollback
scripts/backup.sh restore.sh  validated archives; scripts/validate-backup.py, make-roles-idempotent.py
scripts/rotate-secrets.sh     rotate the database and master passwords
scripts/migrate-legacy.sh     adopt a running compose deployment; --rollback, --status
scripts/legacy-helpers.sh     the helpers migrate-legacy.sh uses (kept out of common.sh, which is
                              byte-identical across four repos below its settings block)
scripts/lib/                  vendored quadlet-lib (do not edit; CI checks its hash)
tests/dryrun.sh               render + Quadlet 4.9.3 dry-run + systemd-analyze verify (CI and local)
tests/run.sh                  Python unit tests for the validator, the roles preparer and the template
tests/migrate-model.sh        pins the migration: both rollback strategies, the dependency order, the
                              empty-database case, the adoption proof (podman/systemctl are shims)
tests/smoke.sh                post-install checks on a host
tests/lint-repo.sh            credential scan, leaked-value gate, image-pin parity, README checks (CI)
docs/plans/                   design history, including the hardened deployment this repo grew from
```

## Troubleshooting

| Symptom | Check |
|---|---|
| `install.sh` says `odoo18.service` is active | The compose-era deployment is still running. Follow the migration section. |
| `install.sh` says a container exists and is not managed | Rename it with the printed command, or remove it after a backup. |
| `install.sh` says the database role does not accept the recorded password | The volume `odoo18-db-data` was initialised earlier, so it kept its original password (`POSTGRES_PASSWORD_FILE` only applies to an empty volume). Run `scripts/rotate-secrets.sh --db`. |
| Odoo starts, then exits with a database error | `journalctl --user -u odoo.service -n 100`. On the very first start the database may still be initialising; Odoo retries and systemd restarts it. |
| `Access Denied` in the database manager | Use the `odoo18-admin-password` secret, not `admin`. |
| An addon does not show up | `chmod -R o+rX` on the addons directory, then restart `odoo.service` and update the module. |
| Units gone after logout or reboot | `loginctl show-user $USER -p Linger` must say `yes`. |
