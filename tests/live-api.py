#!/usr/bin/env python3
"""Seed or verify a real Odoo partner and filestore attachment over XML-RPC."""

import argparse
import base64
import socket
import subprocess
import sys
import xmlrpc.client
from urllib.parse import urlsplit


def secret_value(name: str) -> str:
    proc = subprocess.run(
        ["podman", "secret", "inspect", "--showsecret", "--format", "{{.SecretData}}", name],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode or not proc.stdout.strip():
        raise RuntimeError(f"secret {name} is unavailable")
    return proc.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("login", "seed", "mutate", "verify"))
    parser.add_argument("--database", required=True)
    parser.add_argument("--admin-login", required=True)
    parser.add_argument("--password-secret", required=True)
    parser.add_argument("--url", default="http://127.0.0.1:18069")
    args = parser.parse_args()
    parsed = urlsplit(args.url)
    try:
        valid_port = parsed.port is not None and parsed.port > 0
    except ValueError:
        valid_port = False
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or \
            not valid_port or parsed.path not in {"", "/"} or parsed.username or parsed.password or parsed.query or parsed.fragment:
        parser.error("--url must be a local HTTP origin with an explicit port")
    socket.setdefaulttimeout(60)
    origin = args.url.rstrip("/")
    name = f"woow_odoo_parity_smoke_{args.database}"
    payload = b"Odoo Podman backup/restore filestore fixture\n"
    try:
        password = secret_value(args.password_secret)
        common = xmlrpc.client.ServerProxy(origin + "/xmlrpc/2/common")
        models = xmlrpc.client.ServerProxy(origin + "/xmlrpc/2/object")
        uid = common.authenticate(args.database, args.admin_login, password, {})
        if not isinstance(uid, int) or uid <= 0:
            raise RuntimeError("administrator authentication failed")
        if args.mode == "login":
            print("verified administrator authentication")
            return 0

        def call(model: str, method: str, *params):
            return models.execute_kw(args.database, uid, password, model, method, list(params))

        partners = call("res.partner", "search", [["name", "=", name]])
        if args.mode == "seed":
            if partners:
                raise RuntimeError("the seed partner already exists")
            partner = call("res.partner", "create", {"name": name, "comment": "original"})
            call("ir.attachment", "create", {
                "name": name + ".txt", "type": "binary", "mimetype": "text/plain",
                "res_model": "res.partner", "res_id": partner,
                "datas": base64.b64encode(payload).decode("ascii"),
            })
            print(f"seeded partner {partner} and binary attachment")
            return 0
        if len(partners) != 1:
            raise RuntimeError(f"expected one seed partner, got {len(partners)}")
        partner = partners[0]
        attachments = call("ir.attachment", "search", [["res_model", "=", "res.partner"], ["res_id", "=", partner], ["name", "=", name + ".txt"]])
        if args.mode == "mutate":
            call("res.partner", "write", [partner], {"comment": "changed after backup"})
            if attachments:
                call("ir.attachment", "unlink", attachments)
            print("mutated partner and removed attachment after backup")
            return 0
        partner_data = call("res.partner", "read", [partner], ["comment"])[0]
        # Odoo stores the HTML comment as <p>original</p>, not the literal input.
        if "original" not in partner_data["comment"] or len(attachments) != 1:
            raise RuntimeError("partner or attachment was not restored")
        attachment_data = call("ir.attachment", "read", attachments, ["datas"])[0]
        if base64.b64decode(attachment_data["datas"]) != payload:
            raise RuntimeError("filestore content does not match the seed")
        print("verified administrator login, partner record and filestore attachment")
        return 0
    except (OSError, RuntimeError, xmlrpc.client.Error) as exc:
        # RPC faults may contain request data; print only locally constructed errors.
        if isinstance(exc, RuntimeError):
            print(f"live-api: {exc}", file=sys.stderr)
        else:
            print("live-api: Odoo RPC failed (request details withheld)", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
