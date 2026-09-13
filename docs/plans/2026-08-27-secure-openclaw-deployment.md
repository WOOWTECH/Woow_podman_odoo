# Secure OpenClaw Odoo Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a reproducible, rootless Odoo 18/PostgreSQL 16 + pgvector deployment that keeps Odoo on host loopback, keeps PostgreSQL private, generates private independent credentials, and provides safe idempotent lifecycle operations.

**Architecture:** Replace the custom PostgreSQL build and mutable image tags with digest-pinned upstream images on one project bridge, publishing only Odoo as `127.0.0.1:18069:8069`. A small Bash lifecycle layer will generate and ownership-map mode-`600` secrets/config for rootless Podman, start PostgreSQL before Odoo without relying on unsupported Compose condition semantics, verify exact labeled resources, and install a user-systemd unit. Standard-library Python tests plus opt-in live checks will drive static configuration, lifecycle, backup/restore, local readiness, persistence, and remote tailnet behavior.

**Tech Stack:** Odoo 18.0 Community, PostgreSQL 16, pgvector 0.8.0, rootless Podman 4.9.3, podman-compose 1.0.6, Bash, Python 3 standard library, user systemd, Headscale/Tailscale TCP forwarding

---

## Fixed implementation decisions

- Use these immutable multi-architecture image references (resolved from Docker Hub on 2026-08-27):
  - `docker.io/library/odoo:18.0@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67`
  - `docker.io/pgvector/pgvector:0.8.0-pg16@sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9`
- Keep the Compose project and all explicit resource names at `odoo18`; every container, volume, and network also carries `io.woowtech.stack=odoo18` and `io.woowtech.owner=<numeric host uid>` labels. Lifecycle code must refuse to mutate a same-named resource unless both labels match exactly.
- Do not publish a PostgreSQL port. The only host mapping is the literal `127.0.0.1:18069:8069`; it is not configurable through `.env`.
- Do not depend on Compose v2 features, Compose secrets, `depends_on.condition`, `podman compose`, or `podman generate systemd`. They are not dependable with Podman 4.9.3/podman-compose 1.0.6. Use simple `depends_on`, `podman-compose`, `podman inspect`, and an explicit DB readiness wait in the deployment script.
- Generate two independent random 32-byte base64 values: `.runtime/secrets/postgres_password` and `.runtime/secrets/odoo_admin_password`. Render both into `.runtime/config/odoo.conf` as `db_password` and `admin_passwd`, respectively; never pass either secret on a command line or in a Compose environment value.
- Use `umask 077` and mode `600` for all three files. Under `podman unshare`, map the PostgreSQL secret to `999:999`, the rendered Odoo config to `100:101`, and keep the Odoo admin secret at namespace owner `0:0`. Verify the pinned images still report `postgres=999:999` and `odoo=100:101` before applying ownership; fail closed if they do not.
- Bind the PostgreSQL password file read-only to `/run/secrets/postgres_password` and set only `POSTGRES_PASSWORD_FILE` in the environment. Bind the generated Odoo config read-only to `/etc/odoo/odoo.conf`. Use `:Z,ro` on both bind mounts for SELinux-compatible rootless operation.
- Preserve named database and filestore volumes on deploy, restart, backup, restore, and default removal. Data deletion requires the explicit `remove.sh --purge-data` flag.
- Treat remote access as a separate opt-in live gate: the local deployment is not successful merely because a remote URL was supplied, and CI must never guess or require a tailnet hostname.

### Task 1: Add the standard-library test harness and lock the Compose topology

**Files:**
- Create: `tests/__init__.py`
- Create: `tests/test_compose.py`
- Create: `tests/run.sh`
- Modify: `docker-compose.yml`
- Delete: `postgres/Dockerfile`
- Modify: `.env.example`

**Step 1: Write the failing Compose contract tests**

In `tests/test_compose.py`, use `unittest` and direct text/regular-expression assertions so the static tests do not need PyYAML. Cover:

