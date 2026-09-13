#!/usr/bin/env bash
set -euo pipefail

arch=$(dpkg --print-architecture)
case "$arch" in
  amd64) firmware_packages=(qemu-system-x86 ovmf) ;;
  arm64) firmware_packages=(qemu-system-arm qemu-efi-aarch64) ;;
  *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl debian-keyring debian-archive-keyring gnupg gpgv jq \
  mmdebstrap \
  parted dosfstools e2fsprogs util-linux udev \
  qemu-utils ipxe-qemu "${firmware_packages[@]}" \
  xorriso gzip zstd python3 coreutils file passwd shellcheck
rm -rf /var/lib/apt/lists/*

# shellcheck source=ci/lib/loop-image.sh
source ci/lib/loop-image.sh
loop_preflight

COSIGN_VERSION=${COSIGN_VERSION:-3.1.3}
case "$COSIGN_VERSION-$arch" in
  3.1.3-amd64) COSIGN_SHA256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 ;;
  3.1.3-arm64) COSIGN_SHA256=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a ;;
  *)
    echo "unreviewed cosign build: $COSIGN_VERSION-$arch" >&2
    echo "get the hash from cosign_checksums.txt of that release, then add it here" >&2
    exit 1
    ;;
esac
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${arch}" \
  -o /usr/local/bin/cosign
echo "$COSIGN_SHA256  /usr/local/bin/cosign" | sha256sum --check --strict -
chmod 0755 /usr/local/bin/cosign
