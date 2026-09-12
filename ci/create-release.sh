#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CI_COMMIT_TAG:-}" ]]; then
  version=$CI_COMMIT_TAG
else
  pipeline_date=${CI_PIPELINE_CREATED_AT%%T*}
  pipeline_date=${pipeline_date//-/}
  version="${pipeline_date}-${CI_PIPELINE_IID}"
fi
tag="appliance-$version"
api="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/releases"

links='[]'
for variant in vanilla vpp; do
  name="frr-appliance-${variant}-amd64"
  pkg="frr-appliance-${variant}"
  base="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/${pkg}/${version}"
  signed_files=("$name.img.zst" "$name.qcow2" "$name-installer.iso" "$name-SHA256SUMS" "$name-build-manifest.json" "$name-provenance.json" "$name-sbom.cdx.json")
  for file in "${signed_files[@]}"; do
    links=$(jq --arg n "$variant/$file" --arg u "$base/$file" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
    sig="$file.sigstore.json"
    links=$(jq --arg n "$variant/$sig" --arg u "$base/$sig" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
  done
  if [[ ${PUBLISH_RAW_IMG:-true} == true ]]; then
    file="$name.img"
    links=$(jq --arg n "$variant/$file" --arg u "$base/$file" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
    sig="$file.sigstore.json"
    links=$(jq --arg n "$variant/$sig" --arg u "$base/$sig" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
  fi
done

payload=$(jq -n \
  --arg tag "$tag" --arg ref "$CI_COMMIT_SHA" \
  --arg name "FRR Appliance $version" \
  --arg desc "Automated FRR appliance build from pipeline $CI_PIPELINE_URL. Verify SHA256SUMS and Sigstore bundles before deployment." \
  --argjson links "$links" \
  '{tag_name:$tag,ref:$ref,name:$name,description:$desc,assets:{links:$links}}')

curl --fail-with-body --request POST \
  --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data "$payload" "$api"
