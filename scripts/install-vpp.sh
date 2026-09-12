#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}
[[ "$suite" == bookworm ]] || { echo "VPP release packages are intentionally restricted to Debian Bookworm" >&2; exit 1; }

install -d -m 0755 /etc/apt/keyrings
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://packagecloud.io/fdio/release/gpgkey -o /tmp/fdio-release.asc

fpr=$(gpg --homedir "${GNUPGHOME:?}" --batch --show-keys --with-colons /tmp/fdio-release.asc | awk -F: '
  $1=="pub" {want=1; next}
  $1=="fpr" && want {print toupper($10); exit}
')
[[ "$fpr" == *9CD4562700859B62 ]] || { echo "Unexpected fdio/release key: $fpr" >&2; exit 1; }
gpg --homedir "${GNUPGHOME:?}" --batch --yes --dearmor -o /etc/apt/keyrings/fdio-release.gpg /tmp/fdio-release.asc

cat > /etc/apt/sources.list.d/fdio-release.list <<APT
deb [signed-by=/etc/apt/keyrings/fdio-release.gpg] https://packagecloud.io/fdio/release/debian/ bookworm main
APT
apt-get update
apt-get install -y --no-install-recommends vpp vpp-plugin-core vpp-plugin-dpdk vpp-drivers numactl