```python
ODOO_IMAGE = "docker.io/library/odoo:18.0@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67"
DB_IMAGE = "docker.io/pgvector/pgvector:0.8.0-pg16@sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9"

class ComposeContractTest(unittest.TestCase):
    def test_images_are_release_and_digest_pinned(self): ...
    def test_only_odoo_loopback_port_is_published(self): ...
    def test_db_has_no_ports_key(self): ...
    def test_password_uses_file_and_not_plain_environment(self): ...
    def test_generated_config_and_secret_mounts_are_read_only(self): ...
    def test_db_and_web_have_healthchecks(self): ...
    def test_every_resource_has_stack_and_owner_labels(self): ...
    def test_custom_postgres_build_is_gone(self): ...
```

Assert the exact image strings, exact `127.0.0.1:18069:8069` mapping, absence of `${ODOO_PORT`, absence of a `ports:` block within `db`, absence of `POSTGRES_PASSWORD=`, presence of `POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password`, and absence of `admin_passwd = admin` anywhere outside `.git` and the plans.

Create `tests/run.sh` as:

```bash
#!/usr/bin/env bash
set -euo pipefail
exec python3 -m unittest discover -s tests -p 'test_*.py' -v
```

**Step 2: Run the tests to verify they fail**

Run: `bash tests/run.sh`

Expected: FAIL because the current Compose file builds PostgreSQL, uses mutable `odoo:18`, publishes a wildcard port, and lacks health checks and private mounts.

**Step 3: Write the minimal pinned Compose file**

Replace the DB build with `DB_IMAGE`, replace the web image with `ODOO_IMAGE`, and include:

```yaml
services:
  db:
    image: docker.io/pgvector/pgvector:0.8.0-pg16@sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9
    container_name: odoo18-db
    environment:
      POSTGRES_USER: odoo
      POSTGRES_DB: postgres
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    volumes:
      - odoo-db-data:/var/lib/postgresql/data
      - ./.runtime/secrets/postgres_password:/run/secrets/postgres_password:Z,ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 5s
      timeout: 3s
      retries: 24
  web:
    image: docker.io/library/odoo:18.0@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67
    container_name: odoo18-web
    depends_on: [db]
    ports: ["127.0.0.1:18069:8069"]
    volumes:
      - odoo-web-data:/var/lib/odoo
      - ./addons:/mnt/extra-addons:Z,ro
      - ./.runtime/config/odoo.conf:/etc/odoo/odoo.conf:Z,ro
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8069/web/health', timeout=3)"]
      interval: 10s
      timeout: 5s
      retries: 30
```

Retain the named bridge and named volumes, add the two ownership labels to both services and all top-level resources, and interpolate only `${ODOO_DEPLOY_UID:?set by scripts/deploy.sh}` into owner labels. Delete `postgres/Dockerfile`. Reduce `.env.example` to documented, non-secret metadata; it must not invite checked-in passwords or port overrides.

**Step 4: Run the tests and render with the supported Compose version**

Run: `ODOO_DEPLOY_UID="$(id -u)" podman-compose -f docker-compose.yml config > /tmp/odoo18-compose.yml && bash tests/run.sh`

Expected: podman-compose 1.0.6 exits 0; tests PASS; rendered YAML contains only `127.0.0.1:18069:8069` and no DB host binding.

**Step 5: Commit**

```bash
git add docker-compose.yml .env.example tests postgres/Dockerfile
git commit -m "feat: pin private Odoo compose topology"
```

### Task 2: Generate independent secrets and the private Odoo runtime config

**Files:**
- Create: `config/odoo.conf.template`
- Delete: `config/odoo.conf`
- Create: `scripts/lib.sh`
- Create: `scripts/render-config.sh`
- Create: `tests/test_runtime_config.py`
- Modify: `.gitignore`

**Step 1: Write failing runtime-generation tests**

Use a temporary project root and fake `podman` executable in `tests/test_runtime_config.py`. The fake must implement `podman unshare chown`, `stat`, and image user lookup calls while logging arguments but never file contents. Test that:

