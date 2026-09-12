#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
rootfs=${2:?}
img=${3:?}
size=${DISK_SIZE:-4G}

rm -f "$img"
truncate -s "$size" "$img"
export LIBGUESTFS_BACKEND=direct

# GPT: 2 MiB BIOS boot, 512 MiB ESP, remainder ext4 root.
guestfish --format=raw -a "$img" <<EOF_GUEST
run
part-init /dev/sda gpt
part-add /dev/sda p 2048 6143
part-add /dev/sda p 6144 1054719
part-add /dev/sda p 1054720 -2048
part-set-gpt-type /dev/sda 1 21686148-6449-6E6F-744E-656564454649
part-set-gpt-type /dev/sda 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
part-set-name /dev/sda 1 BIOS-BOOT
part-set-name /dev/sda 2 EFI-SYSTEM
part-set-name /dev/sda 3 ROOT
mkfs fat /dev/sda2 label:EFI
mkfs ext4 /dev/sda3 label:rootfs
mount /dev/sda3 /
mkdir-p /boot/efi
mount /dev/sda2 /boot/efi
tar-in $rootfs / xattrs:true
write /boot/grub/device.map "(hd0) /dev/sda\n"
command "/usr/local/libexec/frr-appliance-image-finalize $variant"
rm /usr/local/libexec/frr-appliance-image-finalize
sync
umount-all
shutdown
EOF_GUEST
