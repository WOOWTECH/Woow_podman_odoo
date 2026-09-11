#!/usr/bin/env python3
"""Validate and, only after complete validation, extract an Odoo backup."""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile

MAX_MEMBERS = 10000
MAX_SIZE = 10 * 1024**3
REQUIRED = {"database.dump", "roles.sql", "config/odoo.conf", "secrets/odoo_admin_password", "metadata.json", "SHA256SUMS"}
ALLOWED_TOP = {"database.dump", "roles.sql", "volume", "config", "secrets", "metadata.json", "SHA256SUMS"}


def fail(message):
    raise ValueError(message)


def validate_open(tf: tarfile.TarFile):
    members = tf.getmembers()
    if not members or len(members) > MAX_MEMBERS:
        fail("invalid archive member count")
    seen, roots, total = set(), set(), 0
    regular = {}
    paths = []
    for member in members:
        name = member.name
        raw_parts = name.split("/")
        if member.isdir() and raw_parts[-1] == "":
            raw_parts.pop()
        path = PurePosixPath(name)
        if path.is_absolute() or not raw_parts or any(p in ("", ".", "..") for p in raw_parts):
            fail(f"unsafe path: {name}")
        normalized = path.as_posix().rstrip("/")
        if normalized in seen:
            fail(f"duplicate/conflicting path: {name}")
        seen.add(normalized); roots.add(path.parts[0]); paths.append(path)
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            fail(f"unsupported member type: {name}")
        if member.isfile():
            total += member.size
            if total > MAX_SIZE:
                fail("expanded archive is too large")
            regular["/".join(path.parts[1:])] = member
    if len(roots) != 1:
        fail("archive must have exactly one root")
    root = next(iter(roots))
    types = {PurePosixPath(m.name).as_posix().rstrip("/"): "file" if m.isfile() else "dir" for m in members}
    for normalized in types:
        parts = PurePosixPath(normalized).parts
        for index in range(1, len(parts)):
            parent = PurePosixPath(*parts[:index]).as_posix()
            if types.get(parent) == "file":
                fail(f"file/directory path conflict: {normalized}")
    if not any(path.parts[1:] == ("volume",) and member.isdir() for path, member in zip(paths, members)):
        fail("missing volume directory")
    for path in paths:
        rel_parts = path.parts[1:]
        if rel_parts and rel_parts[0] not in ALLOWED_TOP:
            fail(f"unexpected archive entry: {path.as_posix()}")
    missing = REQUIRED - set(regular)
    if missing:
        fail("missing required entries: " + ", ".join(sorted(missing)))
    manifest_file = tf.extractfile(regular["SHA256SUMS"])
    if manifest_file is None:
        fail("cannot read manifest")
    manifest = manifest_file.read().decode("utf-8", "strict").splitlines()
    expected = {}
    for line in manifest:
        if len(line) < 67 or line[64:66] != "  ":
            fail("invalid manifest line")
        digest, rel = line[:64], line[66:]
        if any(c not in "0123456789abcdef" for c in digest) or rel in expected:
            fail("invalid manifest entry")
        p = PurePosixPath(rel)
        if p.is_absolute() or any(x in ("", ".", "..") for x in p.parts):
            fail("unsafe manifest path")
        expected[rel] = digest
    actual_names = set(regular) - {"SHA256SUMS"}
    if set(expected) != actual_names:
        fail("manifest file set mismatch")
    for rel, digest in expected.items():
        source = tf.extractfile(regular[rel])
        if source is None:
            fail(f"cannot read {rel}")
        h = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
        if h.hexdigest() != digest:
            fail(f"checksum mismatch: {rel}")
    database = tf.extractfile(regular["database.dump"])
    if database is None or database.read(5) != b"PGDMP":
        fail("database dump is not PostgreSQL custom format")
    return root


def validate(archive: Path):
    with tarfile.open(archive, "r:*") as tf:
        return validate_open(tf)


def extract_open(tf: tarfile.TarFile, destination: Path, root: str):
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    for member in tf.getmembers():
        rel = PurePosixPath(member.name).relative_to(root)
        target = destination.joinpath(*rel.parts)
        if member.isdir():
            target.mkdir(mode=0o700, parents=True, exist_ok=True)
        else:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            source = tf.extractfile(member)
            if source is None:
                fail(f"cannot extract {member.name}")
            with target.open("xb") as output:
                shutil.copyfileobj(source, output)
            os.chmod(target, 0o600)
    for directory in (path for path in destination.rglob("*") if path.is_dir()):
        os.chmod(directory, 0o700)


def validate_and_extract(archive: Path, destination: Path):
    # One open tar descriptor spans validation and extraction, preventing a
    # pathname replacement between the two operations.
    with tarfile.open(archive, "r:*") as tf:
        root = validate_open(tf)
        extract_open(tf, destination, root)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("--extract-to", type=Path)
    args = parser.parse_args()
    if args.extract_to:
        validate_and_extract(args.archive, args.extract_to)
    else:
        validate(args.archive)
    print("Backup validation passed.")

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError) as exc:
        raise SystemExit(f"Backup validation failed: {exc}")
