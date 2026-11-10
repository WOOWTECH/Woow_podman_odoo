#!/usr/bin/env python3
"""Reject missing or unsafe restored Odoo attachment paths, supplied on stdin."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve(strict=True)
count = 0
for line in sys.stdin:
    name = line.rstrip("\n")
    if not re.fullmatch(r"[0-9a-f]{2}/[0-9a-f]{40}", name):
        raise SystemExit("unsafe attachment store_fname in staged database")
    target = (root / name).resolve()
    if not target.is_relative_to(root) or not target.is_file():
        raise SystemExit("missing attachment in staged filestore")
    count += 1
print(f"verified {count} staged attachment references")