- first run creates two distinct secrets with at least 43 base64 characters;
- rerun preserves both secrets byte-for-byte;
- rendered config contains each value in only its correct field and never the old literal `admin`;
- config includes `db_host = db`, `db_port = 5432`, `db_user = odoo`, `db_name = postgres`, and the existing operational settings;
- all runtime files report mode `600`;
- namespace ownership is exactly `999:999` for the DB secret, `100:101` for Odoo config, and `0:0` for the admin secret;
- a mismatch between image account IDs and `999:999`/`100:101` aborts without replacing existing files;
- stdout/stderr and fake-command logs contain neither secret.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_runtime_config -v`

Expected: FAIL because `scripts/render-config.sh` and the template do not exist.

**Step 3: Implement the renderer and shared library**

In `scripts/lib.sh`, establish `set -euo pipefail`, `umask 077`, canonical project/runtime paths, overridable test-only command variables (`PODMAN_BIN`, `PODMAN_COMPOSE_BIN`, `SYSTEMCTL_BIN`), `die`, quiet secret-safe logging, mode/namespace-owner assertions, and atomic file replacement.

In `scripts/render-config.sh`:

1. Create `.runtime/secrets` and `.runtime/config` as the invoking user with mode `700`.
2. Verify image account IDs with secret-free `podman run --rm --entrypoint sh IMAGE -c 'id -u postgres; id -g postgres'` and the corresponding `odoo` lookup.
3. Generate each absent secret with `openssl rand -base64 32` into a mode-`600` temporary file; do not regenerate an existing valid secret.
4. Read values through redirected file descriptors, render `config/odoo.conf.template` without putting values in process arguments, and atomically install the result.
5. Run `podman unshare chown 999:999` on the DB secret and `podman unshare chown 100:101` on Odoo config. Keep the admin secret namespace-owned by `0:0`.
6. Verify all three modes and owners after every run and print only paths/status.

The tracked template must contain placeholders `@POSTGRES_PASSWORD@` and `@ODOO_ADMIN_PASSWORD@`; it must not contain a usable default password.

Update `.gitignore` with:

```gitignore
.runtime/
backups/
```

**Step 4: Run focused and full tests**

Run: `python3 -m unittest tests.test_runtime_config -v && bash tests/run.sh`

Expected: PASS, including preservation, permissions, exact ownership, and no-leak tests.

**Step 5: Commit**

```bash
git add .gitignore config scripts/lib.sh scripts/render-config.sh tests/test_runtime_config.py
git commit -m "feat: generate private Odoo runtime configuration"
```

### Task 3: Implement idempotent deployment and readiness sequencing

**Files:**
- Create: `scripts/deploy.sh`
- Create: `tests/test_deploy.py`
- Modify: `scripts/lib.sh`

**Step 1: Write failing deployment tests with fake Podman tools**

In `tests/test_deploy.py`, use temporary executable fakes that return scripted `podman inspect` JSON/fields and record operation order. Test:

- unsupported Podman or podman-compose versions fail before mutation, while exactly `4.9.3` and `1.0.6` pass;
- a clean deploy calls the renderer, checks exact name/labels, runs `podman-compose up -d db`, waits until DB health is `healthy`, then runs `podman-compose up -d web`;
- timeout or `unhealthy` DB status prevents web startup and prints DB diagnostics without secrets;
- rerunning deploy neither rotates secrets nor recreates volumes;
- a same-named container, network, or volume with a missing/wrong stack or owner label causes a refusal, not adoption/removal;
- a healthy rerun converges successfully;
- no command includes password text.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_deploy -v`

Expected: FAIL because `scripts/deploy.sh` does not exist.

**Step 3: Implement deployment with Podman 4.9.3-compatible primitives**

Implement `scripts/deploy.sh` with these ordered phases:

1. Require non-root execution, `podman --version` at least 4.9.3, `podman-compose --version` exactly compatible with 1.0.x (test baseline 1.0.6), `openssl`, `curl`, `python3`, and user systemd unless `--no-systemd` is selected by tests/service startup.
2. Export `ODOO_DEPLOY_UID=$(id -u)`; never source `.env`.
3. Render secrets/config and validate existing exact-name resources via `podman inspect --format` labels before any `up` call.
4. Run `podman-compose -p odoo18 -f docker-compose.yml up -d db`.
5. Poll `podman inspect --format '{{.State.Health.Status}}' odoo18-db` for up to 120 seconds. Do not use `depends_on.condition` or `podman wait`.
6. Run the same Compose command for `web`, then poll the web health status for up to 300 seconds.
7. Invoke local verification from Task 4.
8. On repeat runs, use the same project/name/labels and leave secrets and named volumes untouched.

Provide `--no-systemd` only as an internal/test/systemd recursion guard. Normal interactive deployment installs/enables the unit after Task 5 adds it.

**Step 4: Run focused and full tests**

