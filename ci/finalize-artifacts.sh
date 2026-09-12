#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
export LIBGUESTFS_BACKEND=direct

virt-cat --format=raw -a "$img" -m /dev/sda3 /etc/appliance/build.env > "out/$name-build.env"
virt-cat --format=raw -a "$img" -m /dev/sda3 /etc/appliance/packages.txt > "out/$name-packages.txt"

set -a
source "out/$name-build.env"
set +a

python3 ci/make-sbom.py "out/$name-packages.txt" "out/$name-sbom.cdx.json" "$variant"

img_sha=$(sha256sum "out/$name.img" | awk '{print $1}')
zst_sha=$(sha256sum "out/$name.img.zst" | awk '{print $1}')
qcow_sha=$(sha256sum "out/$name.qcow2" | awk '{print $1}')
iso_sha=$(sha256sum "out/$name-installer.iso" | awk '{print $1}')
source_json=$(cat out/base-source.json)
packages_sha=$(sha256sum "out/$name-packages.txt" | awk '{print $1}')

jq -n \
  --arg variant "$variant" \
  --arg build_time "$APPLIANCE_BUILD_TIME" \
  --arg frr "$FRR_VERSION" \
  --arg vpp "$VPP_VERSION" \
  --arg commit "${CI_COMMIT_SHA:-local}" \
  --arg pipeline "${CI_PIPELINE_URL:-local}" \
  --arg runner "${CI_RUNNER_DESCRIPTION:-local}" \
  --arg img "$img_sha" --arg zst "$zst_sha" --arg qcow "$qcow_sha" --arg iso "$iso_sha" --arg packages "$packages_sha" \
  --argjson base "$source_json" \
  '{schema:1,variant:$variant,build_time:$build_time,base:$base,versions:{frr:$frr,vpp:$vpp},git:{commit:$commit},ci:{pipeline:$pipeline,runner:$runner},artifacts:{img:{sha256:$img},img_zst:{sha256:$zst},qcow2:{sha256:$qcow},installer_iso:{sha256:$iso},package_inventory:{sha256:$packages}}}' \
  > "out/$name-build-manifest.json"

jq -n \
  --arg subject "$name" \
  --arg commit "${CI_COMMIT_SHA:-local}" \
  --arg repo "${CI_PROJECT_URL:-local}" \
  --arg pipeline "${CI_PIPELINE_URL:-local}" \
  --arg base_url "$DEBIAN_BASE_URL/$DEBIAN_ISO_NAME" \
  --arg base_sha512 "$DEBIAN_ISO_SHA512" \
  --arg img "$img_sha" --arg zst "$zst_sha" --arg qcow "$qcow_sha" --arg iso "$iso_sha" --arg packages "$packages_sha" \
  '{_type:"https://in-toto.io/Statement/v1",subject:[{name:($subject+".img"),digest:{sha256:$img}},{name:($subject+".img.zst"),digest:{sha256:$zst}},{name:($subject+".qcow2"),digest:{sha256:$qcow}},{name:($subject+"-installer.iso"),digest:{sha256:$iso}}],predicateType:"https://slsa.dev/provenance/v1",predicate:{buildDefinition:{buildType:"https://gitlab.com/frr-appliance/mmdebstrap-libguestfs@v2",externalParameters:{source_repository:$repo,source_commit:$commit},resolvedDependencies:[{uri:$base_url,digest:{sha512:$base_sha512}},{uri:"urn:frr-appliance:installed-packages",digest:{sha256:$packages}}]},runDetails:{builder:{id:$pipeline},metadata:{invocationId:$pipeline}}}}' \
  > "out/$name-provenance.json"

(
  cd out
  sha256sum \
    "$name.img" "$name.img.zst" "$name.qcow2" "$name-installer.iso" \
    "$name-build.env" "$name-packages.txt" "$name-sbom.cdx.json" \
    "$name-build-manifest.json" "$name-provenance.json" \
    | LC_ALL=C sort > "$name-SHA256SUMS"
)
