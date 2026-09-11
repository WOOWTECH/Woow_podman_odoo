#!/usr/bin/env python3
"""Fail when a known-leaked credential reappears in the tracked tree.

docs/DEPLOYMENT_RECORD.md published a PostgreSQL password in February 2026 and it stayed in the
history of this public repository for seven months. Only the sha256 of that value is recorded here,
so the value itself is not in the repository; the scan hashes every candidate token of tracked files.
Rotating the password is what closes the hole (scripts/rotate-secrets.sh --db); this gate only keeps
the string from coming back.
"""
import hashlib
import re
import subprocess
import sys

KNOWN = {
    # 23-character PostgreSQL password from docs/DEPLOYMENT_RECORD.md before 2026-09
    "64bb24798f45ce1a3bf45372324f5ec0e0718dee8f310f66723fd5f3598e38a5": 23,
}
TOKEN = re.compile(rb"[^\s=:`'\"<>(),;]{8,64}")

def main() -> int:
    files = [f for f in subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True)
             .stdout.split(b"\0") if f]
    hits = 0
    for name in files:
        try:
            data = open(name, "rb").read()
        except (FileNotFoundError, IsADirectoryError):
            continue
        for token in set(TOKEN.findall(data)):
            for digest, length in KNOWN.items():
                candidates = {token} | {token[i:i + length] for i in range(0, max(1, len(token) - length + 1))}
                if any(hashlib.sha256(c).hexdigest() == digest for c in candidates):
                    print(f"leaked credential found in {name.decode()}")
                    hits += 1
    print(f"leaked-value scan: {len(files)} tracked files, {hits} hit(s)")
    return 1 if hits else 0

if __name__ == "__main__":
    sys.exit(main())
