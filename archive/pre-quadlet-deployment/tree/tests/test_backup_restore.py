import hashlib
import importlib.util
import io
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-backup.py"
spec = importlib.util.spec_from_file_location("backup_validator", VALIDATOR)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def archive(path, *, extra=None, corrupt=False, database=b"PGDMPdata",
            roles=b"CREATE ROLE odoo;\nALTER ROLE odoo LOGIN;\n", volume_files=None,
            config=b"[options]\ndb_password = new-db\n", admin=b"new-admin\n"):
    files = {
        "database.dump": database, "roles.sql": roles, "config/odoo.conf": config,
        "secrets/odoo_admin_password": admin, "metadata.json": b"{}",
    }
    for name, data in (volume_files or {}).items():
        files["volume/" + name] = data
    manifest = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(files.items())).encode()
    files["SHA256SUMS"] = (b"0" * 64 + manifest[64:]) if corrupt else manifest
    with tarfile.open(path, "w") as tf:
        volume = tarfile.TarInfo("odoo18-backup-test/volume")
        volume.type = tarfile.DIRTYPE
        volume.mode = 0o700
        tf.addfile(volume)
        for name, data in files.items():
            info = tarfile.TarInfo("odoo18-backup-test/" + name)
            info.size = len(data)
            info.mode = 0o600
            tf.addfile(info, io.BytesIO(data))
        if extra:
            name, kind = extra
            info = tarfile.TarInfo(name)
            info.type = kind
            if kind == tarfile.REGTYPE:
                info.size = 1
                tf.addfile(info, io.BytesIO(b"x"))
            else:
                tf.addfile(info)


