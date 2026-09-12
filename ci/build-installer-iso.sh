#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
base_iso=${2:?}
raw_img=${3:?}
out_iso=${4:?}

# shellcheck source=ci/lib/loop-image.sh
source ci/lib/loop-image.sh

workdir="$PWD/work/${variant}/installer-iso"
rm -rf "$workdir"
mkdir -p "$workdir"

gzip -1 -c "$raw_img" > "$workdir/appliance.img.gz"
sha256sum "$workdir/appliance.img.gz" | sed 's#  .*/#  #' > "$workdir/SHA256SUMS"

# appended cpio breaks the ORDER files
mnt=$(mktemp -d)
loopdev=""
cleanup() {
  set +e
  mountpoint -q "$mnt/run" && umount "$mnt/run" || true
  mountpoint -q "$mnt/sys" && umount -R "$mnt/sys" || true
  mountpoint -q "$mnt/proc" && umount "$mnt/proc" || true
  mountpoint -q "$mnt/dev" && umount -R "$mnt/dev" || true
  mountpoint -q "$mnt/tmp" && umount "$mnt/tmp" || true
  mountpoint -q "$mnt" && umount "$mnt" || true
  [[ -n "$loopdev" ]] && losetup -d "$loopdev" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

loopdev=$(attach_loop "$raw_img" ro yes)
create_partition_nodes "$loopdev" 3
base=$(basename "$loopdev")
mount -o ro "/dev/${base}p3" "$mnt"

kernel=$(find "$mnt/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sort -V | tail -1)
[[ -n "$kernel" ]] || { echo 'no appliance kernel found' >&2; exit 1; }
version=${kernel#vmlinuz-}
[[ -d "$mnt/lib/modules/$version" ]] || { echo "no modules for kernel $version" >&2; exit 1; }
cp "$mnt/boot/$kernel" "$workdir/vmlinuz"

mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$mnt/tmp"
mount --rbind /dev "$mnt/dev"
mount --make-rslave "$mnt/dev"
mount -t proc proc "$mnt/proc"
mount --rbind /sys "$mnt/sys"
mount --make-rslave "$mnt/sys"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$mnt/run"

conf="$mnt/tmp/installer-initramfs-tools"
mkdir -p "$conf"
cp -a "$mnt/etc/initramfs-tools/." "$conf/"
mkdir -p "$conf/scripts/init-premount"
cat > "$conf/scripts/init-premount/appliance-installer" <<'INSTALLER'
#!/bin/sh
set -eu

PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

BB=/bin/busybox
[ -x "$BB" ] || exit 1

case " $($BB cat /proc/cmdline) " in
  *' appliance.installer=1 '*) ;;
  *) exit 0 ;;
esac

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

cmd_target=""
autoinstall=0
for word in $($BB cat /proc/cmdline); do
  case "$word" in
    appliance.target=*) cmd_target=${word#appliance.target=} ;;
    appliance.autoinstall=1) autoinstall=1 ;;
  esac
done

# also to kmsg, for whoever is on the other console
kmsg() {
  [ -w /dev/kmsg ] || return 0
  echo "<4>frr-installer: $*" > /dev/kmsg 2>/dev/null || true
}
notify() {
  echo "$*" || true
  kmsg "$*"
}
halt_forever() {
  notify "$*"
  while : ; do $BB sleep 3600; done
}

i=0
while [ "$i" -lt 50 ]; do
  [ -c /dev/console ] && break
  $BB sleep 1
  i=$((i + 1))
done
[ -c /dev/console ] || halt_forever 'no /dev/console'
exec </dev/console >/dev/console 2>&1

# no root= here, so returning to init panics, and the shell can EOF
fail_shell() {
  notify "error: $*"
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    echo "Rescue shell, attempt $attempt of 3. Exiting restarts it."
    if command -v setsid >/dev/null 2>&1; then
      setsid sh -i </dev/console >/dev/console 2>&1 || true
    else
      sh -i </dev/console >/dev/console 2>&1 || true
    fi
  done
  halt_forever 'no usable console input, halting'
}
trap 'fail_shell "installer exited unexpectedly"' EXIT

