import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class SystemdBehaviorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "systemd").mkdir()
        for name in ("install-systemd.sh", "lib.sh", "service.sh", "healthcheck.sh"):
            shutil.copy(ROOT / "scripts" / name, self.root / "scripts" / name)
        for name in ("odoo18.service.in", "odoo18-health.service.in", "odoo18-health.timer.in"):
            shutil.copy(ROOT / "systemd" / name, self.root / "systemd" / name)
        deploy = self.root / "scripts/deploy.sh"
        deploy.write_text("#!/usr/bin/env bash\nprintf 'deploy <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
        deploy.chmod(0o755)
        (self.root / "docker-compose.yml").write_text("services: {}\n")
        self.log = self.root / "calls"
        self.state = self.root / "state"
        self.state.mkdir()
        identity = self.root / "id"
        identity.write_text("#!/usr/bin/env bash\n[[ $1 == -u ]] && echo \"${FAKE_UID:-1000}\" || /usr/bin/id \"$@\"\n")
        identity.chmod(0o755)
        systemctl = self.root / "systemctl"
        systemctl.write_text(r'''#!/usr/bin/env bash
printf 'systemctl <%s>\n' "$*" >>"$FAKE_LOG"
action=
for arg in "$@"; do
  case "$arg" in is-enabled|is-active|enable|restart|start|stop) action=$arg; break;; esac
done
unit=${@: -1}
case "$action" in
 is-enabled) [[ -e "$FAKE_STATE/enabled-$unit" ]] && echo enabled || echo disabled;;
 is-active) [[ -e "$FAKE_STATE/active-$unit" ]] && echo active || echo inactive;;
 enable)
   seen=false
   for arg in "$@"; do
     $seen && touch "$FAKE_STATE/enabled-$arg"
     [[ $arg == enable ]] && seen=true
   done;;
 restart|start) touch "$FAKE_STATE/active-$unit";;
 stop)
   seen=false
   for arg in "$@"; do
     $seen && rm -f "$FAKE_STATE/active-$arg"
     [[ $arg == stop ]] && seen=true
   done;;
esac
exit 0
''')
        systemctl.chmod(0o755)
        loginctl = self.root / "loginctl"
        loginctl.write_text("#!/usr/bin/env bash\nprintf 'loginctl <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\nprintf '%s\\n' \"${FAKE_LINGER:-no}\"\n")
        loginctl.chmod(0o755)
        compose = self.root / "podman-compose"
        compose.write_text("#!/usr/bin/env bash\nprintf 'compose <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
        compose.chmod(0o755)
        podman = self.root / "podman"
        podman.write_text(r'''#!/usr/bin/env bash
printf 'podman <%s>\n' "$*" >>"$FAKE_LOG"
case "$1" in
 container)
   [[ ${FAKE_CONTAINERS:-0} == 1 && $2 == inspect ]] || exit 1
   [[ $3 == --format ]] && { [[ ${FOREIGN_RESOURCE:-} == "${@: -1}" ]] && echo 'other 9' || echo "odoo18 $ODOO_DEPLOY_UID"; }
   exit 0;;
 healthcheck)
   [[ $2 == run ]] || exit 2
   [[ ${HEALTHCHECK_FAILURE:-} == "$3" ]] && exit 1
   exit 0;;
 *) exit 1;;
esac
''')
        podman.chmod(0o755)
        self.home = self.root / "home"
        self.home.mkdir()
        self.evil = self.root / "xdg"
        self.env = os.environ | {
            "ODOO_PROJECT_ROOT": str(self.root), "SYSTEMCTL_BIN": str(systemctl),
            "PODMAN_COMPOSE_BIN": str(compose), "PODMAN_BIN": str(podman),
            "LOGINCTL_BIN": str(loginctl), "FAKE_LOG": str(self.log),
            "FAKE_STATE": str(self.state), "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.evil), "USER": "odoo-user",
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
        }

    def tearDown(self):
        self.temp.cleanup()

    def install(self, **env):
        return subprocess.run([self.root / "scripts/install-systemd.sh"], env=self.env | env,
                              text=True, capture_output=True)

    def test_installs_main_timer_and_static_health_service_then_converges(self):
        for _ in range(2):
            result = self.install(FAKE_LINGER="yes")
            self.assertEqual(result.returncode, 0, result.stderr)
        unit_dir = self.home / ".config/systemd/user"
        self.assertFalse(self.evil.exists())
        for name in ("odoo18.service", "odoo18-health.service", "odoo18-health.timer"):
            unit = unit_dir / name
            self.assertTrue(unit.is_file())
            if name != "odoo18-health.timer":
                self.assertIn(str(self.root), unit.read_text())
            self.assertNotIn("@PROJECT_ROOT@", unit.read_text())
        main_service = (unit_dir / "odoo18.service").read_text()
        health_service = (unit_dir / "odoo18-health.service").read_text()
        timer = (unit_dir / "odoo18-health.timer").read_text()
        self.assertIn(f"WorkingDirectory={self.root}", main_service.splitlines())
        self.assertIn(f"ExecStart={self.root}/scripts/service.sh start", main_service.splitlines())
        self.assertIn(f"ExecStop={self.root}/scripts/service.sh stop", main_service.splitlines())
        self.assertIn(f"WorkingDirectory={self.root}", health_service.splitlines())
        self.assertIn(f"ExecStart={self.root}/scripts/healthcheck.sh", health_service.splitlines())
        self.assertNotIn(f'WorkingDirectory="{self.root}"', main_service + health_service)
        self.assertNotIn(f'ExecStart="{self.root}', main_service + health_service)
        self.assertNotIn("[Install]", health_service)
        self.assertNotIn("odoo18-health", main_service)
        self.assertNotIn("After=odoo18.service", health_service + timer)
        self.assertNotIn("Before=odoo18.service", health_service + timer)
        self.assertIn("Unit=odoo18-health.service", timer)
        self.assertIn("OnUnitActiveSec=10s", timer)
        calls = self.log.read_text()
        self.assertEqual(calls.count("daemon-reload"), 1)
        self.assertEqual(calls.count("systemctl <--user enable odoo18.service odoo18-health.timer>"), 1)
        self.assertNotIn("enable odoo18-health.service", calls)
        self.assertEqual(calls.count("restart odoo18.service"), 1)
        self.assertEqual(calls.count("restart odoo18-health.timer"), 1)
        self.assertLess(calls.index("restart odoo18.service"), calls.index("restart odoo18-health.timer"))

    def test_rejects_project_roots_with_any_whitespace_before_mutation(self):
        for whitespace in (" ", "\t", "\n"):
            with self.subTest(whitespace=repr(whitespace)):
                result = self.install(ODOO_PROJECT_ROOT=f"{self.root}/invalid{whitespace}root")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("repository path contains unsupported systemd characters", result.stderr)
        self.assertFalse((self.home / ".config").exists())
        self.assertFalse(self.log.exists())

    @unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze is not installed")
    def test_rendered_units_pass_systemd_analyze_verify(self):
        result = self.install(FAKE_LINGER="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        unit_dir = self.home / ".config/systemd/user"
        units = [
            unit_dir / "odoo18.service",
            unit_dir / "odoo18-health.service",
            unit_dir / "odoo18-health.timer",
        ]
        verify = subprocess.run(["systemd-analyze", "verify", *units],
                                text=True, capture_output=True)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_health_unit_change_reloads_and_restarts_only_timer(self):
        first = self.install(FAKE_LINGER="yes")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.log.write_text("")
        installed = self.home / ".config/systemd/user/odoo18-health.service"
        installed.write_text(installed.read_text() + "# stale\n")
        result = self.install(FAKE_LINGER="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn("daemon-reload", calls)
        self.assertIn("restart odoo18-health.timer", calls)
        self.assertNotIn("restart odoo18.service", calls)
        self.assertNotIn("restart odoo18-health.service", calls)

    def test_root_refusal_happens_before_files_or_systemctl_mutation(self):
        result = self.install(FAKE_UID="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("root/system-scope installation is forbidden", result.stderr)
        self.assertFalse((self.home / ".config").exists())
        self.assertFalse(self.log.exists())

    def test_disabled_linger_prints_actionable_administrator_guidance(self):
        result = self.install(FAKE_LINGER="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Boot startup needs administrator action: loginctl enable-linger odoo-user", result.stderr)
        self.assertIn("show-user odoo-user -p Linger --value", self.log.read_text())

    def test_service_start_uses_recursion_guard_and_starts_timer_after_deploy(self):
        result = subprocess.run([self.root / "scripts/service.sh", "start"], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn("deploy <--no-systemd>", calls)
        self.assertLess(calls.index("deploy <--no-systemd>"), calls.index("start odoo18-health.timer"))

    def test_service_stop_quiesces_checks_before_compose_stop(self):
        result = subprocess.run([self.root / "scripts/service.sh", "stop"], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn("stop odoo18-health.timer odoo18-health.service", calls)
        self.assertIn("compose <-p odoo18 -f", calls)
        self.assertNotIn("down", calls)
        self.assertLess(calls.index("stop odoo18-health.timer"), calls.index("compose <-p odoo18"))

    def test_health_oneshot_validates_both_then_runs_both_even_on_failure(self):
        result = subprocess.run([self.root / "scripts/healthcheck.sh"],
                                env=self.env | {"FAKE_CONTAINERS": "1", "HEALTHCHECK_FAILURE": "odoo18-db"},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        calls = self.log.read_text()
        self.assertIn("healthcheck run odoo18-db", calls)
        self.assertIn("healthcheck run odoo18-web", calls)
        first_check = calls.index("healthcheck run")
        self.assertLess(calls.index("container inspect odoo18-db"), first_check)
        self.assertLess(calls.index("container inspect odoo18-web"), first_check)


if __name__ == "__main__":
    unittest.main()
