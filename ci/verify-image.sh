#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
export LIBGUESTFS_BACKEND=direct

# Offline verification catches image/layout errors without booting another VM.
guestfish --ro --format=raw -a "$img" <<'EOF_GUEST'
run
mount-ro /dev/sda3 /
mount-ro /dev/sda2 /boot/efi
command "test -s /etc/appliance/build.env"
command "test -s /etc/appliance/packages.txt"
command "test -s /etc/frr/frr.conf"
command "test -s /boot/grub/grub.cfg"
command "test -s /boot/efi/EFI/BOOT/BOOTX64.EFI"
command "test -s /boot/efi/EFI/BOOT/grub.cfg"
command "test -s /boot/efi/EFI/debian/grub.cfg"
command "dpkg-query -W frr"
command "grep -q '^LABEL=rootfs / ' /etc/fstab"
command "grep -q 'console=ttyS0,115200n8' /boot/grub/grub.cfg"
umount-all
shutdown
EOF_GUEST

if [[ "$variant" == vpp ]]; then
  guestfish --ro --format=raw -a "$img" <<'EOF_GUEST'
run
mount-ro /dev/sda3 /
command "dpkg-query -W vpp"
command "test -s /etc/appliance/vpp-dpdk.conf"
umount-all
shutdown
EOF_GUEST
fi