class BackupRestoreTest(unittest.TestCase):
    def validate(self, path, out=None):
        cmd = ["python3", str(VALIDATOR), str(path)]
        if out is not None:
            cmd += ["--extract-to", str(out)]
        return subprocess.run(cmd, text=True, capture_output=True)

    def test_validator_accepts_and_extracts_all_contents_with_private_modes(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source, volume_files={"filestore/db/object": b"payload"})
            out = Path(d) / "out"
            result = self.validate(source, out)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((out / "volume/filestore/db/object").read_bytes(), b"payload")
            for path in out.rglob("*"):
                self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)

    def test_validation_and_extraction_share_one_archive_descriptor(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source)
            real_open = tarfile.open
            with mock.patch.object(validator.tarfile, "open", wraps=real_open) as opened:
                validator.validate_and_extract(source, Path(d) / "out")
            self.assertEqual(opened.call_count, 1)

    def test_validator_rejects_traversal_checksum_types_absolute_duplicate_and_bad_dump(self):
        cases = [
            (("odoo18-backup-test/../escape", tarfile.REGTYPE), False, b"PGDMPx"),
            (("odoo18-backup-test/link", tarfile.SYMTYPE), False, b"PGDMPx"),
            (("/absolute", tarfile.REGTYPE), False, b"PGDMPx"),
            (("odoo18-backup-test/database.dump", tarfile.REGTYPE), False, b"PGDMPx"),
            (None, True, b"PGDMPx"), (None, False, b"not-a-dump"),
        ]
        for extra, corrupt, dump in cases:
            with self.subTest(case=(extra, corrupt, dump[:5])), tempfile.TemporaryDirectory() as d:
                source = Path(d) / "a.tar"
                archive(source, extra=extra, corrupt=corrupt, database=dump)
                out = Path(d) / "out"
                result = self.validate(source, out)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(out.exists())

    def test_validator_rejects_unexpected_top_level_and_file_directory_conflict(self):
        for extra in (("odoo18-backup-test/unexpected", tarfile.REGTYPE),
                      ("odoo18-backup-test/config/odoo.conf/child", tarfile.REGTYPE)):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as d:
                source = Path(d) / "a.tar"
                archive(source, extra=extra)
                self.assertNotEqual(self.validate(source).returncode, 0)

    def test_validator_enforces_member_count_and_expanded_size_ceilings(self):
        self.assertEqual(validator.MAX_MEMBERS, 10000)
        self.assertEqual(validator.MAX_SIZE, 10 * 1024**3)
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source)
            original_members, original_size = validator.MAX_MEMBERS, validator.MAX_SIZE
            try:
                validator.MAX_MEMBERS = 2
                with self.assertRaisesRegex(ValueError, "member count"):
                    validator.validate(source)
                validator.MAX_MEMBERS = original_members
                validator.MAX_SIZE = 4
                with self.assertRaisesRegex(ValueError, "expanded archive"):
                    validator.validate(source)
            finally:
                validator.MAX_MEMBERS, validator.MAX_SIZE = original_members, original_size

    def test_role_preparer_handles_existing_quoted_multiline_and_apostrophe_names(self):
        source = ('CREATE ROLE odoo;\nCREATE ROLE "Existing\nRole";\n'
                  'CREATE ROLE "O\'Brien";\nALTER ROLE odoo LOGIN;\n')
        result = subprocess.run(["python3", str(ROOT / "scripts/make-roles-idempotent.py")],
                                input=source, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("WHERE NOT EXISTS"), 3)
        self.assertIn("SELECT 'CREATE ROLE \"O''Brien\"'", result.stdout)
        self.assertIn("rolname = 'O''Brien'", result.stdout)
        self.assertIn("ALTER ROLE odoo LOGIN", result.stdout)

    def test_role_preparer_removes_roles_introduced_by_failed_restore(self):
        with tempfile.TemporaryDirectory() as d:
            mutated = Path(d) / "mutated.sql"
            mutated.write_text('CREATE ROLE odoo;\nCREATE ROLE "New O\'Brien";\n')
            result = subprocess.run(
                ["python3", str(ROOT / "scripts/make-roles-idempotent.py"),
                 "--drop-roles-from", str(mutated)],
                input="CREATE ROLE odoo;\n", text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('REASSIGN OWNED BY "New O\'Brien" TO odoo;', result.stdout)
            self.assertIn('DROP ROLE "New O\'Brien";', result.stdout)
            self.assertNotIn("DROP ROLE odoo", result.stdout)

    def make_runtime(self, root):
        (root / ".runtime/secrets").mkdir(parents=True)
        (root / ".runtime/config").mkdir()
        for path, data in (
            (root / ".runtime/secrets/postgres_password", "old-db\n"),
            (root / ".runtime/secrets/odoo_admin_password", "old-admin\n"),
            (root / ".runtime/config/odoo.conf", "[options]\ndb_password = old-db\n"),
        ):
            path.write_text(data)
            path.chmod(0o600)

    def test_successful_backup_streams_exact_custom_dump_without_file_option_and_preserves_volume(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "scripts").mkdir()
            for name in ("backup.sh", "lib.sh", "validate-backup.py"):
                shutil.copy(ROOT / "scripts" / name, root / "scripts" / name)
            self.make_runtime(root)
            volume = root / "volume"
            (volume / "filestore/db").mkdir(parents=True)
            (volume / "filestore/db/object").write_text("durable")
            log = root / "calls"
            podman = root / "podman"
            podman.write_text(r'''#!/usr/bin/env bash
printf 'podman <%s>\n' "$*" >>"$FAKE_LOG"
if [[ $1 == container || $1 == network ]]; then exit 1; fi
if [[ $1 == volume && $2 == inspect ]]; then
  [[ $3 == --format ]] && echo "$FAKE_VOLUME"
  [[ $3 == --format ]] || exit 1
  exit
fi
if [[ $1 == inspect ]]; then
  [[ $* == *State.Running* ]] && echo true || echo healthy
  exit
fi
if [[ $1 == exec ]]; then
  if [[ $* == *' pg_dump '* ]]; then
    # The PostgreSQL image treats --file=- as a literal /- file and emits no
    # stdout. Model that behavior so this test requires a true stdout stream.
    [[ $* == *'--file=-'* ]] && exit 0
    [[ ${INVALID_DUMP:-0} == 1 ]] && printf 'not-a-database' || printf 'PGDMPdatabase'
  elif [[ $* == *' pg_dumpall '* ]]; then printf 'CREATE ROLE odoo;\nALTER ROLE odoo LOGIN;\n'
  fi
  exit 0
fi
if [[ $1 == unshare ]]; then
  shift; action=$1; shift
  case $action in
    stat) case ${@: -1} in *postgres_password) echo 999:999;; *odoo.conf) echo 100:101;; *) echo 0:0;; esac;;
    chown) exit 0;;
    *) exec "$action" "$@";;
  esac
fi
''')
            podman.chmod(0o755)
            compose = root / "compose"
            compose.write_text("#!/usr/bin/env bash\nprintf 'compose <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
            compose.chmod(0o755)
            date = root / "date"
            date.write_text("#!/usr/bin/env bash\nprintf '20260817T010203Z\\n'\n")
            date.chmod(0o755)
            env = os.environ | {
                "ODOO_PROJECT_ROOT": str(root), "PODMAN_BIN": str(podman),
                "PODMAN_COMPOSE_BIN": str(compose),
                "FAKE_VOLUME": str(volume), "FAKE_LOG": str(log),
                "PATH": str(root) + os.pathsep + os.environ["PATH"],
            }
            outputs = []
            for _ in range(2):
                result = subprocess.run([root / "scripts/backup.sh"], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                outputs.append(Path(result.stdout.strip()))
            self.assertNotEqual(outputs[0], outputs[1])
            self.assertTrue(all(path.is_file() and path.stat().st_mode & 0o777 == 0o600 for path in outputs))
            calls = log.read_text()
            self.assertNotIn("--file=-", calls)
            log.write_text("")
            rejected = subprocess.run([root / "scripts/backup.sh"], env=env | {"INVALID_DUMP": "1"},
                                      text=True, capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(set((root / "backups").glob("*.tar")), set(outputs))
            self.assertFalse(any((root / "backups").glob(".backup.*")))
            self.assertEqual((volume / "filestore/db/object").read_text(), "durable")
            failed_calls = log.read_text()
            self.assertIn("stop web", failed_calls)
            self.assertIn("start web", failed_calls)
            self.assertNotIn(" pg_dumpall ", failed_calls)
            self.assertNotIn("unshare cp -a", failed_calls)
            with tempfile.TemporaryDirectory() as extracted:
                target = Path(extracted) / "out"
                result = self.validate(outputs[0], target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((target / "database.dump").read_bytes(), b"PGDMPdatabase")
                self.assertEqual((target / "volume/filestore/db/object").read_text(), "durable")
                self.assertIn("CREATE ROLE odoo", (target / "roles.sql").read_text())
            successful_calls = calls
            self.assertLess(successful_calls.index("stop web"), successful_calls.index(" pg_dump "))
            self.assertLess(successful_calls.index(" pg_dumpall "), successful_calls.index("unshare tar"))
            self.assertLess(successful_calls.index("unshare tar"), successful_calls.index("start web"))
            self.assertIn("unshare rm -rf", failed_calls)

    def test_backup_dump_failures_leave_no_archive_or_staging(self):
        for failing in ("pg_dump ", "pg_dumpall"):
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                (root / "scripts").mkdir()
                for name in ("backup.sh", "lib.sh"):
                    shutil.copy(ROOT / "scripts" / name, root / "scripts" / name)
                self.make_runtime(root)
                podman = root / "podman"
                log = root / "calls"
                podman.write_text(r'''#!/usr/bin/env bash
printf 'podman <%s>\n' "$*" >>"$FAKE_LOG"
if [[ $1 == container || $1 == network || $1 == volume ]]; then exit 1; fi
if [[ $1 == inspect ]]; then [[ $* == *State.Running* ]] && echo true || echo healthy; exit; fi
if [[ $1 == unshare && $2 == rm ]]; then shift; exec "$@"; fi
if [[ $1 == unshare && $2 == stat ]]; then case ${@: -1} in *postgres_password) echo 999:999;; *odoo.conf) echo 100:101;; *) echo 0:0;; esac; exit; fi
if [[ $1 == exec && "$*" == *"$FAIL_TOOL"* ]]; then exit 42; fi
if [[ $1 == exec && $* == *' pg_dump '* ]]; then printf PGDMPdump; fi
if [[ $1 == exec && $* == *' pg_dumpall '* ]]; then printf 'CREATE ROLE odoo;\n'; fi
''')
                podman.chmod(0o755)
                compose = root / "compose"
                compose.write_text("#!/usr/bin/env bash\nprintf 'compose <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
                compose.chmod(0o755)
                env = os.environ | {"ODOO_PROJECT_ROOT": str(root), "PODMAN_BIN": str(podman),
                                    "PODMAN_COMPOSE_BIN": str(compose), "FAIL_TOOL": failing,
                                    "FAKE_LOG": str(log)}
                result = subprocess.run([root / "scripts/backup.sh"], env=env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any((root / "backups").glob("*.tar")))
                self.assertFalse(any((root / "backups").glob(".backup.*")))
                calls = log.read_text()
                self.assertIn(" stop web>", calls)
                self.assertIn(" start web>", calls)

    def make_restore_fixture(self, root):
        (root / "scripts").mkdir()
        for name in ("restore.sh", "lib.sh", "validate-backup.py", "make-roles-idempotent.py"):
            shutil.copy(ROOT / "scripts" / name, root / "scripts" / name)
        source = root / "input.tar"
        archive(source, roles=b'CREATE ROLE odoo;\nCREATE ROLE "restore-only";\n',
                volume_files={"filestore/db/object": b"new-filestore"})
        pre_restore = root / "pre restore.tar"
        archive(pre_restore, database=b"PGDMPold-database",
                config=b"[options]\ndb_password = old-db\n", admin=b"old-admin\n",
                volume_files={"filestore/db/object": b"old-filestore"})
        self.make_runtime(root)
        volume = root / "volume"
        (volume / "filestore/db").mkdir(parents=True)
        (volume / "filestore/db/object").write_text("old-filestore")
        backup = root / "scripts/backup.sh"
        backup.write_text(f"#!/usr/bin/env bash\nprintf 'backup-called\\n' >>\"$FAKE_LOG\"\nprintf '%s\\n' '{pre_restore}'\n")
        backup.chmod(0o755)
        deploy = root / "scripts/deploy.sh"
        deploy.write_text("#!/usr/bin/env bash\nprintf 'deploy <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
        deploy.chmod(0o755)
        verify = root / "scripts/verify.sh"
        verify.write_text(r'''#!/usr/bin/env bash
printf 'verify\n' >>"$FAKE_LOG"
if [[ ${FAIL_VERIFY_ALWAYS:-0} == 1 ]]; then exit 1; fi
if [[ ${FAIL_VERIFY:-0} == 1 && ! -e "$VERIFY_FAILED_ONCE" ]]; then touch "$VERIFY_FAILED_ONCE"; exit 1; fi
''')
        verify.chmod(0o755)
        compose = root / "compose"
        compose.write_text("#!/usr/bin/env bash\nprintf 'compose <%s>\\n' \"$*\" >>\"$FAKE_LOG\"\n")
        compose.chmod(0o755)
        podman = root / "podman"
        podman.write_text(r'''#!/usr/bin/env bash
printf 'podman <%s>\n' "$*" >>"$FAKE_LOG"
if [[ $1 == container || $1 == network ]]; then exit 1; fi
if [[ $1 == volume && $2 == inspect ]]; then
  [[ $3 == --format ]] && echo "$FAKE_VOLUME"
  [[ $3 == --format ]] || exit 1
  exit
fi
if [[ $1 == inspect ]]; then echo "${FAKE_WEB_RUNNING:-true}"; exit; fi
if [[ $1 == exec && "$*" == *' psql '* ]]; then
 cat >"$ROLE_CAPTURE"
 if [[ ${FAIL_PSQL:-0} != 0 && ! -e "$PSQL_FAILED_ONCE" ]]; then touch "$PSQL_FAILED_ONCE"; exit "$FAIL_PSQL"; fi
 exit 0
fi
if [[ $1 == exec && "$*" == *' pg_restore '* ]]; then
 cat >/dev/null
 if [[ ${FAIL_RESTORE:-0} != 0 && ! -e "$RESTORE_FAILED_ONCE" ]]; then touch "$RESTORE_FAILED_ONCE"; exit "$FAIL_RESTORE"; fi
 exit 0
fi
if [[ $1 == unshare ]]; then
 shift; action=$1; shift
 case $action in
   stat) case ${@: -1} in *postgres_password) echo 999:999;; *odoo.conf) echo 100:101;; *) echo 0:0;; esac;;
   chown) exit 0;;
   *) "$action" "$@";;
 esac
fi
''')
        podman.chmod(0o755)
        log = root / "calls"
        env = os.environ | {
            "ODOO_PROJECT_ROOT": str(root), "PODMAN_BIN": str(podman),
            "PODMAN_COMPOSE_BIN": str(compose), "FAKE_LOG": str(log),
            "ROLE_CAPTURE": str(root / "roles.sql"), "FAKE_VOLUME": str(volume),
            "VERIFY_FAILED_ONCE": str(root / "verify-failed-once"),
            "PSQL_FAILED_ONCE": str(root / "psql-failed-once"),
            "RESTORE_FAILED_ONCE": str(root / "restore-failed-once"),
        }
        return source, pre_restore, volume, log, env

    def restore(self, root, source, env, **extra):
        return subprocess.run([root / "scripts/restore.sh", "--archive", source,
                               "--confirm-restore", "odoo18"], env=env | extra,
                              text=True, capture_output=True)

    def test_successful_restore_contents_modes_and_repeat_convergence(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, _, volume, log, env = self.make_restore_fixture(root)
            for _ in range(2):
                result = self.restore(root, source, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                restored_object = volume / "filestore/db/object"
                self.assertEqual(restored_object.read_text(), "new-filestore")
                self.assertEqual(restored_object.stat().st_mode & 0o777, 0o600)
                self.assertEqual(restored_object.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual((root / ".runtime/config/odoo.conf").read_text(), "[options]\ndb_password = new-db\n")
                self.assertEqual((root / ".runtime/secrets/postgres_password").read_text(), "new-db\n")
                self.assertEqual((root / ".runtime/secrets/odoo_admin_password").read_text(), "new-admin\n")
                for path in (root / ".runtime").rglob("*"):
                    if path.is_file(): self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            calls = log.read_text()
            self.assertEqual(calls.count("deploy <--no-systemd>"), 2)
            self.assertEqual(calls.count("verify\n"), 2)
            self.assertEqual(calls.count("unshare chown -R 100:101"), 2)
            self.assertEqual(calls.count("unshare chown 100:101"), 2)
            self.assertIn("WHERE NOT EXISTS", (root / "roles.sql").read_text())

    def test_invalid_archive_is_rejected_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, _, volume, log, env = self.make_restore_fixture(root)
            bad = root / "bad.tar"
            archive(bad, corrupt=True)
            result = self.restore(root, bad, env)
            self.assertNotEqual(result.returncode, 0)
            calls = log.read_text()
            self.assertNotIn("backup-called", calls)
            self.assertNotIn("compose", calls)
            self.assertEqual((volume / "filestore/db/object").read_text(), "old-filestore")
            self.assertEqual((root / ".runtime/config/odoo.conf").read_text(), "[options]\ndb_password = old-db\n")

    def test_failure_after_touched_files_rolls_back_and_prints_exact_recovery_command(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, pre_restore, volume, log, env = self.make_restore_fixture(root)
            result = self.restore(root, source, env, FAIL_VERIFY="1")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((volume / "filestore/db/object").read_text(), "old-filestore")
            self.assertEqual((root / ".runtime/config/odoo.conf").read_text(), "[options]\ndb_password = old-db\n")
            self.assertEqual((root / ".runtime/secrets/postgres_password").read_text(), "old-db\n")
            self.assertEqual((root / ".runtime/secrets/odoo_admin_password").read_text(), "old-admin\n")
            escaped_archive = str(pre_restore).replace(" ", "\\ ")
            expected = f"{root / 'scripts/restore.sh'} --archive {escaped_archive} --confirm-restore odoo18"
            self.assertIn("Recovery command: " + expected, result.stderr)
            self.assertIn('DROP ROLE "restore-only";', (root / "roles.sql").read_text())
            self.assertIn("compose <-p odoo18 -f", log.read_text())
            self.assertIn("start web", log.read_text())

    def test_failed_full_rollback_leaves_web_stopped_with_recovery_command(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, pre_restore, _, log, env = self.make_restore_fixture(root)
            result = self.restore(root, source, env, FAIL_VERIFY_ALWAYS="1")
            self.assertNotEqual(result.returncode, 0)
            calls = log.read_text()
            self.assertNotIn("start web", calls)
            self.assertIn("web remains stopped", result.stderr)
            self.assertIn(str(pre_restore).replace(" ", "\\ "), result.stderr)

    def test_strict_role_and_database_failures_stop_and_restore_running_state(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, _, _, log, env = self.make_restore_fixture(root)
            failed = self.restore(root, source, env, FAIL_RESTORE="29")
            self.assertNotEqual(failed.returncode, 0)
            calls = log.read_text()
            self.assertIn("--set=ON_ERROR_STOP=1", calls)
            self.assertIn("--single-transaction", calls)
            self.assertIn("start web", calls)
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source, _, _, log, env = self.make_restore_fixture(root)
            failed = self.restore(root, source, env, FAIL_PSQL="17", FAKE_WEB_RUNNING="false")
            self.assertNotEqual(failed.returncode, 0)
            calls = log.read_text()
            # The failed desired-state role phase skips its pg_restore; the
            # one pg_restore below belongs to the verified full rollback.
            self.assertEqual(calls.count(" pg_restore "), 1)
            self.assertGreaterEqual(calls.count("stop web"), 3)
            self.assertNotIn("start web", calls)


if __name__ == "__main__":
    unittest.main()