Run: `python3 -m unittest tests.test_deploy -v && bash tests/run.sh`

Expected: PASS; operation logs prove `db healthy` occurs before the web `up` call.

**Step 5: Commit**

```bash
git add scripts/deploy.sh scripts/lib.sh tests/test_deploy.py
git commit -m "feat: add idempotent rootless deployment"
```

### Task 4: Verify local health, connectivity, ownership, and restart persistence

**Files:**
- Create: `scripts/verify.sh`
- Create: `tests/test_verify.py`
- Create: `tests/live-local.sh`
- Modify: `scripts/deploy.sh`

**Step 1: Write failing verification tests**

Test fake inspect/curl/exec output in `tests/test_verify.py`. Require verification to fail independently when:

- either expected container is absent, not running, or not healthy;
- any exact resource has wrong `io.woowtech.stack` or `io.woowtech.owner`;
- DB/image volume ownership differs from `999:999`, Odoo filestore ownership differs from `100:101`, or runtime ownership/mode differs from Task 2;
- `pg_isready` fails, `SELECT 1` fails, or `pg_available_extensions` does not report `vector` version `0.8.0`;
- `http://127.0.0.1:18069/web/health` does not return success and the root route does not return a valid Odoo HTTP response/redirect;
- `podman port odoo18-web 8069` differs from `127.0.0.1:18069`, or DB has any host port;
- inspect output, process arguments, tracked files, or captured logs contain either generated secret.

Also test `--restart-persistence`: capture checksums of both secrets, stop/start the user service (or Compose in test mode), and assert unchanged secret checksums, healthy services, successful `SELECT 1`, and the same Odoo filestore marker after restart.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_verify -v`

Expected: FAIL because `scripts/verify.sh` does not exist.

**Step 3: Implement local verification**

Use exact `podman inspect`, `podman volume inspect`, `podman network inspect`, `podman exec`, `podman port`, and `curl --noproxy '*'` calls. Query PostgreSQL without putting a password in argv; local container authentication and the configured `_FILE` mechanism supply what is needed. Check `pg_available_extensions` first, then create `vector` only in a disposable verification database, query `extversion`, and drop that database so verification does not modify application databases.

Make default verification read-only except for the disposable extension compatibility probe. Put the slower destructive/restart sequence behind `--restart-persistence`. `tests/live-local.sh` should call deploy, verify, restart-persistence verification, and verify once more.

**Step 4: Run focused and full tests**

Run: `python3 -m unittest tests.test_verify -v && bash tests/run.sh`

Expected: PASS with one assertion per security/readiness/persistence property.

On a Podman 4.9.3 test host also run: `bash tests/live-local.sh`

Expected: PASS; both services are healthy, PostgreSQL is not published, Odoo is loopback-only, pgvector 0.8.0 loads, and data/credentials survive restart.

**Step 5: Commit**

```bash
git add scripts/deploy.sh scripts/verify.sh tests/test_verify.py tests/live-local.sh
git commit -m "feat: verify Odoo readiness and persistence"
```

### Task 5: Install an idempotent rootless user-systemd service

**Files:**
- Create: `systemd/odoo18.service.in`
- Create: `scripts/install-systemd.sh`
- Create: `scripts/service.sh`
- Create: `tests/test_systemd.py`
- Modify: `scripts/deploy.sh`

**Step 1: Write failing user-systemd tests**

Test that installation:

- refuses root/system scope and writes only `$HOME/.config/systemd/user/odoo18.service`;
- substitutes the canonical repository path safely into `WorkingDirectory`, `ExecStart`, and `ExecStop`;
- uses `Type=oneshot`, `RemainAfterExit=yes`, `After=network-online.target`, and `Wants=network-online.target`;
- starts via `scripts/service.sh start` and stops containers without deleting volumes via `scripts/service.sh stop`;
- runs `systemctl --user daemon-reload` and `enable --now odoo18.service` only when content/state requires it;
- gives the same result on a second installation;
- detects disabled lingering and prints the exact administrator command `loginctl enable-linger <user>` without attempting privileged escalation.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_systemd -v`

Expected: FAIL because the template and installer do not exist.

**Step 3: Implement the unit, installer, and service wrapper**

