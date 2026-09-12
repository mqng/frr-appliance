#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"

# shellcheck source=ci/lib/loop-image.sh
source ci/lib/loop-image.sh
mnt=$(mktemp -d)
loopdev=""
cleanup() {
  set +e
  if mountpoint -q "$mnt"; then umount "$mnt"; fi
  if [[ -n "$loopdev" ]]; then losetup -d "$loopdev" 2>/dev/null || true; fi
  rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

loopdev=$(attach_loop "$img" ro yes)
create_partition_nodes "$loopdev" 3
base=$(basename "$loopdev")
mount -o ro,noload "/dev/${base}p3" "$mnt"
cp "$mnt/etc/appliance/build.env" "out/$name-build.env"
cp "$mnt/etc/appliance/packages.txt" "out/$name-packages.txt"
umount "$mnt"
losetup -d "$loopdev"
loopdev=""

set -a
source "out/$name-build.env"
set +a
python3 ci/make-sbom.py "out/$name-packages.txt" "out/$name-sbom.cdx.json" "$variant"

img_sha=$(sha256sum "out/$name.img" | awk '{print $1}')
zst_sha=$(sha256sum "out/$name.img.zst" | awk '{print $1}')
qcow_sha=$(sha256sum "out/$name.qcow2" | awk '{print $1}')
iso_sha=$(sha256sum "out/$name-installer.iso" | awk '{print $1}')
packages_sha=$(sha256sum "out/$name-packages.txt" | awk '{print $1}')
source_json=$(cat out/base-source.json)
base_iso_url=$(jq -r '.installer_iso_source + "/" + .installer_iso' out/base-source.json)
base_iso_sha512=$(jq -r '.installer_iso_sha512' out/base-source.json)

jq -n \
  --arg variant "$variant" --arg build_time "$APPLIANCE_BUILD_TIME" \
  --arg frr "$FRR_VERSION" --arg vpp "$VPP_VERSION" \
  --arg frr_key "$FRR_KEYRING_SHA256" --arg vpp_key "$VPP_KEYRING_SHA256" \
  --arg commit "${CI_COMMIT_SHA:-local}" --arg pipeline "${CI_PIPELINE_URL:-local}" --arg runner "${CI_RUNNER_DESCRIPTION:-local}" \
  --arg img "$img_sha" --arg zst "$zst_sha" --arg qcow "$qcow_sha" --arg iso "$iso_sha" --arg packages "$packages_sha" \
  --argjson base "$source_json" \
  '{schema:1,variant:$variant,build_time:$build_time,base:$base,versions:{frr:$frr,vpp:$vpp},repository_keys:{frr_sha256:$frr_key,vpp_sha256:$vpp_key},git:{commit:$commit},ci:{pipeline:$pipeline,runner:$runner},artifacts:{img:{sha256:$img},img_zst:{sha256:$zst},qcow2:{sha256:$qcow},installer_iso:{sha256:$iso},package_inventory:{sha256:$packages}}}' \
  > "out/$name-build-manifest.json"

jq -n \
  --arg subject "$name" --arg commit "${CI_COMMIT_SHA:-local}" --arg repo "${CI_PROJECT_URL:-local}" --arg pipeline "${CI_PIPELINE_URL:-local}" \
  --arg base_url "$base_iso_url" --arg base_sha512 "$base_iso_sha512" \
  --arg frr_key "$FRR_KEYRING_SHA256" --arg vpp_key "$VPP_KEYRING_SHA256" \
  --arg img "$img_sha" --arg zst "$zst_sha" --arg qcow "$qcow_sha" --arg iso "$iso_sha" --arg packages "$packages_sha" \
  '{_type:"https://in-toto.io/Statement/v1",subject:[{name:($subject+".img"),digest:{sha256:$img}},{name:($subject+".img.zst"),digest:{sha256:$zst}},{name:($subject+".qcow2"),digest:{sha256:$qcow}},{name:($subject+"-installer.iso"),digest:{sha256:$iso}}],predicateType:"https://slsa.dev/provenance/v1",predicate:{buildDefinition:{buildType:"https://gitlab.com/frr-appliance/mmdebstrap-loop@v3",externalParameters:{source_repository:$repo,source_commit:$commit},resolvedDependencies:([{uri:$base_url,digest:{sha512:$base_sha512}},{uri:"https://deb.frrouting.org/frr/keys.gpg",digest:{sha256:$frr_key}},{uri:"urn:frr-appliance:installed-packages",digest:{sha256:$packages}}] + (if $vpp_key != "none" then [{uri:"https://packagecloud.io/fdio/release/gpgkey",digest:{sha256:$vpp_key}}] else [] end))},runDetails:{builder:{id:$pipeline},metadata:{invocationId:$pipeline}}}}' \
  > "out/$name-provenance.json"

(
  cd out
  sha256sum \
    "$name.img" "$name.img.zst" "$name.qcow2" "$name-installer.iso" \
    "$name-build.env" "$name-packages.txt" "$name-sbom.cdx.json" \
    "$name-build-manifest.json" "$name-provenance.json" \
    | LC_ALL=C sort > "$name-SHA256SUMS"
)
