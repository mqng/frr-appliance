#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"

if [[ -z "${SIGSTORE_ID_TOKEN:-}" ]]; then
  echo "SIGSTORE_ID_TOKEN not present; skipping keyless signing outside GitLab CI" >&2
  exit 0
fi
export COSIGN_YES=true

files=(
  "out/$name.img.zst"
  "out/$name.qcow2"
  "out/$name-installer.iso"
  "out/$name-SHA256SUMS"
  "out/$name-build-manifest.json"
  "out/$name-provenance.json"
  "out/$name-sbom.cdx.json"
)
if [[ ${PUBLISH_RAW_IMG:-true} == true ]]; then files+=("out/$name.img"); fi

for f in "${files[@]}"; do
  cosign sign-blob "$f" --bundle "$f.sigstore.json"
done