`systemd/odoo18.service.in` must call `scripts/service.sh start`/`stop`; `start` delegates to `deploy.sh --no-systemd`, while `stop` uses `podman-compose ... stop` after exact label validation. Do not use `sudo`, a system unit, generated Podman units, or `compose down` on routine stop.

Render the unit atomically with mode `644`. Normal `scripts/deploy.sh` should install/enable it after runtime prerequisites are ready; service re-entry uses `--no-systemd` to avoid recursion. Check lingering with `loginctl show-user "$USER" -p Linger --value`; document that an administrator may need to enable it once for boot startup.

**Step 4: Run focused and full tests**

Run: `python3 -m unittest tests.test_systemd -v && bash tests/run.sh`

Expected: PASS; a repeat install produces no content change and no destructive Compose action.

**Step 5: Commit**

```bash
git add systemd scripts/install-systemd.sh scripts/service.sh scripts/deploy.sh tests/test_systemd.py
git commit -m "feat: run Odoo with user systemd"
```

### Task 6: Add private, validated, idempotent backup and restore

**Files:**
- Create: `scripts/backup.sh`
- Create: `scripts/restore.sh`
- Create: `scripts/validate-backup.py`
- Create: `tests/test_backup_restore.py`
- Create: `tests/fixtures/README.md`

**Step 1: Write failing backup/restore tests**

Use fake Podman commands and temporary archives. Test:

- backup creates a mode-`600` archive under a mode-`700` `backups/` directory;
- archive contains a PostgreSQL custom-format dump, filestore, generated Odoo config, separate admin-secret recovery copy, metadata (image digests/project/UTC timestamp), and SHA-256 manifest;
- PostgreSQL data is obtained with `pg_dump --format=custom` and filestore is copied from the exact labeled volume, without pausing or mutating application data;
- two backup invocations produce separate timestamped archives and do not alter running state;
- validator rejects absolute paths, `..` traversal, duplicate/conflicting paths, symlinks, hardlinks, devices/FIFOs, unexpected top-level entries, checksum mismatches, and over-limit member count/expanded size;
- restore validates fully before stopping services or writing a byte;
- restore stages extraction on the same filesystem, creates an automatic pre-restore backup, restores DB with `pg_restore --clean --if-exists`, replaces filestore/config atomically, reapplies exact `999:999`/`100:101` ownership and mode `600`, then deploys/verifies;
- failed validation is a no-op; failed restore retains the pre-restore archive and reports recovery instructions without deleting current volumes;
- rerunning restore with the same archive converges to the same checksums and healthy result;
- logs/argv never expose secrets.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_backup_restore -v`

Expected: FAIL because backup, validator, and restore scripts do not exist.

**Step 3: Implement backup and strict pre-extraction validation**

Use `umask 077`, a private staging directory, and an outer uncompressed tar (or tar.gz only after enforcing an expanded-size limit). `scripts/validate-backup.py` must inspect every `TarInfo` before extraction, permit only regular files/directories under one expected root, normalize names with `PurePosixPath`, reject links and special files, enforce member/size ceilings, and verify the manifest. Only then extract into a new private staging directory.

Back up all databases/roles needed to reconstruct Odoo, the full Odoo named volume, generated config, and the independent admin recovery secret. Do not copy the live PostgreSQL data directory. Never write secrets into metadata or console output.

**Step 4: Implement restore and run tests**

Restore only into resources whose exact stack/owner labels match. Require `--archive <path>` and an explicit `--confirm-restore odoo18`; these are safety gates, not non-idempotent prompts. Preserve the supplied archive and pre-restore backup. Apply ownership in the rootless Podman user namespace before restarting.

Run: `python3 -m unittest tests.test_backup_restore -v && bash tests/run.sh`

Expected: PASS, including malicious fixture rejection before mutation and repeat-restore convergence.

**Step 5: Commit**

```bash
git add scripts/backup.sh scripts/restore.sh scripts/validate-backup.py tests/test_backup_restore.py tests/fixtures
git commit -m "feat: add validated Odoo backup and restore"
```

### Task 7: Add safe, scoped, idempotent removal

**Files:**
- Create: `scripts/remove.sh`
- Create: `tests/test_remove.py`

**Step 1: Write failing removal tests**

Test three cases:

1. Default removal disables/stops the user unit and removes only the two exact labeled containers and project network; it preserves named volumes, `.runtime`, and `backups`.
2. `--purge-data --confirm-purge odoo18` additionally removes only the exact labeled project volumes and `.runtime`, but still preserves `backups`.
3. Missing resources return success, while a same-named resource with wrong/missing labels fails closed and remains untouched.

Assert no broad prune command, wildcard, `podman system reset`, or unrelated resource name is ever invoked.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_remove -v`

