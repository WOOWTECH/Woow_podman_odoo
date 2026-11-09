#!/usr/bin/env python3
"""Create a fresh Odoo database through the local XML-RPC database service.

The first administrator password lives in a Podman secret. The master password is
read from its existing secret; neither password enters argv, the env file or logs.
Existing databases are never re-initialized by this command.
"""

import argparse
import re
import secrets
import socket
import subprocess
import sys
import xmlrpc.client
from urllib.parse import urlsplit


def podman(*args: str, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["podman", *args], input=input_text, text=True, capture_output=True, check=False
    )


def secret_value(name: str) -> str:
    result = podman("secret", "inspect", "--showsecret", "--format", "{{.SecretData}}", name)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError(f"Podman secret {name} is absent or empty")
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True)
    parser.add_argument("--admin-login", required=True)
    parser.add_argument("--lang", default="en_US")
    parser.add_argument("--url", default="http://127.0.0.1:18069")
    args = parser.parse_args()

    if not re.fullmatch(r"[a-z][a-z0-9_]{0,62}", args.database):
        parser.error("database must start with a lowercase letter and contain only a-z, 0-9 or _ (max 63)")
    if args.database in {"postgres", "template0", "template1"}:
        parser.error("database name is reserved by PostgreSQL")
    if not re.fullmatch(r"[A-Za-z0-9_.+@-]{3,254}", args.admin_login):
        parser.error("admin login must be 3-254 safe email/login characters")
    if not re.fullmatch(r"[a-z]{2}_[A-Z]{2}", args.lang):
        parser.error("lang must look like en_US or zh_TW")
    parsed = urlsplit(args.url)
    try:
        valid_port = parsed.port is not None and parsed.port > 0
    except ValueError:
        valid_port = False
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or \
            not valid_port or parsed.path not in {"", "/"} or parsed.username or parsed.password or parsed.query or parsed.fragment:
        parser.error("--url must be a local HTTP origin with an explicit port")

    socket.setdefaulttimeout(900)
    db = xmlrpc.client.ServerProxy(args.url.rstrip("/") + "/xmlrpc/2/db", allow_none=False)
    common = xmlrpc.client.ServerProxy(args.url.rstrip("/") + "/xmlrpc/2/common", allow_none=False)
    secret_name = f"odoo18-{args.database}-admin-password"
    try:
        if db.db_exist(args.database):
            raise RuntimeError(f"database {args.database} already exists; inspect it before any retry")
        master = secret_value("odoo18-admin-password")
        if podman("secret", "exists", secret_name).returncode:
            created = podman("secret", "create", secret_name, "-", input_text=secrets.token_urlsafe(36))
            if created.returncode:
                raise RuntimeError(f"could not create Podman secret {secret_name}")
        admin_password = secret_value(secret_name)
        db.create_database(master, args.database, False, args.lang, admin_password, args.admin_login)
        uid = common.authenticate(args.database, args.admin_login, admin_password, {})
        if not isinstance(uid, int) or uid <= 0:
            raise RuntimeError("database was created, but its administrator login did not authenticate")
    except (OSError, RuntimeError, xmlrpc.client.Error) as exc:
        # XML-RPC faults can echo request data on some servers; do not print the fault.
        if isinstance(exc, RuntimeError):
            print(f"init-db: {exc}", file=sys.stderr)
        else:
            print("init-db: Odoo request failed; inspect the Odoo service log (credentials withheld)", file=sys.stderr)
        return 1

    print(f"database {args.database} created; administrator {args.admin_login} authenticated")
    print(f"login password: podman secret inspect --showsecret --format '{{{{.SecretData}}}}' {secret_name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
