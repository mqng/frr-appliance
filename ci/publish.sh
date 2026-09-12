#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"

if [[ -z "${CI_API_V4_URL:-}" || -z "${CI_PROJECT_ID:-}" || -z "${CI_JOB_TOKEN:-}" ]]; then
  echo "Not running in GitLab CI; artifacts left in ./out"
  exit 0
fi

version=${CI_COMMIT_TAG:-$(date -u +%Y%m%d)-${CI_PIPELINE_IID}}
package="frr-appliance-$variant"
base="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/${package}/${version}"

files=(
  "out/$name.img.zst"
  "out/$name.qcow2"
  "out/$name-installer.iso"
  "out/$name-SHA256SUMS"
  "out/$name-build.env"
  "out/$name-packages.txt"
  "out/$name-sbom.cdx.json"
  "out/$name-build-manifest.json"
  "out/$name-provenance.json"
)
if [[ ${PUBLISH_RAW_IMG:-true} == true ]]; then files+=("out/$name.img"); fi
for sig in out/$name*.sigstore.json; do [[ -f "$sig" ]] && files+=("$sig"); done

for f in "${files[@]}"; do
  b=$(basename "$f")
  echo "Publishing $b"
  curl --fail-with-body --location --retry 4 --retry-all-errors \
    --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    --upload-file "$f" "$base/$b"
done

cat > "out/publish.env" <<ENV
PACKAGE_VERSION=$version
PACKAGE_NAME=$package
PACKAGE_BASE_URL=$base
ENV
