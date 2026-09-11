#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
"$ROOT/scripts/deploy.sh"
"$ROOT/scripts/verify.sh"
"$ROOT/scripts/verify.sh" --restart-persistence
"$ROOT/scripts/verify.sh"
