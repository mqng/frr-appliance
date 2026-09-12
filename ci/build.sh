#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: build.sh <vanilla|vpp>}
source work/base.env

name="frr-appliance-${variant}-amd64"
workdir="$PWD/work/$variant"
outdir="$PWD/out"
rootfs="$workdir/rootfs.tar"
mkdir -p "$workdir" "$outdir"

# GitLab.com saas-linux hosted runners are privileged. Use mmdebstrap's
# native root mode so package maintainer scripts run in a real chroot rather
# than through fakechroot/LD_PRELOAD emulation.
packages=(
  systemd-sysv linux-image-amd64 initramfs-tools
  grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed dosfstools
  openssh-server sudo ca-certificates curl gnupg
  iproute2 ethtool pciutils kmod tcpdump lsof jq less vim-tiny bash-completion
  iputils-ping traceroute dnsutils mtr-tiny debian-security-support
  nftables chrony auditd apparmor apparmor-utils unattended-upgrades
  libpam-pwquality cloud-guest-utils
)

include=$(IFS=,; echo "${packages[*]}")
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD 2>/dev/null || date +%s)}
export TMPDIR="$workdir/tmp"
mkdir -p "$TMPDIR"

# Fail immediately if the runner cannot perform the mounts required by
# mmdebstrap root mode. GitLab.com saas-linux runners are expected to pass.
probe=$(mktemp -d)
if ! mount -t tmpfs -o size=1m tmpfs "$probe"; then
  rmdir "$probe"
  echo 'Runner lacks CAP_SYS_ADMIN; this pipeline requires a privileged GitLab hosted runner' >&2
  exit 1
fi
umount "$probe"
rmdir "$probe"

mmdebstrap \
  --mode=root \
  --format=tar \
  --variant=minbase \
  --architectures=amd64 \
  --components=main \
  --aptopt='Acquire::Languages "none"' \
  --include="$include" \
  --customize-hook="copy-in scripts config /tmp" \
  --customize-hook="chroot \"\$1\" /usr/bin/env DEBIAN_FRONTEND=noninteractive APPLIANCE_BUILD_EPOCH=$SOURCE_DATE_EPOCH /bin/bash /tmp/scripts/provision-rootfs.sh $variant" \
  --customize-hook='chroot "$1" /bin/bash -c "rm -rf /tmp/scripts /tmp/config /tmp/*"' \
  "$DEBIAN_SUITE" "$rootfs" \
  "deb https://deb.debian.org/debian $DEBIAN_SUITE main" \
  "deb https://deb.debian.org/debian $DEBIAN_SUITE-updates main" \
  "deb https://security.debian.org/debian-security $DEBIAN_SUITE-security main"

bash ci/assemble-image.sh "$variant" "$rootfs" "$outdir/$name.img"
qemu-img convert -p -f raw -O qcow2 -c "$outdir/$name.img" "$outdir/$name.qcow2"
zstd -T0 -15 --long=27 -f "$outdir/$name.img" -o "$outdir/$name.img.zst"

bash ci/build-installer-iso.sh \
  "$variant" "$DEBIAN_ISO_PATH" "$outdir/$name.img" "$outdir/$name-installer.iso"
