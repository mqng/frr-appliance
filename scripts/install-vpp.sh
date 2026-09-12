#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}
[[ "$suite" == bookworm ]] || { echo 'VPP release packages are intentionally restricted to Debian Bookworm' >&2; exit 1; }

install -d -m 0755 /etc/apt/keyrings
keyring=/etc/apt/keyrings/fdio-release.asc
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://packagecloud.io/fdio/release/gpgkey -o "$keyring"
chmod 0644 "$keyring"

# Keep read-only key inspection isolated from the image's persistent GnuPG state.
gpg_home=$(mktemp -d)
chmod 0700 "$gpg_home"
trap 'rm -rf "$gpg_home"' EXIT

# packagecloud currently identifies the fdio/release APT signing key by the
# 64-bit key ID 9CD4562700859B62. Require a single primary key with that suffix.
mapfile -t fingerprints < <(gpg --homedir "$gpg_home" --batch --no-options --with-colons --show-keys "$keyring" | awk -F: '
  $1=="pub" {want=1; next}
  $1=="fpr" && want {print toupper($10); want=0}
')
[[ ${#fingerprints[@]} -eq 1 ]] || { echo 'Unexpected fdio/release key bundle shape' >&2; exit 1; }
[[ "${fingerprints[0]}" == *9CD4562700859B62 ]] || {
  echo "Unexpected fdio/release key: ${fingerprints[0]}" >&2
  exit 1
}

cat > /etc/apt/sources.list.d/fdio-release.sources <<APT
Types: deb
URIs: https://packagecloud.io/fdio/release/debian/
Suites: bookworm
Components: main
Signed-By: /etc/apt/keyrings/fdio-release.asc
APT

apt-get update
apt-get install -y --no-install-recommends \
  vpp vpp-plugin-core vpp-plugin-dpdk vpp-drivers numactl
