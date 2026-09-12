#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"

# GitLab hands us a token up front through id_tokens. GitHub Actions tokens live
# only about five minutes, far less than a build takes, so there cosign fetches a
# fresh one itself from the OIDC endpoint at the moment it signs.
if [[ -z "${SIGSTORE_ID_TOKEN:-}" && -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo 'No OIDC identity available; skipping keyless signing' >&2
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
