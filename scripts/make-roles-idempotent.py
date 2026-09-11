#!/usr/bin/env python3
"""Make pg_dumpall --roles-only CREATE ROLE statements safe to replay."""
import argparse
import re
import sys

CREATE_ROLE = re.compile(
    r'^CREATE ROLE (?P<identifier>"(?:""|[^"])*"|[A-Za-z_][A-Za-z0-9_$]*);[ \t]*(?=\r?$)',
    re.MULTILINE,
)
UNQUOTED = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


def role_name(identifier: str) -> str:
    if identifier.startswith('"') and identifier.endswith('"'):
        return identifier[1:-1].replace('""', '"')
    if not UNQUOTED.fullmatch(identifier):
        raise ValueError("unsupported role identifier in roles dump")
    return identifier.lower()


def identifiers(source: str) -> dict[str, str]:
    found = {}
    for match in CREATE_ROLE.finditer(source):
        identifier = match.group("identifier")
        found[role_name(identifier)] = identifier
    return found


def convert(source: str, drop_roles_from: str | None = None) -> str:
    def conditional(match: re.Match) -> str:
        identifier = match.group("identifier")
        name = role_name(identifier).replace("'", "''")
        # Both SQL string literals must escape apostrophes. In particular, a
        # quoted PostgreSQL identifier may itself contain an apostrophe.
        create_sql = f"CREATE ROLE {identifier}".replace("'", "''")
        return (
            f"SELECT '{create_sql}' WHERE NOT EXISTS "
            f"(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '{name}') \\gexec"
        )

    output = CREATE_ROLE.sub(conditional, source)
    if drop_roles_from is not None:
        restored_names = identifiers(source)
        mutated_names = identifiers(drop_roles_from)
        drops = []
        for name in sorted(mutated_names.keys() - restored_names.keys()):
            identifier = mutated_names[name]
            # These roles were introduced by the failed restore, so they could
            # only own objects in the database being restored. Remove those
            # dependencies transactionally before dropping the extra role.
            drops.extend((f"REASSIGN OWNED BY {identifier} TO odoo;",
                          f"DROP OWNED BY {identifier};",
                          f"DROP ROLE {identifier};"))
        if drops:
            output = "\n".join(drops) + "\n" + output
    # Never silently pass through a CREATE ROLE shape that we cannot make
    # idempotent. pg_dumpall output should always match the grammar above.
    if re.search(r"^CREATE ROLE ", output, re.MULTILINE):
        raise ValueError("unsupported CREATE ROLE statement in roles dump")
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--drop-roles-from")
    args = parser.parse_args()
    try:
        mutated = None
        if args.drop_roles_from:
            with open(args.drop_roles_from, encoding="utf-8") as source:
                mutated = source.read()
        sys.stdout.write(convert(sys.stdin.read(), mutated))
    except ValueError as exc:
        raise SystemExit(f"Cannot prepare roles dump: {exc}")


if __name__ == "__main__":
    main()
