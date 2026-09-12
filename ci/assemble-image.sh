#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
rootfs=${2:?}
img=${3:?}
size=${DISK_SIZE:-4G}

# shellcheck source=ci/lib/loop-image.sh
source ci/lib/loop-image.sh

mnt=$(mktemp -d)
loopdev=""
root_uuid=""
esp_uuid=""
cleanup() {
  set +e
  if mountpoint -q "$mnt/run"; then umount "$mnt/run"; fi
  if mountpoint -q "$mnt/sys"; then umount -R "$mnt/sys"; fi
  if mountpoint -q "$mnt/proc"; then umount "$mnt/proc"; fi
  if mountpoint -q "$mnt/dev"; then umount -R "$mnt/dev"; fi
  if mountpoint -q "$mnt/boot/efi"; then umount "$mnt/boot/efi"; fi
  if mountpoint -q "$mnt"; then umount "$mnt"; fi
  if [[ -n "$root_uuid" ]]; then rm -f "/dev/disk/by-uuid/$root_uuid" 2>/dev/null || true; fi
  if [[ -n "$esp_uuid" ]]; then rm -f "/dev/disk/by-uuid/$esp_uuid" 2>/dev/null || true; fi
  if [[ -n "$loopdev" ]]; then losetup -d "$loopdev" 2>/dev/null || true; fi
  rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

rm -f "$img"
truncate -s "$size" "$img"
loopdev=$(attach_loop "$img" rw yes)

parted -s "$loopdev" \
  mklabel gpt \
  mkpart BIOS-BOOT 1MiB 3MiB \
  set 1 bios_grub on \
  mkpart EFI-SYSTEM fat32 3MiB 515MiB \
  set 2 esp on \
  mkpart ROOT ext4 515MiB 100%
create_partition_nodes "$loopdev" 3

base=$(basename "$loopdev")
esp="/dev/${base}p2"
root="/dev/${base}p3"

mkfs.vfat -F 32 -n EFI "$esp" >/dev/null
mkfs.ext4 -F -L rootfs "$root" >/dev/null

root_uuid=$(blkid -s UUID -o value "$root")
esp_uuid=$(blkid -s UUID -o value "$esp")
[[ -n "$root_uuid" && -n "$esp_uuid" ]] || { echo 'Failed to read filesystem UUIDs' >&2; exit 1; }

mount "$root" "$mnt"
mkdir -p "$mnt/boot/efi"
mount "$esp" "$mnt/boot/efi"
tar --numeric-owner --xattrs --xattrs-include='*' --acls -xf "$rootfs" -C "$mnt"

# no loop device names in the image
cat > "$mnt/etc/fstab" <<FSTAB
UUID=$root_uuid / ext4 defaults,errors=remount-ro 0 1
UUID=$esp_uuid /boot/efi vfat umask=0077 0 1
FSTAB

# 10_linux needs by-uuid symlinks and there is no udev here
mkdir -p /dev/disk/by-uuid
ln -sfn "../../${base}p3" "/dev/disk/by-uuid/$root_uuid"
ln -sfn "../../${base}p2" "/dev/disk/by-uuid/$esp_uuid"

mount --rbind /dev "$mnt/dev"
mount --make-rslave "$mnt/dev"
mount -t proc proc "$mnt/proc"
mount --rbind /sys "$mnt/sys"
mount --make-rslave "$mnt/sys"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$mnt/run"

chroot "$mnt" /usr/local/libexec/frr-appliance-image-finalize "$variant" "$loopdev" "$root_uuid"
rm -f "$mnt/usr/local/libexec/frr-appliance-image-finalize"
sync
