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

# Build a separate installer initramfs through initramfs-tools itself. Do not
# append cpio data to the appliance initramfs: initramfs-tools generates ORDER
# files for each boot-script stage, and bypassing mkinitramfs can leave those
# directories structurally invalid.
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
[[ -n "$kernel" ]] || { echo 'No appliance kernel found' >&2; exit 1; }
version=${kernel#vmlinuz-}
[[ -d "$mnt/lib/modules/$version" ]] || { echo "No modules for appliance kernel: $version" >&2; exit 1; }
cp "$mnt/boot/$kernel" "$workdir/vmlinuz"

# Keep the appliance filesystem read-only. Writable build state lives only on
# tmpfs and temporary virtual filesystems mounted into the chroot.
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

console=ttyS0
cmd_target=""
autoinstall=0
for word in $($BB cat /proc/cmdline); do
  case "$word" in
    appliance.console=*) console=${word#appliance.console=} ;;
    appliance.target=*) cmd_target=${word#appliance.target=} ;;
    appliance.autoinstall=1) autoinstall=1 ;;
  esac
done
case "$console" in tty1|ttyS0) ;; *) console=ttyS0 ;; esac
console_dev="/dev/$console"
i=0
while [ "$i" -lt 50 ]; do
  [ -c "$console_dev" ] && break
  $BB sleep 1
  i=$((i + 1))
done
exec <"$console_dev" >"$console_dev" 2>&1

fail_shell() {
  echo "ERROR: $*"
  echo "Dropping to an installer shell."
  exec sh
}

echo
echo "FRR Appliance installer"
echo "======================="
echo "This writes the complete appliance image and DESTROYS the selected disk."
echo

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
[ -n "$media" ] || fail_shell 'Installer media not found'

cd /cdrom/appliance
$BB sha256sum -c SHA256SUMS || fail_shell 'Appliance image checksum verification failed'

# If the ISO was written to USB, never offer that same disk as an erase target.
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
  [ -n "$installer_disk" ] && [ "$d" = "$installer_disk" ] && continue
  disks="$disks $d"
done
set -- $disks
[ "$#" -gt 0 ] || fail_shell 'No installable disks found'

target=$cmd_target
if [ -z "$target" ]; then
  if [ "$#" -eq 1 ]; then
    target=$1
  else
    echo "Available disks:"
    i=1
    for d in "$@"; do
      echo "  $i) $d"
      i=$((i + 1))
    done
    printf 'Select target number: '
    read choice
    i=1
    for d in "$@"; do
      if [ "$i" = "$choice" ]; then target=$d; break; fi
      i=$((i + 1))
    done
  fi
fi

valid=0
for d in "$@"; do
  [ "$target" = "$d" ] && valid=1
done
[ "$valid" -eq 1 ] && [ -b "$target" ] || fail_shell "Invalid or unsafe target: $target"

echo "Target: $target"
echo "FRR_APPLIANCE_INSTALLER=READY"

if [ "$autoinstall" -ne 1 ]; then
  printf 'Type ERASE to continue: '
  read confirm
  [ "$confirm" = ERASE ] || fail_shell 'Installation cancelled'
fi

echo "Writing appliance image to $target ..."
$BB gzip -dc appliance.img.gz | $BB dd of="$target" bs=4M
$BB sync
echo 'Install complete. Rebooting.'
$BB reboot -f
INSTALLER
chmod 0755 "$conf/scripts/init-premount/appliance-installer"

# Ensure the installer can see both optical/USB media and common target disks
# regardless of which subset the normal appliance needs for its root filesystem.
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

# Validate the generated initramfs structure before publishing the ISO.
listing="$workdir/installer-initrd.list"
chroot "$mnt" lsinitramfs /tmp/installer-initrd > "$listing"
grep -Eq '(^|/)scripts/init-premount/ORDER$' "$listing" || {
  echo 'Generated installer initramfs is missing init-premount/ORDER' >&2
  exit 1
}
grep -Eq '(^|/)scripts/init-premount/appliance-installer$' "$listing" || {
  echo 'Generated installer initramfs is missing appliance-installer' >&2
  exit 1
}
cp "$mnt/tmp/installer-initrd" "$workdir/installer-initrd.gz"

# Release all chroot mounts before xorriso starts reading the finished payload.
umount "$mnt/run"
umount -R "$mnt/sys"
umount "$mnt/proc"
umount -R "$mnt/dev"
umount "$mnt/tmp"
umount "$mnt"
losetup -d "$loopdev"
loopdev=""

# Preserve Debian's proven hybrid BIOS/UEFI boot layout, replacing only the menus
# and adding our kernel, initramfs, and appliance payload.
xorriso -osirrox on -indev "$base_iso" \
  -extract /isolinux/txt.cfg "$workdir/txt.cfg.orig" \
  -extract /boot/grub/grub.cfg "$workdir/grub.cfg.orig" >/dev/null 2>&1

cat > "$workdir/txt.cfg" <<'TXT'
default appliance-serial
label appliance-serial
  menu label ^Install FRR Appliance (Serial, ERASE DISK)
  kernel /appliance/vmlinuz
  append initrd=/appliance/installer-initrd.gz appliance.installer=1 appliance.console=ttyS0 console=tty0 console=ttyS0,115200n8
label appliance-vga
  menu label Install FRR Appliance (^VGA, ERASE DISK)
  kernel /appliance/vmlinuz
  append initrd=/appliance/installer-initrd.gz appliance.installer=1 appliance.console=tty1 console=tty0
TXT
cat "$workdir/txt.cfg.orig" >> "$workdir/txt.cfg"

cat > "$workdir/isolinux.cfg" <<'ISOLINUX'
default appliance-serial
prompt 0
timeout 50
include txt.cfg
ISOLINUX

cat > "$workdir/grub.cfg" <<'GRUB'
set default=0
set timeout=5
menuentry 'Install FRR Appliance (Serial, ERASE DISK)' {
    linux /appliance/vmlinuz appliance.installer=1 appliance.console=ttyS0 console=tty0 console=ttyS0,115200n8
    initrd /appliance/installer-initrd.gz
}
menuentry 'Install FRR Appliance (VGA, ERASE DISK)' {
    linux /appliance/vmlinuz appliance.installer=1 appliance.console=tty1 console=tty0
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