Expected: FAIL because `scripts/remove.sh` does not exist.

**Step 3: Implement scoped removal**

Validate every present exact-name resource before the first mutation. Use `systemctl --user disable --now odoo18.service` idempotently, remove exact containers/network, and leave data/runtime by default. Require both purge flags before removing the two named volumes and private runtime tree. Never remove backups automatically.

**Step 4: Run focused and full tests**

Run: `python3 -m unittest tests.test_remove -v && bash tests/run.sh`

Expected: PASS; repeated default and purge removals both exit 0, and foreign resources are untouched.

**Step 5: Commit**

```bash
git add scripts/remove.sh tests/test_remove.py
git commit -m "feat: add scoped idempotent removal"
```

### Task 8: Add local and remote live acceptance gates

**Files:**
- Create: `tests/live-remote.sh`
- Create: `tests/test_live_gates.py`
- Modify: `tests/live-local.sh`
- Modify: `scripts/verify.sh`

**Step 1: Write failing gate tests**

Test that `tests/live-remote.sh`:

- skips with exit 77 unless `ODOO_REMOTE_URL` is explicitly set;
- accepts only `http://` or `https://` URLs whose host is not localhost, `127.0.0.0/8`, `::1`, or an unspecified/wildcard address;
- calls local verification first;
- uses `curl --fail --show-error --location --connect-timeout 10 --max-time 30` against `${ODOO_REMOTE_URL%/}/web/health` and the root route;
- reports only URL/status/timing, never credentials;
- cannot pass by accidentally reaching the local loopback listener.

Keep `tests/live-local.sh` explicit and destructive-test aware; it may run restart-persistence but must not run restore/purge.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_live_gates -v`

Expected: FAIL because the remote gate does not exist.

**Step 3: Implement the remote Headscale/Tailscale gate**

Parse and validate the URL with Python's `urllib.parse` and `ipaddress`, run `scripts/verify.sh`, then curl the configured gateway URL. The external Headscale/Tailscale TCP forward itself remains gateway infrastructure and is not created by this repository; the gate proves that tailnet TCP `18069` reaches host loopback `18069` after an operator configures it.

Document the invocation shape in script help:

```bash
ODOO_REMOTE_URL=http://odoo-gateway.<tailnet>:18069 bash tests/live-remote.sh
```

**Step 4: Run test suites and both live gates**

Run: `bash tests/run.sh`

Expected: PASS.

Run on the target Podman 4.9.3 host: `bash tests/live-local.sh`

Expected: PASS.

Run from a tailnet-connected client after the gateway forward exists: `ODOO_REMOTE_URL=http://<gateway-tailnet-name>:18069 bash tests/live-remote.sh`

Expected: PASS; `/web/health` and the Odoo root route are reachable over the tailnet. Record a skipped gate as SKIP, never PASS, when the URL or gateway is unavailable.

**Step 5: Commit**

```bash
git add scripts/verify.sh tests/live-local.sh tests/live-remote.sh tests/test_live_gates.py
git commit -m "test: gate local and tailnet Odoo access"
```

### Task 9: Replace insecure instructions with bilingual operations documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/skills/deploy-odoo18.md`
- Modify: `docs/DEPLOYMENT_RECORD.md`
- Create: `tests/test_docs.py`

**Step 1: Write failing documentation contract tests**

Test all tracked non-plan documentation for absence of:

- `admin_passwd = admin`, a published `5432`, wildcard `18069:8069`, mutable `odoo:18`, custom pgvector Git clone/build instructions, `docker compose`, and instructions to put passwords in `.env`;
- Portainer claims that bypass runtime rendering, ownership mapping, or user-systemd;
- public proxy/Nginx Proxy Manager setup claims not present in the approved design.

Require both English and Traditional Chinese headings/instructions for prerequisites, deploy, verify, user-systemd/lingering, local URL, tailnet-only remote gate, backup, restore, safe removal/purge, upgrades/digest rotation, troubleshooting, and security boundary.

