import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DeployBehaviorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("deploy.sh", "lib.sh"):
            shutil.copy(ROOT / "scripts" / name, scripts / name)
        for name in ("render-config.sh", "verify.sh", "install-systemd.sh"):
            path = scripts / name
            path.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' {name} >>\"$FAKE_LOG\"\n")
            path.chmod(0o755)
        (self.root / "docker-compose.yml").write_text("services: {}\n")
        self.log = self.root / "calls.log"
        self.state = self.root / "state"
        self.state.mkdir()
        for volume in ("odoo18-db-data", "odoo18-web-data"):
            (self.state / volume).write_text("preserve-me")
        self.web_volume = self.root / "web-volume"
        self.web_volume.mkdir()
        os.chown(self.web_volume, 100, 101)
        podman = self.root / "podman"
        podman.write_text(r'''#!/usr/bin/env bash
printf 'podman' >>"$FAKE_LOG"; printf ' <%s>' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
case "$1" in
 --version) echo "podman version ${FAKE_PODMAN_VERSION:-4.9.3}";;
 container|network|volume)
   name=${@: -1}
   [[ -e "$FAKE_STATE/$name" ]] || exit 1
   if [[ $3 == --format ]]; then
     if [[ $4 == *Mountpoint* ]]; then
       [[ $name == odoo18-web-data ]] && echo "$FAKE_WEB_VOLUME" || echo "$FAKE_STATE/db-volume"
     elif [[ ${FOREIGN_RESOURCE:-} == "$name" || ( ${CREATED_WEB_VOLUME_FOREIGN:-0} == 1 && $name == odoo18-web-data ) ]]; then
       echo "foreign 9999"
     else
       echo "odoo18 $ODOO_DEPLOY_UID"
     fi
   fi;;
 unshare)
   shift
   exec "$@";;
 inspect)
   name=${@: -1}
   if [[ $* == *State.Health.Status* ]]; then
     case "$name" in
       odoo18-db) configured=${DB_HEALTH:-healthy};;
       odoo18-web) configured=${WEB_HEALTH:-healthy};;
     esac
     if [[ ${SCHEDULER_FAILURE:-0} == 1 && $configured == healthy && ! -e "$FAKE_STATE/manual-$name" ]]; then
       echo starting
     else
       echo "$configured"
     fi
   fi;;
 healthcheck)
   [[ $2 == run ]] || exit 2
   [[ ${MANUAL_HEALTH_FAILURE:-} == "$3" ]] || touch "$FAKE_STATE/manual-$3";;
 logs) printf 'safe diagnostics\n';;
esac
''')
        podman.chmod(0o755)
        identity = self.root / "id"
        identity.write_text("#!/usr/bin/env bash\n[[ $1 == -u ]] && echo 1000 || /usr/bin/id \"$@\"\n")
        identity.chmod(0o755)
        sleep = self.root / "sleep"
        sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
        sleep.chmod(0o755)
        compose = self.root / "podman-compose"
        compose.write_text(r'''#!/usr/bin/env bash
if [[ $1 == --version ]]; then
  if [[ -n ${FAKE_COMPOSE_VERSION_OUTPUT+x} ]]; then
    printf '%s' "$FAKE_COMPOSE_VERSION_OUTPUT"
  else
    echo "podman-compose version ${FAKE_COMPOSE_VERSION:-1.0.6}"
  fi
  exit
fi
printf 'compose' >>"$FAKE_LOG"; printf ' <%s>' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
if [[ $* == *'up -d db'* ]]; then touch "$FAKE_STATE/odoo18-db" "$FAKE_STATE/odoo18-network"; fi
if [[ $* == *'up -d web'* ]]; then
  touch "$FAKE_STATE/odoo18-web" "$FAKE_STATE/odoo18-web-data"
  if [[ ! -e "$FAKE_WEB_VOLUME" ]]; then
    mkdir -p "$FAKE_WEB_VOLUME"
    chown 100:101 "$FAKE_WEB_VOLUME"
  fi
fi
''')
        compose.chmod(0o755)
        self.env = os.environ | {
            "ODOO_PROJECT_ROOT": str(self.root), "PODMAN_BIN": str(podman),
            "PODMAN_COMPOSE_BIN": str(compose), "FAKE_LOG": str(self.log),
            "FAKE_STATE": str(self.state), "FAKE_WEB_VOLUME": str(self.web_volume),
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_deploy(self, **env):
        return subprocess.run([self.root / "scripts/deploy.sh", "--no-systemd"],
                              env=self.env | env, text=True, capture_output=True)

    def test_healthy_deploy_and_rerun_converge_without_replacing_volumes(self):
        for _ in range(2):
            result = self.run_deploy()
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(sum("up> <-d> <db>" in line for line in calls), 2)
        self.assertEqual(sum("up> <-d> <web>" in line for line in calls), 2)
        for volume in ("odoo18-db-data", "odoo18-web-data"):
            self.assertEqual((self.state / volume).read_text(), "preserve-me")
        self.assertFalse(any("rm>" in line for line in calls))

    def test_fresh_web_volume_gets_exact_private_filestore_before_web_health(self):
        (self.state / "odoo18-web-data").unlink()
        self.web_volume.rmdir()
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        filestore = self.web_volume / "filestore"
        metadata = filestore.stat()
        self.assertTrue(filestore.is_dir())
        self.assertEqual((metadata.st_uid, metadata.st_gid), (100, 101))
        self.assertEqual(metadata.st_mode & 0o777, 0o700)
        calls = self.log.read_text()
        self.assertLess(calls.index("up> <-d> <web>"), calls.index("unshare> <python3>"))
        self.assertLess(calls.index("unshare> <python3>"), calls.index("healthcheck> <run> <odoo18-web>"))

    def test_rerun_preserves_existing_exact_filestore_contents(self):
        filestore = self.web_volume / "filestore"
        filestore.mkdir(mode=0o700)
        os.chown(filestore, 100, 101)
        payload = filestore / "object"
        payload.write_text("preserve-me")
        before = filestore.stat().st_ino
        for _ in range(2):
            result = self.run_deploy()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(filestore.stat().st_ino, before)
        self.assertEqual(payload.read_text(), "preserve-me")

    def test_volume_created_with_foreign_labels_is_refused_before_filestore_mutation(self):
        (self.state / "odoo18-web-data").unlink()
        self.web_volume.rmdir()
        result = self.run_deploy(CREATED_WEB_VOLUME_FOREIGN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing foreign volume odoo18-web-data", result.stderr)
        self.assertFalse((self.web_volume / "filestore").exists())

    def test_symlink_filestore_is_refused_without_touching_target(self):
        victim = self.root / "victim"
        victim.mkdir()
        (self.web_volume / "filestore").symlink_to(victim, target_is_directory=True)
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("filestore is not a safe directory", result.stderr)
        self.assertEqual(list(victim.iterdir()), [])

    def test_wrong_existing_filestore_ownership_is_refused_not_adopted(self):
        filestore = self.web_volume / "filestore"
        filestore.mkdir(mode=0o700)
        os.chown(filestore, 0, 0)
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong filestore ownership", result.stderr)
        metadata = filestore.stat()
        self.assertEqual((metadata.st_uid, metadata.st_gid), (0, 0))

    def test_wrong_web_volume_ownership_is_refused(self):
        os.chown(self.web_volume, 0, 0)
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong web volume ownership", result.stderr)
        metadata = self.web_volume.stat()
        self.assertEqual((metadata.st_uid, metadata.st_gid), (0, 0))

    def test_manual_native_healthchecks_recover_from_scheduler_failure_for_both_containers(self):
        result = self.run_deploy(SCHEDULER_FAILURE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn("podman <healthcheck> <run> <odoo18-db>", calls)
        self.assertIn("podman <healthcheck> <run> <odoo18-web>", calls)

    def test_unhealthy_or_timed_out_database_blocks_web(self):
        for health in ("unhealthy", "starting"):
            with self.subTest(health=health):
                self.log.write_text("")
                result = self.run_deploy(DB_HEALTH=health)
                self.assertNotEqual(result.returncode, 0)
                calls = self.log.read_text()
                self.assertIn("up> <-d> <db>", calls)
                self.assertNotIn("up> <-d> <web>", calls)
                expected = "unhealthy" if health == "unhealthy" else "timed out"
                self.assertIn(expected, result.stderr)

    def test_unhealthy_web_fails_deploy_but_healthy_rerun_succeeds(self):
        failed = self.run_deploy(WEB_HEALTH="unhealthy")
        self.assertNotEqual(failed.returncode, 0)
        self.log.write_text("")
        healthy = self.run_deploy()
        self.assertEqual(healthy.returncode, 0, healthy.stderr)
        self.assertIn("verify.sh", self.log.read_text())

    def test_foreign_resource_refusal_precedes_compose_mutation(self):
        (self.state / "odoo18-network").touch()
        result = self.run_deploy(FOREIGN_RESOURCE="odoo18-network")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing foreign", result.stderr)
        self.assertNotIn("compose", self.log.read_text())

    def test_accepts_explicit_compose_version_after_noisy_podman_semver(self):
        for output in (
            "podman version 4.9.3\npodman-compose version: 1.0.6\n",
            "podman version 4.9.3\npodman-compose version 1.0.6\n",
        ):
            with self.subTest(output=output):
                self.log.write_text("")
                result = self.run_deploy(FAKE_COMPOSE_VERSION_OUTPUT=output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("up> <-d> <web>", self.log.read_text())

    def test_rejects_ambiguous_or_wrong_explicit_compose_version(self):
        for output in (
            "podman-compose version: 1.0.6\npodman-compose version 1.0.6\n",
            "podman version 4.9.3\npodman-compose version: 1.0.5\n",
            "podman version 4.9.3\n",
        ):
            with self.subTest(output=output):
                self.log.write_text("")
                result = self.run_deploy(FAKE_COMPOSE_VERSION_OUTPUT=output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("podman-compose 1.0.6 is required", result.stderr)
                self.assertNotIn("up> <-d>", self.log.read_text())

    def test_rejects_versions_and_actual_arguments_are_secret_free(self):
        for values in ({"FAKE_PODMAN_VERSION": "4.9.2"}, {"FAKE_COMPOSE_VERSION": "1.1.0"}):
            self.log.write_text("")
            result = self.run_deploy(**values)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("up> <-d>", self.log.read_text())
        self.log.write_text("")
        secrets = ("db-secret-actual-argv", "admin-secret-actual-argv")
        secret_env = {"POSTGRES_" + "PASSWORD": secrets[0], "ODOO_ADMIN_" + "PASSWORD": secrets[1]}
        result = self.run_deploy(**secret_env)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual_arguments = self.log.read_text()
        for secret in secrets:
            self.assertNotIn(secret, actual_arguments)


if __name__ == "__main__":
    unittest.main()
