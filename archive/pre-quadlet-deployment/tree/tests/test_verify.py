import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class VerifyBehaviorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        for script in ("verify.sh", "lib.sh", "odoo-healthcheck.py"):
            shutil.copy(ROOT / "scripts" / script, self.root / "scripts" / script)
        for directory in (".runtime/secrets", ".runtime/config"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.db_secret = "db-secret-value"
        self.admin_secret = "admin-secret-value"
        (self.root / ".runtime/secrets/postgres_password").write_text(self.db_secret + "\n")
        (self.root / ".runtime/secrets/odoo_admin_password").write_text(self.admin_secret + "\n")
        (self.root / ".runtime/config/odoo.conf").write_text("[options]\n")
        for path in (self.root / ".runtime").rglob("*"):
            if path.is_file(): path.chmod(0o600)
        self.log = self.root / "podman.log"
        self.marker = self.root / "persisted-marker"
        podman = self.root / "podman"
        podman.write_text(r'''#!/usr/bin/env bash
printf 'podman' >>"$FAKE_LOG"; printf ' <%s>' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
kind=$1
if [[ $kind == container || $kind == network || $kind == volume ]]; then
  [[ $2 == inspect ]] || exit 2
  name=${@: -1}; [[ ${MISSING_RESOURCE:-} == "$name" ]] && exit 1
  [[ $3 != --format ]] && exit 0
  format=$4
  if [[ $format == *Mountpoint* ]]; then echo "/volumes/$name"; exit; fi
  [[ ${FOREIGN_RESOURCE:-} == "$name" ]] && echo "other 9999" || echo "odoo18 $ODOO_DEPLOY_UID"
  exit
fi
case "$kind" in
 inspect)
   if [[ $2 == --format ]]; then
     format=$3; name=$4
     [[ $format == *State.Running* ]] && { [[ ${STOPPED_CONTAINER:-} == "$name" ]] && echo false || echo true; }
     if [[ $format == *State.Health.Status* ]]; then
       if [[ ${UNHEALTHY_CONTAINER:-} == "$name" ]]; then echo unhealthy
       elif [[ ${SCHEDULER_FAILURE:-0} == 1 && ! -e "$FAKE_MARKER.health-$name" ]]; then echo starting
       else echo healthy
       fi
     fi
     exit 0
   else
     [[ ${LEAK_CHANNEL:-} == inspect ]] && printf '%s\n' "$FAKE_DB_SECRET" || echo '[]'
   fi;;
 healthcheck)
   [[ $2 == run ]] || exit 2
   [[ ${MANUAL_HEALTH_FAILURE:-} == "$3" ]] || touch "$FAKE_MARKER.health-$3";;
 unshare)
   action=$2; target=${@: -1}
   case $action in
     stat)
       case $target in
         *postgres_password) [[ ${BAD_RUNTIME:-} == db ]] && echo 1:1 || echo 999:999;;
         *odoo_admin_password) [[ ${BAD_RUNTIME:-} == admin ]] && echo 1:1 || echo 0:0;;
         *odoo.conf) [[ ${BAD_RUNTIME:-} == config ]] && echo 1:1 || echo 100:101;;
         *odoo-healthcheck.py) [[ ${BAD_RUNTIME:-} == helper ]] && echo 1:1 || echo 0:0;;
         *odoo18-db-data) [[ ${BAD_VOLUME:-} == db ]] && echo 1:1 || echo 999:999;;
         */filestore) [[ ${BAD_VOLUME:-} == filestore ]] && echo 1:1 || echo 100:101;;
         *odoo18-web-data) [[ ${BAD_VOLUME:-} == web ]] && echo 1:1 || echo 100:101;;
       esac;;
     cat) cat "$target";;
     python3)
       if [[ ${MISSING_FILESTORE:-0} == 1 ]]; then echo 'ERROR: missing filestore directory' >&2; exit 1; fi
       if [[ ${BAD_VOLUME:-} == filestore ]]; then echo 'ERROR: wrong filestore ownership' >&2; exit 1; fi
       if [[ ${BAD_FILESTORE_MODE:-0} == 1 ]]; then echo 'ERROR: wrong filestore mode' >&2; exit 1; fi
       if [[ ${SYMLINK_FILESTORE:-0} == 1 ]]; then echo 'ERROR: filestore is not a safe directory' >&2; exit 1; fi;;
     test) [[ ${MISSING_FILESTORE:-0} != 1 ]];;
     sha256sum) /usr/bin/sha256sum "${@:3}";;
   esac;;
 exec)
   shift; container=$1; shift
   if [[ $container == odoo18-db ]]; then
     case "$*" in
       *pg_isready*) [[ ${DB_FAILURE:-} != ready ]];;
       *pg_available_extensions*) [[ ${DB_FAILURE:-} == available ]] && echo missing || echo 0.8.0;;
       *'CREATE EXTENSION vector'*) [[ ${DB_FAILURE:-} == extension ]] && echo wrong || echo 0.8.0;;
       *'SELECT 1'*) [[ ${DB_FAILURE:-} == query ]] && echo 0 || echo 1;;
     esac
   elif [[ $container == odoo18-web ]]; then
     if [[ $1 == sh && $* == *'/var/lib/odoo/filestore/.persistence-marker'* ]]; then
       [[ ${PERSISTENCE_FAILURE:-0} == 1 ]] || printf '%s' "${@: -1}" >"$FAKE_MARKER"
     elif [[ $1 == cat && $2 == /var/lib/odoo/filestore/.persistence-marker ]]; then
       [[ -f "$FAKE_MARKER" ]] && cat "$FAKE_MARKER"
     fi
   fi;;
 port)
   if [[ $2 == odoo18-web ]]; then echo "${WEB_PORT:-127.0.0.1:18069}"
   elif [[ -n ${DB_PORT:-} ]]; then echo "$DB_PORT"; fi;;
 top) [[ ${LEAK_CHANNEL:-} == process ]] && echo "$FAKE_ADMIN_SECRET" || echo process;;
 logs) [[ ${LEAK_CHANNEL:-} == logs ]] && echo "$FAKE_DB_SECRET" || echo diagnostics;;
 esac
''')
        podman.chmod(0o755)
        curl = self.root / "curl"
        curl.write_text(r'''#!/usr/bin/env bash
if [[ $* == *'/web/health'* && ${HTTP_FAILURE:-} == health ]]; then exit 22; fi
if [[ $* == *write-out* ]]; then printf '%s' "${ROOT_HTTP_CODE:-200}"; fi
''')
        curl.chmod(0o755)
        git = self.root / "git"
        git.write_text(r'''#!/usr/bin/env bash
[[ ${LEAK_CHANNEL:-} == tracked ]] && printf 'tracked.txt\n'
''')
        git.chmod(0o755)
        identity = self.root / "id"
        identity.write_text("#!/usr/bin/env bash\n[[ $1 == -u ]] && echo 1234 || /usr/bin/id \"$@\"\n")
        identity.chmod(0o755)
        compose = self.root / "podman-compose"
        compose.write_text("#!/usr/bin/env bash\nprintf 'compose <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
        compose.chmod(0o755)
        systemctl = self.root / "systemctl"
        systemctl.write_text("#!/usr/bin/env bash\nexit 1\n")
        systemctl.chmod(0o755)
        deploy = self.root / "scripts/deploy.sh"
        deploy.write_text("#!/usr/bin/env bash\nprintf 'deploy <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
        deploy.chmod(0o755)
        self.env = os.environ | {
            "ODOO_PROJECT_ROOT": str(self.root), "PODMAN_BIN": str(podman),
            "PODMAN_COMPOSE_BIN": str(compose), "SYSTEMCTL_BIN": str(systemctl),
            "FAKE_LOG": str(self.log), "FAKE_MARKER": str(self.marker),
            "FAKE_DB_SECRET": self.db_secret, "FAKE_ADMIN_SECRET": self.admin_secret,
            "ODOO_DEPLOY_UID": "1234",
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
        }

    def tearDown(self):
        self.temp.cleanup()

    def verify(self, *args, **env):
        return subprocess.run([self.root / "scripts/verify.sh", *args], env=self.env | env,
                              text=True, capture_output=True)

    def assert_failure(self, expected, **env):
        result = self.verify(**env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(expected, result.stderr)

    def test_full_success_and_restart_persist_same_filestore_marker(self):
        result = self.verify("--restart-persistence")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        marker_path = "/var/lib/odoo/filestore/.persistence-marker"
        self.assertGreaterEqual(calls.count(marker_path), 2)
        written = self.marker.read_text()
        self.assertRegex(written, r"^verify-persistence-[0-9]+$")
        self.assertIn("compose <-p odoo18 -f", calls)
        self.assertIn("deploy <--no-systemd>", calls)

    def test_manual_native_healthchecks_recover_both_stale_scheduler_statuses(self):
        result = self.verify(SCHEDULER_FAILURE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn("podman <healthcheck> <run> <odoo18-db>", calls)
        self.assertIn("podman <healthcheck> <run> <odoo18-web>", calls)

    def test_absent_stopped_and_unhealthy_resources_fail(self):
        resources = (("container", "odoo18-db"), ("container", "odoo18-web"),
                     ("network", "odoo18-network"), ("volume", "odoo18-db-data"),
                     ("volume", "odoo18-web-data"))
        for kind, name in resources:
            with self.subTest(absent=name):
                self.assert_failure(f"missing expected {kind}", MISSING_RESOURCE=name)
        for name in ("odoo18-db", "odoo18-web"):
            with self.subTest(stopped=name): self.assert_failure("is not running", STOPPED_CONTAINER=name)
            with self.subTest(unhealthy=name): self.assert_failure("is not healthy", UNHEALTHY_CONTAINER=name)

    def test_database_failure_modes_fail(self):
        for mode in ("ready", "query", "available", "extension"):
            with self.subTest(mode=mode):
                result = self.verify(DB_FAILURE=mode)
                self.assertNotEqual(result.returncode, 0)

    def test_http_and_port_failure_modes_fail(self):
        self.assert_failure("Odoo port is not loopback-only", WEB_PORT="0.0.0.0:18069")
        self.assert_failure("PostgreSQL has a published host port", DB_PORT="127.0.0.1:5432")
        health = self.verify(HTTP_FAILURE="health")
        self.assertNotEqual(health.returncode, 0)
        self.assert_failure("HTTP 500", ROOT_HTTP_CODE="500")

    def test_runtime_and_volume_failures_fail(self):
        for target in ("db", "admin", "config", "helper"):
            with self.subTest(runtime=target): self.assert_failure("wrong namespace owner", BAD_RUNTIME=target)
        for target in ("db", "web", "filestore"):
            with self.subTest(volume=target): self.assert_failure("wrong", BAD_VOLUME=target)
        self.assert_failure("missing filestore", MISSING_FILESTORE="1")
        self.assert_failure("wrong filestore mode", BAD_FILESTORE_MODE="1")
        self.assert_failure("not a safe directory", SYMLINK_FILESTORE="1")

    def test_every_leakage_channel_fails_without_echoing_secret(self):
        (self.root / "tracked.txt").write_text(self.admin_secret)
        for channel in ("inspect", "process", "logs", "tracked"):
            with self.subTest(channel=channel):
                result = self.verify(LEAK_CHANNEL=channel)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("secret found", result.stderr)
                self.assertNotIn(self.db_secret, result.stderr)
                self.assertNotIn(self.admin_secret, result.stderr)

    def test_restart_persistence_failure_is_detected(self):
        result = self.verify("--restart-persistence", PERSISTENCE_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("filestore did not persist", result.stderr)

    def test_foreign_resources_and_redacted_health_diagnostics(self):
        command = f'source "{ROOT}/scripts/lib.sh"; validate_resources'
        foreign = subprocess.run(["bash", "-c", command], env=self.env | {"FOREIGN_RESOURCE": "odoo18-network"}, text=True, capture_output=True)
        self.assertNotEqual(foreign.returncode, 0)
        command = f'source "{ROOT}/scripts/lib.sh"; wait_healthy odoo18-db 2'
        unhealthy = subprocess.run(["bash", "-c", command], env=self.env | {"UNHEALTHY_CONTAINER": "odoo18-db", "LEAK_CHANNEL": "logs"}, text=True, capture_output=True)
        self.assertNotEqual(unhealthy.returncode, 0)
        self.assertNotIn(self.db_secret, unhealthy.stderr)
        self.assertIn("[REDACTED]", unhealthy.stderr)


if __name__ == "__main__":
    unittest.main()
