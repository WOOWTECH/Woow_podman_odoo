#!/usr/bin/env bash
# Add the seven public HA add-on modules to an authorized PaaS cloud image.
# Build context is the pinned source checkout; private PaaS code never enters this repo.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
usage='usage: scripts/build-ha-cloud-image.sh <digest-pinned base image> <odoo-addons checkout> <local output tag>'
[[ $# == 3 ]] || { echo "$usage" >&2; exit 2; }
base=$1 source_dir=$2 output=$3
[[ $base =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}$ ]] \
  || { echo 'Base image must have an immutable sha256 digest' >&2; exit 2; }
[[ $output == localhost/* && $output != *@* ]] \
  || { echo 'Output must be a localhost tag; publish separately after review' >&2; exit 2; }
[[ -d $source_dir/addons && -d $source_dir/.git ]] \
  || { echo 'Source must be a Git checkout with an addons/ directory' >&2; exit 2; }
source_dir=$(cd "$source_dir" && pwd -P)
want=51856b0abbce68848b2b024a00191cac5eeead3f
got=$(git -C "$source_dir" rev-parse HEAD)
[[ $got == "$want" && -z $(git -C "$source_dir" status --porcelain) ]] \
  || { echo "HA addons source must be clean at $want" >&2; exit 1; }
expected=(awesome_clicker awesome_dashboard awesome_gallery awesome_kanban awesome_owl estate estate_account)
mapfile -t actual < <(find "$source_dir/addons" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
[[ ${actual[*]} == "${expected[*]}" ]] || { echo 'HA addon module directory set changed' >&2; exit 1; }
[[ $(podman image inspect --format '{{index .Config.Labels "io.woowtech.paas.addons-path"}}' "$base" 2>/dev/null) == /opt/woow/addons ]] \
  || { echo 'Base image must provide PaaS cloud addons at /opt/woow/addons' >&2; exit 1; }
podman build -f "$REPO/Containerfile.ha-cloud" --build-arg "ODOO_BASE_IMAGE=$base" -t "$output" "$source_dir"
podman image inspect --format '{{index .RepoDigests 0}}' "$output"