echo
echo "FRR appliance installer"
echo
echo "This writes the appliance image and DESTROYS the selected disk."
echo
kmsg 'installer started'

modprobe isofs 2>/dev/null || true
modprobe sr_mod 2>/dev/null || true
modprobe virtio_blk 2>/dev/null || true
modprobe nvme 2>/dev/null || true
udevadm settle 2>/dev/null || true

$BB mkdir -p /cdrom
media=""
i=0
while [ "$i" -lt 60 ]; do
  for d in /dev/sr0 /dev/sr1 /dev/cdrom /dev/sd[a-z] /dev/sd[a-z][0-9]* /dev/nvme*n*p* /dev/mmcblk*p*; do
    [ -b "$d" ] || continue
    if $BB mount -t iso9660 -o ro "$d" /cdrom 2>/dev/null; then
      if [ -f /cdrom/appliance/appliance.img.gz ] && [ -f /cdrom/appliance/SHA256SUMS ]; then
        media=$d
        break 2
      fi
      $BB umount /cdrom 2>/dev/null || true
    fi
  done
  $BB sleep 1
  i=$((i + 1))
done
[ -n "$media" ] || fail_shell 'installer media not found'

cd /cdrom/appliance
$BB sha256sum -c SHA256SUMS || fail_shell 'image checksum verification failed'

installer_disk=""
case "$media" in
  /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*) installer_disk=${media%p[0-9]*} ;;
  /dev/sd[a-z][0-9]*) installer_disk=$(printf '%s' "$media" | $BB sed 's/[0-9][0-9]*$//') ;;
  /dev/sd[a-z]|/dev/nvme*n[0-9]|/dev/mmcblk[0-9]*) installer_disk=$media ;;
esac

