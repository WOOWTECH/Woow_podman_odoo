#!/usr/bin/env bash
# tests/run.sh: the Python unit tests (backup-archive validator, roles preparer, conf template).
# They need no podman and no network. tests/dryrun.sh and tests/lint-repo.sh are the other static
# checks; tests/smoke.sh runs against an installed host.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -m unittest discover -s tests -p 'test_*.py' -v
