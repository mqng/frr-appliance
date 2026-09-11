#!/usr/bin/env bash
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl debian-keyring gnupg gpgv jq \
  qemu-system-x86 qemu-utils ovmf \
  xorriso gzip zstd python3 coreutils util-linux \
  libguestfs-tools file
rm -rf /var/lib/apt/lists/*

COSIGN_VERSION=${COSIGN_VERSION:-3.1.3}
case "$COSIGN_VERSION" in
  3.1.3) COSIGN_SHA256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 ;;
  *) echo "Unreviewed COSIGN_VERSION=$COSIGN_VERSION; add its reviewed checksum first" >&2; exit 1 ;;
esac
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" \
  -o /usr/local/bin/cosign
echo "$COSIGN_SHA256  /usr/local/bin/cosign" | sha256sum --check --strict -
chmod 0755 /usr/local/bin/cosign
cosign version
