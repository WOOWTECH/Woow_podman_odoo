#!/usr/bin/env python3
"""Retain seven timer backups and one extra backup from each of four ISO weeks.

Only odoo18-auto-*.tar files are eligible. Every eligible archive must have a
matching checksum sidecar before *any* file is removed; hand-made archives are
never considered. This runs while backup.sh still owns the Odoo operation lock.
"""

import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import re

NAME = re.compile(r"odoo18-auto-(\d{8}T\d{6}Z)(?:-\d+)?\.tar\Z")
CHECKSUM = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)\n\Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory(directory: Path) -> list[tuple[datetime, Path]]:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"unsafe backup directory: {directory}")
    found = []
    for path in directory.iterdir():
        match = NAME.fullmatch(path.name)
        if not match:
            continue
        sidecar = path.with_name(path.name + ".sha256")
        if path.is_symlink() or not path.is_file() or sidecar.is_symlink() or not sidecar.is_file():
            raise ValueError(f"missing or unsafe backup/checksum pair: {path.name}")
        if sidecar.stat().st_size > 200:
            raise ValueError(f"oversized backup checksum: {path.name}")
        line = sidecar.read_text(encoding="ascii")
        checksum = CHECKSUM.fullmatch(line)
        if not checksum or checksum.group(2) != path.name or sha256(path) != checksum.group(1):
            raise ValueError(f"invalid backup checksum: {path.name}")
        stamp = datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        found.append((stamp, path))
    return sorted(found, key=lambda entry: (entry[0], entry[1].name), reverse=True)


def keep_set(found: list[tuple[datetime, Path]], daily: int, weekly: int) -> set[Path]:
    keep = {path for _, path in found[:daily]}
    weeks = sorted({stamp.isocalendar()[:2] for stamp, _ in found}, reverse=True)[:weekly]
    for week in weeks:
        # The first successful backup of each ISO week is the weekly reference.
        candidates = [(stamp, path) for stamp, path in found if stamp.isocalendar()[:2] == week]
        keep.add(min(candidates, key=lambda entry: (entry[0], entry[1].name))[1])
    return keep


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--daily", type=int, default=7)
    parser.add_argument("--weekly", type=int, default=4)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.daily < 1 or args.weekly < 0:
        parser.error("daily must be positive; weekly cannot be negative")
    found = inventory(args.directory)
    keep = keep_set(found, args.daily, args.weekly)
    stale = [path for _, path in found if path not in keep]
    for path in stale:
        if not args.dry_run:
            path.unlink()
            path.with_name(path.name + ".sha256").unlink()
        print(f"{'would prune' if args.dry_run else 'pruned'} {path.name}")
    print(f"automated backup retention: {len(keep)} kept, {len(stale)} pruned")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError) as exc:
        raise SystemExit(f"automated backup retention failed: {exc}")
