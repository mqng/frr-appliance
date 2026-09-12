#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
base_iso=${2:?}
raw_img=${3:?}
out_iso=${4:?}

workdir="$PWD/work/${variant}/installer-iso"
rm -rf "$workdir"
mkdir -p "$workdir"

name=$(basename "$raw_img")
gzip -1 -c "$raw_img" > "$workdir/appliance.img.gz"
sha256sum "$workdir/appliance.img.gz" | sed 's#  .*/#  #' > "$workdir/SHA256SUMS"

cat > "$workdir/preseed-install.cfg" <<'PRESEED'
d-i preseed/early_command string sh /cdrom/appliance/install.sh
PRESEED

cat > "$workdir/install.sh" <<'INSTALL'
#!/bin/sh
set -eu

IMAGE=/cdrom/appliance/appliance.img.gz
SUMS=/cdrom/appliance/SHA256SUMS

echo
echo "FRR Appliance installer"
echo "======================="
echo "This writes the complete appliance image and DESTROYS the selected disk."
echo

cd /cdrom/appliance
sha256sum -c "$SUMS"

cmd_target=""
autoinstall=0
for word in $(cat /proc/cmdline); do
  case "$word" in
    appliance.target=*) cmd_target=${word#appliance.target=} ;;
    appliance.autoinstall=1) autoinstall=1 ;;
  esac
done

if command -v list-devices >/dev/null 2>&1; then
  disks=$(list-devices disk || true)
else
  disks=$(ls /dev/sd? /dev/vd? /dev/nvme?n1 2>/dev/null || true)
fi

[ -n "$disks" ] || { echo "No installable disks found"; exec sh; }

target=$cmd_target
if [ -z "$target" ]; then
  count=$(printf '%s\n' $disks | wc -l)
  if [ "$count" -eq 1 ]; then
    target=$(printf '%s\n' $disks | head -1)
  else
    echo "Available disks:"
    i=1
    for d in $disks; do echo "  $i) $d"; i=$((i+1)); done
    printf "Select target number: "
    read choice
    i=1
    for d in $disks; do
      if [ "$i" = "$choice" ]; then target=$d; break; fi
      i=$((i+1))
    done
  fi
fi

[ -b "$target" ] || { echo "Invalid target: $target"; exec sh; }

echo "Target: $target"
if [ "$autoinstall" -ne 1 ]; then
  printf "Type ERASE to continue: "
  read confirm
  [ "$confirm" = ERASE ] || { echo "Cancelled"; exec sh; }
fi

swapoff -a 2>/dev/null || true
sync
gzip -dc "$IMAGE" | dd of="$target" bs=16M conv=fsync
sync

echo "Install complete. Rebooting."
reboot -f
INSTALL
chmod 0755 "$workdir/install.sh"

xorriso -osirrox on -indev "$base_iso" \
  -extract /isolinux/txt.cfg "$workdir/txt.cfg.orig" \
  -extract /boot/grub/grub.cfg "$workdir/grub.cfg.orig" >/dev/null 2>&1

cat > "$workdir/txt.cfg" <<'TXT'
default appliance
label appliance
  menu label ^Install FRR Appliance (ERASE DISK)
  kernel /install.amd/vmlinuz
  append auto=true priority=critical file=/cdrom/appliance/preseed-install.cfg initrd=/install.amd/initrd.gz console=tty0 console=ttyS0,115200n8 --- quiet
TXT
cat "$workdir/txt.cfg.orig" >> "$workdir/txt.cfg"

cat > "$workdir/isolinux.cfg" <<'ISOLINUX'
default appliance
prompt 0
timeout 50
include txt.cfg
ISOLINUX

cat > "$workdir/grub.cfg" <<'GRUB'
set default=0
set timeout=5
menuentry 'Install FRR Appliance (ERASE DISK)' {
    linux /install.amd/vmlinuz auto=true priority=critical file=/cdrom/appliance/preseed-install.cfg console=tty0 console=ttyS0,115200n8 --- quiet
    initrd /install.amd/initrd.gz
}
GRUB
cat "$workdir/grub.cfg.orig" >> "$workdir/grub.cfg"

xorriso \
  -abort_on FAILURE \
  -report_about WARNING \
  -overwrite nondir \
  -indev "$base_iso" \
  -outdev "$out_iso" \
  -mkdir /appliance \
  -map "$workdir/appliance.img.gz" /appliance/appliance.img.gz \
  -map "$workdir/SHA256SUMS" /appliance/SHA256SUMS \
  -map "$workdir/install.sh" /appliance/install.sh \
  -map "$workdir/preseed-install.cfg" /appliance/preseed-install.cfg \
  -map "$workdir/txt.cfg" /isolinux/txt.cfg \
  -map "$workdir/isolinux.cfg" /isolinux/isolinux.cfg \
  -map "$workdir/grub.cfg" /boot/grub/grub.cfg \
  -boot_image any replay
