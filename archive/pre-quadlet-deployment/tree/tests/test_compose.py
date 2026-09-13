import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = (ROOT / "docker-compose.yml").read_text()
ODOO_IMAGE = "docker.io/library/odoo:18.0@sha256:259fa933bf3ee7f3e375bd74d1e0bc28bd75955159723be477359e0fdb8acf67"
DB_IMAGE = "docker.io/pgvector/pgvector:0.8.0-pg16@sha256:a132765ec351c65111b5b675928a3a0515a466a40f97277329db8b8209ad8bc9"
# Captured from podman inspect after podman-compose 1.0.6 flattened the old
# inline CMD array. The unquoted Python source is not a valid shell command.
OBSERVED_MALFORMED_INSPECT_COMMAND = "/bin/sh -c python3 -c import urllib.request; urllib.request.urlopen(http://127.0.0.1:8069/web/health, timeout=3)"


def service(name):
    match = re.search(rf"^  {name}:\n(.*?)(?=^  \w[\w-]*:\n|^volumes:|^networks:)", COMPOSE, re.M | re.S)
    return match.group(1) if match else ""


class ComposeContractTest(unittest.TestCase):
    def test_images_are_release_and_digest_pinned(self):
        self.assertIn(f"image: {ODOO_IMAGE}", COMPOSE)
        self.assertIn(f"image: {DB_IMAGE}", COMPOSE)
        self.assertNotIn("build:", COMPOSE)

    def test_only_odoo_loopback_port_is_published(self):
        self.assertIn('"127.0.0.1:18069:8069"', COMPOSE)
        self.assertEqual(COMPOSE.count("ports:"), 1)
        self.assertNotIn("${ODOO_PORT", COMPOSE)

    def test_db_has_no_ports_key(self):
        self.assertNotIn("ports:", service("db"))

    def test_password_uses_file_and_not_plain_environment(self):
        self.assertIn("POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password", service("db"))
        self.assertNotIn("POSTGRES_" + "PASSWORD=", COMPOSE)
        self.assertNotIn("POSTGRES_PASSWORD:", COMPOSE)

    def test_generated_config_secret_and_health_helper_mounts_are_read_only(self):
        self.assertIn("./.runtime/secrets/postgres_password:/run/secrets/postgres_password:Z,ro", COMPOSE)
        self.assertIn("./.runtime/config/odoo.conf:/etc/odoo/odoo.conf:Z,ro", COMPOSE)
        self.assertIn("./scripts/odoo-healthcheck.py:/usr/local/bin/odoo-healthcheck:Z,ro", COMPOSE)

    def test_web_healthcheck_avoids_observed_inline_cmd_mangling(self):
        web = service("web")
        self.assertIn('test: ["CMD-SHELL", "/usr/local/bin/odoo-healthcheck"]', web)
        self.assertNotIn("python3", web)
        self.assertNotIn("urllib.request", web)
        self.assertNotIn(OBSERVED_MALFORMED_INSPECT_COMMAND, web)

    def test_db_and_web_have_healthchecks(self):
        self.assertIn("healthcheck:", service("db"))
        self.assertIn("healthcheck:", service("web"))

    def test_every_resource_has_stack_and_owner_labels(self):
        self.assertEqual(COMPOSE.count("io.woowtech.stack: odoo18"), 5)
        self.assertEqual(COMPOSE.count('io.woowtech.owner: "${ODOO_DEPLOY_UID:?set by scripts/deploy.sh}"'), 5)

    def test_custom_postgres_build_is_gone(self):
        self.assertFalse((ROOT / "postgres/Dockerfile").exists())
        for path in ROOT.rglob("*"):
            if path.is_file() and ".git" not in path.parts and "docs" not in path.parts and "__pycache__" not in path.parts:
                insecure = "admin_passwd" + " = " + "admin"
                self.assertNotIn(insecure, path.read_text(errors="ignore"), str(path))


if __name__ == "__main__":
    unittest.main()
