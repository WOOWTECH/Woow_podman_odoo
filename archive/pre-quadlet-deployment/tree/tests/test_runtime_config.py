import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RuntimeConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "config").mkdir()
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "config/odoo.conf.template", self.root / "config")
        shutil.copy(ROOT / "scripts/odoo-healthcheck.py", self.root / "scripts")
        self.log = self.root / "podman.log"
        fake = self.root / "podman"
        fake.write_text("""#!/usr/bin/env bash
printf '%s\\n' \"$*\" >>\"$FAKE_LOG\"
if [[ \"$1\" == run ]]; then
  if [[ \"$*\" == *postgres* ]]; then
    printf '999\\n999\\n'
  elif [[ ${FAKE_ODOO_IDS:-} == mismatch ]]; then
    printf '100\\n100\\n'
  else
    # Exact IDs observed from the digest-pinned Odoo image.
    printf '100\\n101\\n'
  fi
elif [[ \"$1 $2\" == 'unshare stat' ]]; then
  p=${@: -1}
  case $p in *postgres_password) echo 999:999;; *odoo.conf) echo 100:101;; *odoo-healthcheck.py) echo "${FAKE_HELPER_OWNER:-0:0}";; *) echo 0:0;; esac
elif [[ \"$1 $2\" == 'unshare cat' ]]; then
  cat \"${@: -1}\"
elif [[ \"$1 $2\" == 'unshare rm' ]]; then
  shift; exec \"$@\"
fi
""")
        fake.chmod(0o755)
        self.env = os.environ | {"ODOO_PROJECT_ROOT": str(self.root), "PODMAN_BIN": str(fake), "FAKE_LOG": str(self.log)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_render(self, **extra):
        return subprocess.run([ROOT / "scripts/render-config.sh"], env=self.env | extra,
                              text=True, capture_output=True)

    def test_generation_preservation_permissions_and_no_leak(self):
        first = self.run_render()
        self.assertEqual(first.returncode, 0, first.stderr)
        db = self.root / ".runtime/secrets/postgres_password"
        admin = self.root / ".runtime/secrets/odoo_admin_password"
        config = self.root / ".runtime/config/odoo.conf"
        values = (db.read_text().strip(), admin.read_text().strip())
        self.assertNotEqual(*values)
        self.assertTrue(all(len(v) >= 43 for v in values))
        self.assertEqual(stat.S_IMODE(db.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(admin.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        text = config.read_text()
        self.assertIn("db_host = db", text)
        self.assertIn("db_port = 5432", text)
        self.assertIn("db_user = odoo", text)
        self.assertNotIn("db_name", text)
        self.assertIn("db_password = " + values[0], text)
        self.assertIn("admin_passwd = " + values[1], text)
        captured = first.stdout + first.stderr + self.log.read_text()
        self.assertTrue(all(v not in captured for v in values))
        second = self.run_render()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(values, (db.read_text().strip(), admin.read_text().strip()))

    def test_exact_observed_image_ids_drive_the_required_ownership(self):
        result = self.run_render()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertIn("id -u 'postgres'; id -g 'postgres'", calls)
        self.assertIn("id -u 'odoo'; id -g 'odoo'", calls)
        self.assertIn("unshare chown 999:999", calls)
        self.assertIn("unshare chown 0:0", calls)
        self.assertIn("unshare chown 100:101", calls)
        self.assertIn("unshare stat -c %u:%g", calls)

    def test_health_helper_requires_reviewed_mode_and_namespace_owner(self):
        helper = self.root / "scripts/odoo-healthcheck.py"
        helper.chmod(0o700)
        bad_mode = self.run_render()
        self.assertNotEqual(bad_mode.returncode, 0)
        self.assertIn("expected 755", bad_mode.stderr)
        helper.chmod(0o755)
        bad_owner = self.run_render(FAKE_HELPER_OWNER="1:1")
        self.assertNotEqual(bad_owner.returncode, 0)
        self.assertIn("expected 0:0", bad_owner.stderr)

    def test_secret_install_rejects_symlink_without_following_it(self):
        secrets = self.root / ".runtime/secrets"
        secrets.mkdir(parents=True)
        victim = self.root / "victim"
        victim.write_text("unchanged")
        (secrets / "postgres_password").symlink_to(victim)
        result = self.run_render()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), "unchanged")
        self.assertTrue((secrets / "postgres_password").is_symlink())

    def test_lifecycle_lock_serializes_concurrent_secret_installation(self):
        fake_openssl = self.root / "openssl"
        fake_openssl.write_text("""#!/usr/bin/env bash
count_file="$FAKE_OPENSSL_COUNT"
count=0; [[ -f "$count_file" ]] && read -r count <"$count_file"
count=$((count + 1)); printf '%s\\n' "$count" >"$count_file"
sleep 0.1
if [[ $count == 1 ]]; then printf 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR\\n'; else printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqr\\n'; fi
""")
        fake_openssl.chmod(0o755)
        env = self.env | {"PATH": str(self.root) + os.pathsep + os.environ["PATH"],
                          "FAKE_OPENSSL_COUNT": str(self.root / "openssl-count")}
        first = subprocess.Popen([ROOT / "scripts/render-config.sh"], env=env,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = subprocess.Popen([ROOT / "scripts/render-config.sh"], env=env,
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first_output = first.communicate()
        second_output = second.communicate()
        self.assertEqual(first.returncode, 0, first_output[1])
        self.assertEqual(second.returncode, 0, second_output[1])
        secrets = self.root / ".runtime/secrets"
        self.assertEqual((secrets / "postgres_password").read_text(),
                         "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR\n")
        self.assertEqual((secrets / "odoo_admin_password").read_text(),
                         "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqr\n")

    def test_failed_generation_cleans_exclusively_installed_secret(self):
        fake_openssl = self.root / "openssl"
        fake_openssl.write_text("""#!/usr/bin/env bash
count_file="$FAKE_OPENSSL_COUNT"
count=0; [[ -f "$count_file" ]] && read -r count <"$count_file"
count=$((count + 1)); printf '%s\\n' "$count" >"$count_file"
if [[ $count == 1 ]]; then printf 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR\\n'; else exit 9; fi
""")
        fake_openssl.chmod(0o755)
        result = self.run_render(PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                                 FAKE_OPENSSL_COUNT=str(self.root / "openssl-count"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / ".runtime/secrets/postgres_password").exists())
        self.assertFalse(any((self.root / ".runtime/secrets").glob(".secret.*")))

    def test_image_account_mismatch_fails_before_generation(self):
        fake = Path(self.env["PODMAN_BIN"])
        fake.write_text("#!/usr/bin/env bash\n[[ $1 == run ]] && printf '998\\n998\\n'\n")
        fake.chmod(0o755)
        result = self.run_render()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / ".runtime/secrets/postgres_password").exists())

    def test_odoo_account_mismatch_fails_closed_before_generation(self):
        result = self.run_render(FAKE_ODOO_IDS="mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected odoo 100:101", result.stderr)
        self.assertFalse((self.root / ".runtime/secrets/postgres_password").exists())


if __name__ == "__main__":
    unittest.main()
