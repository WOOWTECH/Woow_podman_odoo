#!/usr/bin/env python3
"""Check installed tenant modules against the exact Odoo image used for a gated upgrade."""
import argparse
import json
import sys

import odoo
from odoo.tools import config
from odoo.modules import module
import psycopg2


def version(value):
    parts = value.split(".")
    if not 2 <= len(parts) <= 5 or not all(part.isdigit() for part in parts):
        return None
    return tuple(int(part) for part in (parts + ["0"] * (5 - len(parts))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", default="odoo")
    parser.add_argument("--mode", choices=["sources", "post"], required=True)
    args = parser.parse_args()
    config.parse_config(["-c", "/etc/odoo/odoo.conf"])
    with psycopg2.connect(
        host=config["db_host"], port=config["db_port"], dbname=args.database,
        user=config["db_user"], password=config["db_password"],
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT name, state, latest_version FROM ir_module_module "
                           "WHERE state IN ('installed','to upgrade','to install','to remove') ORDER BY name")
            rows = cursor.fetchall()
    missing, newer, mismatch, pending = [], [], [], []
    for name, state, installed in rows:
        if state == "to install":
            if args.mode == "post":
                pending.append(name)
            continue
        manifest = module.get_manifest(name)
        if not manifest:
            missing.append(name)
            continue
        image_version = str(manifest.get("version", ""))
        db_version, target_version = version(installed or ""), version(image_version)
        if db_version is None or target_version is None:
            mismatch.append(name)
        elif db_version > target_version:
            newer.append(name)
        elif args.mode == "post" and db_version != target_version:
            mismatch.append(name)
        if args.mode == "post" and state != "installed":
            pending.append(name)
    result = {"installed": len(rows), "missing": missing, "newer": newer,
              "mismatch": mismatch, "pending": pending}
    print(json.dumps(result, sort_keys=True))
    return 0 if not any((missing, newer, mismatch, pending)) else (4 if args.mode == "sources" else 7)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"module verification failed: {type(exc).__name__}", file=sys.stderr)
        sys.exit(2)
