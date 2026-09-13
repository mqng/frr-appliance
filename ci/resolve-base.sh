#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
mkdir -p work/base out

case "$variant" in
  vanilla) suite=trixie ;;
  vpp)     suite=bookworm ;;
  *) exit 2 ;;
esac

arch=$(dpkg --print-architecture)
case "$arch" in
  amd64) serial=ttyS0 ;;
  arm64) serial=ttyAMA0 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac
if [[ "$variant" == vpp && "$arch" != amd64 ]]; then
  echo "the vpp dataplane is reviewed on amd64 only, not $arch" >&2
  exit 2
fi

expected_major=13
base_url=https://cdimage.debian.org/debian-cd/current/$arch/iso-cd

curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  "$base_url/SHA512SUMS" -o work/base/SHA512SUMS
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  "$base_url/SHA512SUMS.sign" -o work/base/SHA512SUMS.sign

keyring_args=()
for candidate in   /usr/share/keyrings/debian-role-keys.gpg   /usr/share/keyrings/debian-keyring.gpg   /usr/share/keyrings/debian-archive-keyring.gpg
do
  [[ -r "$candidate" ]] && keyring_args+=(--keyring "$candidate")
done
[[ ${#keyring_args[@]} -gt 0 ]] || { echo 'No Debian verification keyring found' >&2; exit 1; }
gpgv "${keyring_args[@]}" work/base/SHA512SUMS.sign work/base/SHA512SUMS

iso_name=$(awk -v arch="$arch" \
  '$2 ~ ("^debian-[0-9.]+-" arch "-netinst\\.iso$") {print $2; exit}' work/base/SHA512SUMS)
[[ -n "$iso_name" ]] || { echo 'Unable to resolve Debian netinst ISO' >&2; exit 1; }

curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  "$base_url/$iso_name" -o "work/base/$iso_name"
(
  cd work/base
  grep "  $iso_name\$" SHA512SUMS | sha512sum --check --strict -
)

version=${iso_name#debian-}
version=${version%-"$arch"-netinst.iso}
[[ "$version" == "$expected_major".* ]] || {
  echo "unreviewed Debian major: expected $expected_major.x, got $version" >&2
  exit 1
}

sha512=$(sha512sum "work/base/$iso_name" | awk '{print $1}')
cat > work/base.env <<ENV
APPLIANCE_ARCH=$arch
APPLIANCE_SERIAL=$serial
DEBIAN_SUITE=$suite
DEBIAN_ISO_PATH=$PWD/work/base/$iso_name
ENV

cat > out/base-source.json <<JSON
{
  "variant": "$variant",
  "arch": "$arch",
  "debian_suite": "$suite",
  "debian_version": "$version",
  "rootfs_sources": [
    "https://deb.debian.org/debian",
    "https://security.debian.org/debian-security"
  ],
  "installer_iso": "$iso_name",
  "installer_iso_sha512": "$sha512",
  "installer_iso_source": "$base_url"
}
JSON
