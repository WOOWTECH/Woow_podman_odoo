"""Backup-archive validator and roles preparer.

Harvested from the hardened compose deployment (tests/test_backup_restore.py) and adapted to the
Quadlet archive layout: one dump per Odoo database under databases/, no odoo.conf in the archive, and
the passwords only when the operator asked for them with --include-secrets.
"""
import hashlib
import importlib.util
import re
import io
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


def archive(path, *, extra=None, corrupt=False, databases=None,
            roles=b"CREATE ROLE odoo;\nALTER ROLE odoo LOGIN;\n", volume_files=None,
            metadata=b'{"project":"odoo18"}', secrets=None):
    """Write a backup archive; the defaults are a valid one."""
    if databases is None:
        databases = {"smoke": b"PGDMPdata"}
    files = {"roles.sql": roles, "metadata.json": metadata}
    for name, data in databases.items():
        files[f"databases/{name}.dump"] = data
    for name, data in (volume_files or {}).items():
        files["volume/" + name] = data
    for name, data in (secrets or {}).items():
        files["secrets/" + name] = data
    manifest = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(files.items())).encode()
    files["SHA256SUMS"] = (b"0" * 64 + manifest[64:]) if corrupt else manifest
    with tarfile.open(path, "w") as tf:
        for directory in ("volume", "databases"):
            info = tarfile.TarInfo("odoo18-backup-test/" + directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o700
            tf.addfile(info)
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


class BackupValidatorTest(unittest.TestCase):
    def validate(self, path, out=None):
        cmd = ["python3", str(VALIDATOR), str(path)]
        if out is not None:
            cmd += ["--extract-to", str(out)]
        return subprocess.run(cmd, text=True, capture_output=True)

    def test_accepts_and_extracts_every_entry_with_private_modes(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source, databases={"smoke": b"PGDMPone", "shop": b"PGDMPtwo"},
                    volume_files={"filestore/smoke/object": b"payload"},
                    secrets={"admin-password": b"x"})
            out = Path(d) / "out"
            result = self.validate(source, out)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((out / "volume/filestore/smoke/object").read_bytes(), b"payload")
            self.assertEqual((out / "databases/shop.dump").read_bytes(), b"PGDMPtwo")
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

    def test_rejects_traversal_links_absolute_duplicate_corrupt_and_bad_dump(self):
        cases = [
            (("odoo18-backup-test/../escape", tarfile.REGTYPE), False, {"smoke": b"PGDMPx"}),
            (("odoo18-backup-test/link", tarfile.SYMTYPE), False, {"smoke": b"PGDMPx"}),
            (("/absolute", tarfile.REGTYPE), False, {"smoke": b"PGDMPx"}),
            (("odoo18-backup-test/roles.sql", tarfile.REGTYPE), False, {"smoke": b"PGDMPx"}),
            (None, True, {"smoke": b"PGDMPx"}),
            (None, False, {"smoke": b"not-a-dump"}),
        ]
        for extra, corrupt, databases in cases:
            with self.subTest(case=(extra, corrupt)), tempfile.TemporaryDirectory() as d:
                source = Path(d) / "a.tar"
                archive(source, extra=extra, corrupt=corrupt, databases=databases)
                out = Path(d) / "out"
                result = self.validate(source, out)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(out.exists())

    def test_rejects_unexpected_top_level_entry_and_missing_roles(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source, extra=("odoo18-backup-test/unexpected", tarfile.REGTYPE))
            self.assertNotEqual(self.validate(source).returncode, 0)
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source)
            # Rebuild without roles.sql by filtering the archive.
            stripped = Path(d) / "b.tar"
            with tarfile.open(source) as src, tarfile.open(stripped, "w") as dst:
                for member in src.getmembers():
                    if member.name.endswith("roles.sql"):
                        continue
                    dst.addfile(member, src.extractfile(member) if member.isfile() else None)
            self.assertNotEqual(self.validate(stripped).returncode, 0)

    def test_accepts_an_archive_without_any_database(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / "a.tar"
            archive(source, databases={})
            self.assertEqual(self.validate(source).returncode, 0)

    def test_enforces_member_count_and_expanded_size_ceilings(self):
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


class RolePreparerTest(unittest.TestCase):
    def prepare(self, source, *args):
        return subprocess.run(["python3", str(ROOT / "scripts/make-roles-idempotent.py"), *args],
                              input=source, text=True, capture_output=True)

    def test_handles_existing_quoted_multiline_and_apostrophe_names(self):
        source = ('CREATE ROLE odoo;\nCREATE ROLE "Existing\nRole";\n'
                  'CREATE ROLE "O\'Brien";\nALTER ROLE odoo LOGIN;\n')
        result = self.prepare(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("WHERE NOT EXISTS"), 3)
        self.assertIn("SELECT 'CREATE ROLE \"O''Brien\"'", result.stdout)
        self.assertIn("rolname = 'O''Brien'", result.stdout)
        self.assertIn("ALTER ROLE odoo LOGIN", result.stdout)

    def test_removes_roles_introduced_by_a_failed_restore(self):
        with tempfile.TemporaryDirectory() as d:
            mutated = Path(d) / "mutated.sql"
            mutated.write_text('CREATE ROLE odoo;\nCREATE ROLE "New O\'Brien";\n')
            result = self.prepare("CREATE ROLE odoo;\n", "--drop-roles-from", str(mutated))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('REASSIGN OWNED BY "New O\'Brien" TO odoo;', result.stdout)
            self.assertIn('DROP ROLE "New O\'Brien";', result.stdout)
            self.assertNotIn("DROP ROLE odoo", result.stdout)

    def test_refuses_a_create_role_shape_it_cannot_make_idempotent(self):
        result = self.prepare("CREATE ROLE odoo WITH LOGIN;\n")
        self.assertNotEqual(result.returncode, 0)


class ConfigTemplateTest(unittest.TestCase):
    """The template must keep every credential a token and never ship a default."""

    def test_template_has_only_tokens_for_credentials(self):
        text = (ROOT / "config/odoo.conf.template").read_text()
        self.assertIn("db_password = @@POSTGRES_PASSWORD@@", text)
        self.assertIn("admin_passwd = @@ODOO_ADMIN_PASSWORD@@", text)
        self.assertIn("db_host = odoo18-db", text)
        self.assertNotRegex(text, r"(?m)^admin_passwd\s*=\s*admin\s*$")

    def test_render_vars_lists_exactly_the_tokens(self):
        text = (ROOT / "config/odoo.conf.template").read_text()
        tokens = set(re.findall(r"@@([A-Za-z_][A-Za-z0-9_]*)@@", text))
        listed = {line.strip() for line in (ROOT / "config/odoo.conf.render-vars").read_text().splitlines()
                  if line.strip() and not line.startswith("#")}
        self.assertEqual(tokens, listed)


if __name__ == "__main__":
    unittest.main()
