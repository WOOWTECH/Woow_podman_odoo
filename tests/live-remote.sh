#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
if [[ -z ${ODOO_REMOTE_URL:-} ]]; then
  printf '%s\n' 'SKIP: ODOO_REMOTE_URL is not set.' >&2
  printf '%s\n' 'Usage: ODOO_REMOTE_URL=http://odoo-gateway.<tailnet>:18069 bash tests/live-remote.sh' >&2
  exit 77
fi
# Reject an invalid origin before touching the local runtime. By default every
# resolved/connected address must be in Tailscale's CGNAT or ULA ranges. An
# operator may instead pin one reviewed gateway IP with ODOO_REMOTE_PEER.
peer_args=()
[[ -n ${ODOO_REMOTE_PEER:-} ]] && peer_args=(--peer "$ODOO_REMOTE_PEER")
python3 "$ROOT/scripts/remote-probe.py" --validate-only "${peer_args[@]}" "$ODOO_REMOTE_URL"
"$ROOT/scripts/verify.sh"
python3 "$ROOT/scripts/remote-probe.py" "${peer_args[@]}" "$ODOO_REMOTE_URL"
