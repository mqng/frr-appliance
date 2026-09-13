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

env_value() { grep -m1 "^$2=" "$1" | cut -d= -f2-; }

links='[]'
rows=""
for sums in out/frr-appliance-*-SHA256SUMS; do
  [[ -f "$sums" ]] || continue
  name=$(basename "$sums" -SHA256SUMS)
  target=${name#frr-appliance-}
  variant=${target%-*}
  arch=${target##*-}
  pkg="frr-appliance-${variant}-${arch}"

  build_env="out/$name-build.env"
  if [[ -r "$build_env" ]]; then
    vpp_version=$(env_value "$build_env" VPP_VERSION)
    [[ "$vpp_version" != none ]] || vpp_version=-
    rows+=$(printf '| %s | %s | %s (%s) | %s (%s) | %s |' \
      "$variant" "$arch" \
      "$(env_value "$build_env" DEBIAN_VERSION)" \
      "$(env_value "$build_env" DEBIAN_CODENAME)" \
      "$(env_value "$build_env" FRR_VERSION)" \
      "$(env_value "$build_env" FRR_CHANNEL)" \
      "$vpp_version")
    rows+=$'\n'
  fi

  base="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/${pkg}/${version}"
  signed_files=("$name.img.zst" "$name.qcow2" "$name-installer.iso" "$name-SHA256SUMS" "$name-build-manifest.json" "$name-provenance.json" "$name-sbom.cdx.json")
  for file in "${signed_files[@]}"; do
    links=$(jq --arg n "$target/$file" --arg u "$base/$file" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
    sig="$file.sigstore.json"
    links=$(jq --arg n "$target/$sig" --arg u "$base/$sig" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
  done
  if [[ ${PUBLISH_RAW_IMG:-true} == true ]]; then
    file="$name.img"
    links=$(jq --arg n "$target/$file" --arg u "$base/$file" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
    sig="$file.sigstore.json"
    links=$(jq --arg n "$target/$sig" --arg u "$base/$sig" '. + [{name:$n,url:$u,link_type:"package"}]' <<<"$links")
  fi
done

desc=$(cat <<DESC
FRR appliance build from $CI_PIPELINE_URL, commit $CI_COMMIT_SHA.

| Variant | Arch | Debian | FRR | VPP |
| --- | --- | --- | --- | --- |
$rows
Verify SHA256SUMS and the Sigstore bundles before use.
DESC
)

payload=$(jq -n \
  --arg tag "$tag" --arg ref "$CI_COMMIT_SHA" \
  --arg name "FRR appliance $version" \
  --arg desc "$desc" \
  --argjson links "$links" \
  '{tag_name:$tag,ref:$ref,name:$name,description:$desc,assets:{links:$links}}')

status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$api/$tag")
case "$status" in
  200)
    curl --fail-with-body --request DELETE \
      --header "JOB-TOKEN: ${CI_JOB_TOKEN}" "$api/$tag" >/dev/null
    ;;
  404) ;;
  *) echo "unexpected release lookup status: $status" >&2; exit 1 ;;
esac

curl --fail-with-body --request POST \
  --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data "$payload" "$api"
