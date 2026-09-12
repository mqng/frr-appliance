#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"

# shellcheck source=ci/lib/loop-image.sh
source ci/lib/loop-image.sh
mnt=$(mktemp -d)
loopdev=""
cleanup() {
  set +e
  if mountpoint -q "$mnt/boot/efi"; then umount "$mnt/boot/efi"; fi
  if mountpoint -q "$mnt"; then umount "$mnt"; fi
  [[ -n "$loopdev" ]] && losetup -d "$loopdev" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

loopdev=$(attach_loop "$img" ro yes)
create_partition_nodes "$loopdev" 3
base=$(basename "$loopdev")
mount -o ro,noload "/dev/${base}p3" "$mnt"
mkdir -p "$mnt/boot/efi"
mount -o ro "/dev/${base}p2" "$mnt/boot/efi"

test -s "$mnt/etc/appliance/build.env"
test -s "$mnt/etc/appliance/packages.txt"
test -s "$mnt/etc/frr/frr.conf"
test -s "$mnt/boot/grub/grub.cfg"
test -s "$mnt/boot/efi/EFI/BOOT/BOOTX64.EFI"
test -s "$mnt/boot/efi/EFI/debian/grub.cfg"
root_uuid=$(blkid -s UUID -o value "/dev/${base}p3")
esp_uuid=$(blkid -s UUID -o value "/dev/${base}p2")
grep -q "^UUID=$root_uuid / ext4 " "$mnt/etc/fstab"
grep -q "^UUID=$esp_uuid /boot/efi vfat " "$mnt/etc/fstab"
grep -Eq "root=UUID=${root_uuid}([[:space:]]|$)" "$mnt/boot/grub/grub.cfg"
! grep -Eq 'root=/dev/loop[0-9]+p?[0-9]*' "$mnt/boot/grub/grub.cfg"
grep -q 'console=ttyS0,115200n8' "$mnt/boot/grub/grub.cfg"
chroot "$mnt" dpkg-query -W frr >/dev/null
if [[ "$variant" == vpp ]]; then
  chroot "$mnt" dpkg-query -W vpp >/dev/null
  test -s "$mnt/etc/appliance/vpp-dpdk.conf"
fi
