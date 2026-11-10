"""The timer must never delete manual backups or prune after checksum failure."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/retain-backups.py"
SPEC = importlib.util.spec_from_file_location("retain_backups", SCRIPT)
retention = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retention)


class BackupRetentionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def backup(self, stamp, *, automated=True):
        name = f"odoo18-{'auto-' if automated else ''}{stamp}.tar"
        path = self.root / name
        path.write_bytes(stamp.encode())
        checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        (self.root / (name + ".sha256")).write_text(f"{checksum}  {name}\n")
        return path

    def run_retention(self, *args):
        return subprocess.run(
            [sys.executable, SCRIPT, "--directory", self.root, *args],
            capture_output=True, text=True, check=False,
        )

    def test_keeps_seven_daily_and_first_backup_of_four_recent_weeks(self):
        stamps = [
            "20260907T020000Z", "20260908T020000Z", "20260914T020000Z",
            "20260915T020000Z", "20260921T020000Z", "20260922T020000Z",
            "20260928T020000Z", "20260929T020000Z", "20261005T020000Z",
            "20261006T020000Z", "20261007T020000Z", "20261008T020000Z",
            "20261009T020000Z", "20261010T020000Z", "20261011T020000Z",
        ]
        archives = [self.backup(stamp) for stamp in stamps]
        manual = self.backup("20260801T020000Z", automated=False)
        expected = retention.keep_set(retention.inventory(self.root), 7, 4)
        self.assertLess(len(expected), len(archives))
        preview = self.run_retention("--dry-run")
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertTrue(all(path.exists() for path in archives))
        actual = self.run_retention()
        self.assertEqual(actual.returncode, 0, actual.stderr)
        self.assertEqual({path for path in archives if path.exists()}, expected)
        self.assertTrue(manual.exists())
        for path in archives:
            self.assertEqual(path.exists(), (self.root / (path.name + ".sha256")).exists())

    def test_checksum_failure_prevents_any_deletion(self):
        archives = [self.backup(f"202610{day:02d}T020000Z") for day in range(1, 13)]
        archives[0].write_bytes(b"corrupted")
        result = self.run_retention()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(path.exists() for path in archives))

    def test_symlinked_archive_is_rejected(self):
        target = self.backup("20261001T020000Z", automated=False)
        linked = self.root / "odoo18-auto-20261001T020000Z.tar"
        linked.symlink_to(target)
        result = self.run_retention()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(target.exists())


if __name__ == "__main__":
    unittest.main()
