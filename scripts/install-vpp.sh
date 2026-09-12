#!/usr/bin/env bash
set -euo pipefail

suite=${1:?}
[[ "$suite" == bookworm ]] || {
  echo 'VPP release packages are restricted to Debian Bookworm' >&2
  exit 1
}

install -d -m 0755 /etc/apt/keyrings

curl \
  --fail \
  --location \
  --retry 4 \
  --retry-all-errors \
  --proto '=https' \
  --tlsv1.2 \
  https://packagecloud.io/fdio/release/gpgkey \
  -o /etc/apt/keyrings/fdio-release.asc

chmod 0644 /etc/apt/keyrings/fdio-release.asc

cat >/etc/apt/sources.list.d/fdio-release.sources <<'APT'
Types: deb
URIs: https://packagecloud.io/fdio/release/debian/
Suites: bookworm
Components: main
Signed-By: /etc/apt/keyrings/fdio-release.asc
APT

apt-get update

# VPP's package postinst normally applies its sysctl settings immediately.
# During image construction we must not modify the CI runner's kernel.
# The sysctl files remain in the image and are applied normally on boot.
VPP_INSTALL_SKIP_SYSCTL=true \
  apt-get install -y --no-install-recommends \
    vpp \
    vpp-plugin-core \
    vpp-plugin-dpdk \
    vpp-drivers \
    numactl

dpkg-query -W \
  vpp \
  vpp-plugin-core \
  vpp-plugin-dpdk \
  vpp-drivers