**Step 2: Run the focused test to verify it fails**

Run: `python3 -m unittest tests.test_docs -v`

Expected: FAIL because current docs advertise `.env` passwords, wildcard publication, mutable images, Portainer, and master password `admin`.

**Step 3: Rewrite docs in English and Traditional Chinese**

In both languages, document:

- exact supported versions: rootless Podman 4.9.3 and podman-compose 1.0.6;
- `scripts/deploy.sh`, `verify.sh`, `backup.sh`, `restore.sh`, and `remove.sh` command examples and idempotency/data-preservation behavior;
- generated credentials, mode/ownership model, and a safe operator command that reads the Odoo admin secret through `podman unshare` without printing it in routine logs;
- `http://127.0.0.1:18069`, no PostgreSQL host port, and why remote users must use the configured Headscale/Tailscale gateway;
- how to enable/check user lingering, run local acceptance, and run the explicit remote gate;
- archive validation and the destructive confirmation flags;
- digest upgrades as a reviewed change to both release tag and digest followed by the complete test/live matrix, never an automatic floating pull.

Replace the stale skill file rather than leaving contradictory Docker/Portainer instructions. Make `docs/DEPLOYMENT_RECORD.md` a reproducible evidence template: commit, host versions, image IDs/digests, local gate result, remote gate result or explicit SKIP reason, backup/restore drill result, date, and operator. Do not fabricate live results.

**Step 4: Run documentation and full tests**

Run: `python3 -m unittest tests.test_docs -v && bash tests/run.sh`

Expected: PASS; no tracked operational doc contains an insecure legacy path.

**Step 5: Commit**

```bash
git add README.md docs/skills/deploy-odoo18.md docs/DEPLOYMENT_RECORD.md tests/test_docs.py
git commit -m "docs: add bilingual secure Odoo operations"
```

### Task 10: Run the complete supported-version acceptance matrix

**Files:**
- Modify: `docs/DEPLOYMENT_RECORD.md` (only with observed results)

**Step 1: Run static/unit tests from a clean checkout**

Run: `bash tests/run.sh`

Expected: PASS with no skipped unit/static tests.

**Step 2: Run syntax and Compose compatibility checks**

Run:

```bash
find scripts tests -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
ODOO_DEPLOY_UID="$(id -u)" podman-compose -f docker-compose.yml config >/tmp/odoo18-compose.yml
podman --version
podman-compose --version
```

Expected: all syntax/config commands exit 0; versions report Podman 4.9.3 and podman-compose 1.0.6.

**Step 3: Run local lifecycle acceptance twice**

Run:

```bash
scripts/deploy.sh
scripts/deploy.sh
scripts/verify.sh --restart-persistence
scripts/backup.sh
# Restore the just-created archive using the documented explicit confirmation.
scripts/restore.sh --archive backups/<observed-archive> --confirm-restore odoo18
scripts/verify.sh
scripts/remove.sh
scripts/deploy.sh
scripts/verify.sh
```

Expected: every command exits 0; redeploy preserves credentials/data; backup is private; restore converges; default removal preserves volumes/runtime; redeploy recovers the same healthy data.

**Step 4: Run the remote live gate or record an explicit skip**

Run from a tailnet client:

```bash
ODOO_REMOTE_URL=http://<gateway-tailnet-name>:18069 bash tests/live-remote.sh
```

Expected: PASS when gateway forwarding is configured. If live infrastructure is unavailable, record `SKIP` plus the reason in `docs/DEPLOYMENT_RECORD.md`; do not weaken or mock this gate and do not claim remote acceptance.

**Step 5: Check secret leakage, scope, and repository state**

Run:

```bash
scripts/verify.sh
git grep -n -E 'admin_passwd[[:space:]]*=[[:space:]]*admin|POSTGRES_PASSWORD=' -- ':!docs/plans/*'
git status --short
```

Expected: verification PASS; grep prints nothing; only the evidence update is modified before its commit; `.runtime/` and `backups/` are untracked/ignored.

**Step 6: Commit observed evidence**

```bash
git add docs/DEPLOYMENT_RECORD.md
git commit -m "test: record secure Odoo deployment acceptance"
```

Do not make this commit if no record fields changed. Never record generated credentials, archive contents, tailnet authentication material, or other secrets.
