#!/usr/bin/env bash
# tests/lint-repo.sh: static repository checks for CI (.github/workflows/repo-checks.yml) and local
# use. Creates nothing and needs no podman.
#
#   1. no plaintext credentials or well-known default passwords in tracked files
#   2. the compose deployment is gone (decision D1: Docker users use the compose-final tag)
#   3. both READMEs lead with the Quadlet install and point Docker users to compose-final
#   4. repo-specific checks (lint_local, at the end of this file): the leaked-value gate, image pin
#      parity, no unit named odoo18.*, the read-only addons mount
#
# Matches are reported as file:line only; the matched text is never printed.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$REPO"
fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
ok() { printf 'ok   %s\n' "$*"; }
# where <hits>: print file:line only, never the matched text
where() { cut -d: -f1,2 | sed 's/^/     /'; }

# The vendored library and this script itself carry the patterns by nature.
mapfile -t files < <(git ls-files --cached --others --exclude-standard \
  | grep -vE '^(scripts/lib/quadlet-lib\.sh|tests/lint-repo\.sh)$' || true)
text=()
for f in "${files[@]}"; do [[ -f $f ]] && grep -Iq . "$f" 2>/dev/null && text+=("$f"); done

# ---- 1. credentials ------------------------------------------------------------------------------
# KEY=value lines whose key names a credential and whose value is a literal (not empty, not a
# $VAR / @@TOKEN@@ / <placeholder> / *_FILE path).
cred_re='(^|[^A-Za-z0-9_])[A-Z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|_KEY)=[^[:space:]$@<"'\''`{}(%]'
# Obvious placeholders (dummy/example/placeholder/changeme/redacted values) are not credentials.
hits=$(grep -nHE "$cred_re" "${text[@]}" 2>/dev/null \
  | grep -vE '(_FILE|_PATH)=' \
  | grep -viE '=[A-Za-z0-9_-]*(dummy|example|placeholder|changeme|redacted|your[_-]?)[A-Za-z0-9_-]*([[:space:]]|$)' || true)
if [[ -n $hits ]]; then fail "literal credential assignments at:"; where <<<"$hits"; else ok "no literal credential assignments"; fi
# Well-known defaults and token formats.
known='admin_passwd[[:space:]]*=[[:space:]]*admin([[:space:]]|$)|DEFAULT_PASSWORD[=:][[:space:]]*public|DASHBOARD_PASSWORD[=:][[:space:]]*(public|admin)([[:space:]]|$)'
known+='|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}'
known+='|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhbGciOi[A-Za-z0-9_-]{20,}\.'
hits=$(grep -nHE "$known" "${text[@]}" 2>/dev/null || true)
if [[ -n $hits ]]; then fail "default passwords or token-shaped strings at:"; where <<<"$hits"; else ok "no default passwords or token-shaped strings"; fi

# ---- 2. D1: compose files are gone ---------------------------------------------------------------
left=$(printf '%s\n' "${files[@]}" | grep -E '(^|/)(docker|podman)-compose[^/]*\.ya?ml$|^compose/|^\.env\.example$' || true)
if [[ -n $left ]]; then fail "compose deployment files remain (D1):"; while IFS= read -r l; do printf "     %s\n" "$l"; done <<<"$left"; else ok "no compose files (D1)"; fi

# ---- 3. READMEs --------------------------------------------------------------------------------
for r in README.md README_zh-TW.md; do
  if [[ ! -f $r ]]; then fail "$r is missing"; continue; fi
  grep -q 'scripts/install.sh' "$r" || fail "$r does not document scripts/install.sh"
  grep -q 'compose-final' "$r" || fail "$r does not point Docker users to the compose-final tag"
  if grep -qi 'portainer' "$r"; then fail "$r still mentions Portainer"; fi
done
ok "README checks done"

# ---- 4. repo-specific ----------------------------------------------------------------------------
lint_local() {
  # The database password that docs/DEPLOYMENT_RECORD.md published in February must never come back.
  # Only its sha256 is stored here, so the value itself is not in the repository.
  if ! python3 tests/leaked-value-scan.py; then fail "a known leaked credential is back in the tree"; fi
  # No default master password, anywhere.
  if grep -rqE '^[[:space:]]*admin_passwd[[:space:]]*=[[:space:]]*admin[[:space:]]*$' config quadlet scripts 2>/dev/null; then
    fail "admin_passwd = admin is back"
  fi
  # Image pins: the units and scripts/common.sh must agree, and both must be digests.
  local img unit_db unit_web
  unit_db=$(sed -n 's/^Image=//p' quadlet/odoo-db.container)
  unit_web=$(sed -n 's/^Image=//p' quadlet/odoo.container)
  grep -qxF "DB_IMAGE=$unit_db" scripts/common.sh || fail "scripts/common.sh DB_IMAGE differs from quadlet/odoo-db.container"
  grep -qxF "ODOO_IMAGE=$unit_web" scripts/common.sh || fail "scripts/common.sh ODOO_IMAGE differs from quadlet/odoo.container"
  for img in "$unit_db" "$unit_web"; do
    [[ $img == *@sha256:* ]] || fail "image not pinned by digest: $img"
  done
  # A unit named odoo18.service would be shadowed by the compose-era hand-written unit.
  if compgen -G 'quadlet/odoo18.*' >/dev/null; then fail "a unit named odoo18.* would be shadowed by the legacy unit"; fi
  # The addons mount stays read-only.
  grep -q ':/mnt/extra-addons:ro,' quadlet/odoo.container || fail "the addons mount is no longer read-only"
  # The rendered odoo.conf is a secret, never a file in the repo.
  if compgen -G 'config/odoo.conf' >/dev/null; then fail "config/odoo.conf is back (the conf is rendered into a podman secret)"; fi
  ok "Odoo checks done"
}
lint_local

((fails == 0)) && echo "lint-repo: all checks passed" || echo "lint-repo: $fails check(s) failed"
((fails == 0))
