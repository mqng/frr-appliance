#!/usr/bin/env bash
set -euo pipefail

suite=${1:?}
# nothing newer on packagecloud
[[ "$suite" == bookworm ]] || {
  echo "no fd.io VPP packages for $suite" >&2
  exit 1
}

key=/etc/apt/keyrings/fdio-release.asc
key_sha256=54d4aa534babdf30dfb56760107ff7d69fbe3d09d943e65339cdae00572e7606

install -d -m 0755 /etc/apt/keyrings
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://packagecloud.io/fdio/release/gpgkey \
  -o "$key"
chmod 0644 "$key"

got=$(sha256sum "$key" | awk '{print $1}')
[[ "$got" == "$key_sha256" ]] || {
  echo "fd.io signing key changed, now $got" >&2
  echo 'Check the new key, then set key_sha256 in scripts/install-vpp.sh' >&2
  exit 1
}

cat >/etc/apt/sources.list.d/fdio-release.sources <<'APT'
Types: deb
URIs: https://packagecloud.io/fdio/release/debian/
Suites: bookworm
Components: main
Signed-By: /etc/apt/keyrings/fdio-release.asc
APT

apt-get update

# keep the postinst off the build host's sysctls
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