disks=""
for sysdev in /sys/block/vd* /sys/block/sd* /sys/block/nvme*n* /sys/block/mmcblk*; do
  [ -e "$sysdev" ] || continue
  dev=${sysdev##*/}
  d="/dev/$dev"
  [ -b "$d" ] || continue
  if [ -n "$installer_disk" ] && [ "$d" = "$installer_disk" ]; then continue; fi
  disks="$disks $d"
done
set -- $disks
[ "$#" -gt 0 ] || fail_shell 'no installable disks found'

target=$cmd_target
if [ -z "$target" ] && [ "$#" -eq 1 ]; then
  target=$1
fi
while [ -z "$target" ]; do
  echo "Available disks:"
  i=1
  for d in "$@"; do
    echo "  $i) $d"
    i=$((i + 1))
  done
  printf 'Select target number: '
  IFS= read -r choice || fail_shell 'console input unavailable'
  i=1
  for d in "$@"; do
    if [ "$i" = "$choice" ]; then target=$d; fi
    i=$((i + 1))
  done
  [ -n "$target" ] || echo "Not one of the listed numbers: $choice"
done

valid=0
for d in "$@"; do
  if [ "$target" = "$d" ]; then valid=1; fi
done
[ "$valid" -eq 1 ] && [ -b "$target" ] || fail_shell "invalid target: $target"

notify "Target: $target"
notify 'FRR_APPLIANCE_INSTALLER=READY'

if [ "$autoinstall" -ne 1 ]; then
  printf 'Type ERASE to continue: '
  IFS= read -r confirm || fail_shell 'console input unavailable'
  [ "$confirm" = ERASE ] || fail_shell 'cancelled'
fi

notify "Writing image to $target"
$BB gzip -dc appliance.img.gz | $BB dd of="$target" bs=4M
$BB sync
notify 'Done, rebooting'
trap - EXIT
$BB reboot -f
halt_forever 'reboot failed, power-cycle the machine'
INSTALLER
chmod 0755 "$conf/scripts/init-premount/appliance-installer"

# more than the appliance itself boots from
cat >> "$conf/modules" <<'MODULES'
sr_mod
isofs
ahci
virtio_pci
virtio_blk
nvme
MODULES

mkdir -p "$mnt/tmp/installer-tmp"
chroot "$mnt" /usr/bin/env \
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" \
  TMPDIR=/tmp/installer-tmp \
  mkinitramfs \
    -d /tmp/installer-initramfs-tools \
    -o /tmp/installer-initrd \
    "$version"

listing="$workdir/installer-initrd.list"
chroot "$mnt" lsinitramfs /tmp/installer-initrd > "$listing"
grep -Eq '(^|/)scripts/init-premount/ORDER$' "$listing" || {
  echo 'installer initramfs is missing init-premount/ORDER' >&2
  exit 1
}
grep -Eq '(^|/)scripts/init-premount/appliance-installer$' "$listing" || {
  echo 'installer initramfs is missing appliance-installer' >&2
  exit 1
}
cp "$mnt/tmp/installer-initrd" "$workdir/installer-initrd.gz"

umount "$mnt/run"
umount -R "$mnt/sys"
umount "$mnt/proc"
umount -R "$mnt/dev"
umount "$mnt/tmp"
umount "$mnt"
losetup -d "$loopdev"
loopdev=""

# keep Debian's hybrid boot layout, replace only the menus
xorriso -osirrox on -indev "$base_iso" \
  -extract /isolinux/txt.cfg "$workdir/txt.cfg.orig" \
  -extract /boot/grub/grub.cfg "$workdir/grub.cfg.orig" >/dev/null 2>&1

# last console= takes input. VGA default, serial still sees this menu
cat > "$workdir/txt.cfg" <<'TXT'
default appliance-vga
label appliance-vga
  menu label ^Install FRR Appliance (VGA console, ERASE DISK)
  kernel /appliance/vmlinuz
  append initrd=/appliance/installer-initrd.gz appliance.installer=1 console=ttyS0,115200n8 console=tty0
label appliance-serial
  menu label Install FRR Appliance (^Serial console 115200 8N1, ERASE DISK)
  kernel /appliance/vmlinuz
  append initrd=/appliance/installer-initrd.gz appliance.installer=1 console=tty0 console=ttyS0,115200n8
TXT
cat "$workdir/txt.cfg.orig" >> "$workdir/txt.cfg"

# text prompt works over serial, no menu.c32 needed
cat > "$workdir/isolinux.cfg" <<'ISOLINUX'
serial 0 115200
say
say FRR appliance installer. Every option ERASES the selected disk.
say   [Enter]          install, interactive on the VGA console
say   appliance-serial install, interactive on serial (115200 8N1)
say   install          Debian installer
say
default appliance-vga
prompt 1
timeout 100
include txt.cfg
ISOLINUX

cat > "$workdir/grub.cfg" <<'GRUB'
if serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1; then
    terminal_input --append serial
    terminal_output --append serial
fi
set default=0
set timeout=10
menuentry 'Install FRR Appliance (VGA console, ERASE DISK)' {
    linux /appliance/vmlinuz appliance.installer=1 console=ttyS0,115200n8 console=tty0
    initrd /appliance/installer-initrd.gz
}
menuentry 'Install FRR Appliance (serial console 115200 8N1, ERASE DISK)' {
    linux /appliance/vmlinuz appliance.installer=1 console=tty0 console=ttyS0,115200n8
    initrd /appliance/installer-initrd.gz
}
GRUB
cat "$workdir/grub.cfg.orig" >> "$workdir/grub.cfg"

volid="FRR_${variant^^}_AMD64"

xorriso \
  -abort_on FAILURE \
  -report_about WARNING \
  -indev "$base_iso" \
  -outdev "$out_iso" \
  -overwrite nondir \
  -mkdir /appliance -- \
  -volid "$volid" \
  -map "$workdir/appliance.img.gz" /appliance/appliance.img.gz \
  -map "$workdir/SHA256SUMS" /appliance/SHA256SUMS \
  -map "$workdir/vmlinuz" /appliance/vmlinuz \
  -map "$workdir/installer-initrd.gz" /appliance/installer-initrd.gz \
  -map "$workdir/txt.cfg" /isolinux/txt.cfg \
  -map "$workdir/isolinux.cfg" /isolinux/isolinux.cfg \
  -map "$workdir/grub.cfg" /boot/grub/grub.cfg \
  -boot_image any replay
