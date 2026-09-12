#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: build.sh <vanilla|vpp>}
source work/base.env

name="frr-appliance-${variant}-amd64"
workdir="$PWD/work/$variant"
outdir="$PWD/out"
rootfs="$workdir/rootfs.tar"
mkdir -p "$workdir" "$outdir"

packages=(
  systemd-sysv linux-image-amd64 initramfs-tools busybox
  grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed dosfstools
  openssh-server sudo ca-certificates curl gnupg dbus
  iproute2 ethtool pciutils kmod tcpdump lsof jq less vim-tiny bash-completion
  iputils-ping traceroute dnsutils mtr-tiny debian-security-support
  nftables chrony auditd apparmor apparmor-utils unattended-upgrades
  libpam-pwquality cracklib-runtime cloud-guest-utils zstd snmpd
)

include=$(IFS=,; echo "${packages[*]}")
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git show -s --format=%ct HEAD 2>/dev/null || date +%s)}
export TMPDIR="$workdir/tmp"
mkdir -p "$TMPDIR"

probe=$(mktemp -d)
if ! mount -t tmpfs -o size=1m tmpfs "$probe"; then
  rmdir "$probe"
  echo 'runner lacks CAP_SYS_ADMIN; this build needs a privileged runner' >&2
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
  --dpkgopt='path-exclude=/usr/share/doc/*' \
  --dpkgopt='path-include=/usr/share/doc/*/copyright' \
  --dpkgopt='path-exclude=/usr/share/locale/*' \
  --dpkgopt='path-include=/usr/share/locale/en*' \
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
