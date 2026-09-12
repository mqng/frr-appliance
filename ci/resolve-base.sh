#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
mkdir -p work/base out

case "$variant" in
  vanilla)
    suite=trixie
    expected_major=13
    base_url=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd
    ;;
  vpp)
    suite=bookworm
    expected_major=12
    base_url=https://cdimage.debian.org/cdimage/archive/12.15.0/amd64/iso-cd
    ;;
  *) exit 2 ;;
esac

# ISO is only the installer boot env, rootfs comes from apt
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

iso_name=$(awk '$2 ~ /^debian-[0-9.]+-amd64-netinst\.iso$/ {print $2; exit}' work/base/SHA512SUMS)
[[ -n "$iso_name" ]] || { echo 'Unable to resolve Debian netinst ISO' >&2; exit 1; }

curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  "$base_url/$iso_name" -o "work/base/$iso_name"
(
  cd work/base
  grep "  $iso_name\$" SHA512SUMS | sha512sum --check --strict -
)

version=${iso_name#debian-}
version=${version%-amd64-netinst.iso}
[[ "$version" == "$expected_major".* ]] || {
  echo "unreviewed Debian major: expected $expected_major.x, got $version" >&2
  exit 1
}

sha512=$(sha512sum "work/base/$iso_name" | awk '{print $1}')
cat > work/base.env <<ENV
APPLIANCE_VARIANT=$variant
DEBIAN_SUITE=$suite
DEBIAN_VERSION=$version
DEBIAN_ISO_NAME=$iso_name
DEBIAN_ISO_PATH=$PWD/work/base/$iso_name
DEBIAN_ISO_SHA512=$sha512
DEBIAN_BASE_URL=$base_url
DEBIAN_APT_MIRROR=https://deb.debian.org/debian
DEBIAN_SECURITY_MIRROR=https://security.debian.org/debian-security
ENV

cat > out/base-source.json <<JSON
{
  "variant": "$variant",
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
