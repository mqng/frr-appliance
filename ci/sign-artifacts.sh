#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"

# GitHub tokens expire in minutes, cosign fetches its own
if [[ -z "${SIGSTORE_ID_TOKEN:-}" && -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo 'no OIDC identity available, skipping signing' >&2
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
  # if it fails here it fails everywhere
  cosign verify-blob "$f" \
    --bundle "$f.sigstore.json" \
    --certificate-identity-regexp '.' \
    --certificate-oidc-issuer-regexp '.'
done
