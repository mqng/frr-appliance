#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}
[[ "$suite" == bookworm ]] || { echo 'VPP release packages are restricted to Debian Bookworm' >&2; exit 1; }

install -d -m 0755 /etc/apt/keyrings
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://packagecloud.io/fdio/release/gpgkey \
  -o /etc/apt/keyrings/fdio-release.asc
chmod 0644 /etc/apt/keyrings/fdio-release.asc

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
