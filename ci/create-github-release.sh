#!/usr/bin/env bash
set -euo pipefail


: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_RUN_ID:?}"
: "${GITHUB_RUN_NUMBER:?}"
: "${GH_TOKEN:?export GH_TOKEN so gh can authenticate}"

run_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

if [[ "${GITHUB_REF_TYPE:-}" == tag && -n "${GITHUB_REF_NAME:-}" ]]; then
  version=$GITHUB_REF_NAME
  tag=$GITHUB_REF_NAME
else
  version="$(date -u +%Y%m%d)-$GITHUB_RUN_NUMBER"
  tag="appliance-$version"
fi

env_value() { grep -m1 "^$2=" "$1" | cut -d= -f2-; }

assets=()
variants=()
rows=""
for variant in vanilla vpp; do
  name="frr-appliance-${variant}-amd64"
  [[ -f "out/$name-SHA256SUMS" ]] || continue
  variants+=("$variant")

  build_env="out/$name-build.env"
  if [[ -r "$build_env" ]]; then
    vpp_version=$(env_value "$build_env" VPP_VERSION)
    [[ "$vpp_version" != none ]] || vpp_version=-
    rows+=$(printf '| %s | %s (%s) | %s (%s) | %s |\n' \
      "$variant" \
      "$(env_value "$build_env" DEBIAN_VERSION)" \
      "$(env_value "$build_env" DEBIAN_CODENAME)" \
      "$(env_value "$build_env" FRR_VERSION)" \
      "$(env_value "$build_env" FRR_CHANNEL)" \
      "$vpp_version")
    rows+=$'\n'
  fi

  files=(
    "$name.img.zst"
    "$name.qcow2"
    "$name-installer.iso"
    "$name-SHA256SUMS"
    "$name-build.env"
    "$name-packages.txt"
    "$name-sbom.cdx.json"
    "$name-build-manifest.json"
    "$name-provenance.json"
  )
  if [[ ${PUBLISH_RAW_IMG:-false} == true ]]; then files+=("$name.img"); fi

  for file in "${files[@]}"; do
    if [[ ! -f "out/$file" ]]; then
      echo "missing release asset: out/$file" >&2
      exit 1
    fi
    assets+=("out/$file")
  done
  for sig in out/"$name"*.sigstore.json; do
    if [[ -f "$sig" ]]; then assets+=("$sig"); fi
  done
done

[[ ${#variants[@]} -gt 0 ]] || { echo 'no build output in ./out' >&2; exit 1; }

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<NOTES
FRR appliance build from [run $GITHUB_RUN_NUMBER]($run_url), commit \`$GITHUB_SHA\`.

| Variant | Debian | FRR | VPP |
| --- | --- | --- | --- |
$rows
Verify the checksums and signatures before use:

\`\`\`
sha256sum --check --ignore-missing frr-appliance-vanilla-amd64-SHA256SUMS

cosign verify-blob frr-appliance-vanilla-amd64.img.zst \\
  --bundle frr-appliance-vanilla-amd64.img.zst.sigstore.json \\
  --certificate-identity-regexp "^${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/" \\
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
\`\`\`
NOTES

if gh release view "$tag" >/dev/null 2>&1; then
  gh release delete "$tag" --yes --cleanup-tag
fi

gh release create "$tag" \
  --target "$GITHUB_SHA" \
  --title "FRR appliance $version" \
  --notes-file "$notes" \
  "${assets[@]}"
