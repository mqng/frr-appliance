#!/usr/bin/env bash
set -euo pipefail

# Publishes the artifacts collected in ./out as a GitHub release.
#
# The GitLab pipeline uploads images to the generic package registry and links
# them from a release (ci/publish.sh, ci/create-release.sh). GitHub has no
# equivalent registry, so the files are attached to the release directly. That
# caps each asset at 2 GiB, which is why the 4 GiB raw image is not published
# from GitHub; PUBLISH_RAW_IMG defaults to false here.

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_RUN_ID:?}"
: "${GITHUB_RUN_NUMBER:?}"
: "${GH_TOKEN:?export GH_TOKEN so gh can authenticate}"

run_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

# Mirrors the GitLab version scheme: a tag if we are on one, otherwise the build
# date plus the run counter.
if [[ "${GITHUB_REF_TYPE:-}" == tag && -n "${GITHUB_REF_NAME:-}" ]]; then
  version=$GITHUB_REF_NAME
  tag=$GITHUB_REF_NAME
else
  version="$(date -u +%Y%m%d)-$GITHUB_RUN_NUMBER"
  tag="appliance-$version"
fi

assets=()
variants=()
for variant in vanilla vpp; do
  name="frr-appliance-${variant}-amd64"
  # A dispatched run can build a single variant, so absent output is not a fault.
  [[ -f "out/$name-SHA256SUMS" ]] || continue
  variants+=("$variant")

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
      echo "Missing release asset: out/$file" >&2
      exit 1
    fi
    assets+=("out/$file")
  done
  for sig in out/"$name"*.sigstore.json; do
    if [[ -f "$sig" ]]; then assets+=("$sig"); fi
  done
done

[[ ${#variants[@]} -gt 0 ]] || { echo 'No appliance build output found in ./out' >&2; exit 1; }

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<NOTES
Automated FRR appliance build from [run $GITHUB_RUN_NUMBER]($run_url).

- Variants: ${variants[*]}
- Commit: \`$GITHUB_SHA\`

Verify the checksums and the Sigstore bundles before deploying anything:

\`\`\`
sha256sum --check --ignore-missing frr-appliance-vanilla-amd64-SHA256SUMS

cosign verify-blob frr-appliance-vanilla-amd64.img.zst \\
  --bundle frr-appliance-vanilla-amd64.img.zst.sigstore.json \\
  --certificate-identity-regexp "^${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/" \\
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
\`\`\`
NOTES

# A re-run must not leave assets from the previous attempt attached, so the
# release and its tag are recreated rather than amended.
if gh release view "$tag" >/dev/null 2>&1; then
  gh release delete "$tag" --yes --cleanup-tag
fi

gh release create "$tag" \
  --target "$GITHUB_SHA" \
  --title "FRR Appliance $version" \
  --notes-file "$notes" \
  "${assets[@]}"
