#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
source work/base.env
name="frr-appliance-${variant}-${APPLIANCE_ARCH}"
img="$PWD/out/$name.img"
case "$APPLIANCE_ARCH" in
  amd64) efi_fallback=BOOTX64.EFI ;;
  arm64) efi_fallback=BOOTAA64.EFI ;;
  *) echo "unsupported architecture: $APPLIANCE_ARCH" >&2; exit 2 ;;
esac

# shellcheck source=ci/lib/loop-image.sh
source ci/lib/loop-image.sh
mnt=$(mktemp -d)
loopdev=""
cleanup() {
  set +e
  if mountpoint -q "$mnt/proc"; then umount "$mnt/proc"; fi
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
mount -t proc proc "$mnt/proc"

test -s "$mnt/etc/appliance/build.env"
test -s "$mnt/etc/appliance/packages.txt"
test -s "$mnt/etc/frr/frr.conf"
test -s "$mnt/boot/grub/grub.cfg"
test -s "$mnt/boot/efi/EFI/BOOT/$efi_fallback"
test -s "$mnt/boot/efi/EFI/debian/grub.cfg"
root_uuid=$(blkid -s UUID -o value "/dev/${base}p3")
esp_uuid=$(blkid -s UUID -o value "/dev/${base}p2")
grep -q "^UUID=$root_uuid / ext4 " "$mnt/etc/fstab"
grep -q "^UUID=$esp_uuid /boot/efi vfat " "$mnt/etc/fstab"
grep -Eq "root=UUID=${root_uuid}([[:space:]]|$)" "$mnt/boot/grub/grub.cfg"
grep -Eq 'root=/dev/loop[0-9]+p?[0-9]*' "$mnt/boot/grub/grub.cfg" && exit 1
grep -q "console=${APPLIANCE_SERIAL},115200n8" "$mnt/boot/grub/grub.cfg"
chroot "$mnt" dpkg-query -W frr >/dev/null
chroot "$mnt" dpkg-query -W snmpd >/dev/null
test -s "$mnt/etc/audit/rules.d/10-appliance.rules"
grep -q '^disk_full_action' "$mnt/etc/audit/auditd.conf"
stray=$(find "$mnt/etc" -xdev -uid +999 -print -quit)
if [[ -n "$stray" ]]; then
  echo "shipped config is not owned by a system user: $stray" >&2
  exit 1
fi
grep -qx 'agentaddress udp:127.0.0.1:161' "$mnt/etc/snmp/snmpd.conf"
test -s "$mnt/etc/pmacct/pmacctd.conf"
[[ ! -e "$mnt/usr/local/sbin/appliance-info" ]]
grep -q 'audit=1' "$mnt/boot/grub/grub.cfg"
grep -q 'APT::Periodic::Unattended-Upgrade "0"' "$mnt/etc/apt/apt.conf.d/20auto-upgrades"
[[ ! -e "$mnt/etc/apt/apt.conf.d/21appliance-auto-upgrades" ]]

test -e "$mnt/etc/motd"
[[ ! -s "$mnt/etc/motd" ]]
grep -q 'FRR appliance' "$mnt/etc/issue"
! compgen -G "$mnt/etc/update-motd.d/*" >/dev/null

test -s "$mnt/etc/apt/preferences.d/50-frr"
holds=$(chroot "$mnt" dpkg --get-selections | awk '$2 == "hold" { print $1 }')
if grep -qx frr <<<"$holds"; then
  echo 'frr must not be held, it hides patch releases' >&2
  exit 1
fi

for unit in ssh nftables auditd frr appliance-selftest.service \
            appliance-update-check.timer tmp.mount "serial-getty@${APPLIANCE_SERIAL}.service"; do
  chroot "$mnt" systemctl is-enabled "$unit" >/dev/null
done
chroot "$mnt" systemctl is-enabled snmpd.service >/dev/null && exit 1
chroot "$mnt" systemctl is-enabled pmacctd.service >/dev/null && exit 1
chroot "$mnt" dpkg-query -W pmacct >/dev/null
if [[ "$variant" == vpp ]]; then
  chroot "$mnt" dpkg-query -W vpp >/dev/null
  test -s "$mnt/etc/appliance/vpp-dpdk.conf"
  grep -qx vpp <<<"$holds"
  test -e "$mnt/lib/systemd/system/vpp.service"
  test -s "$mnt/etc/systemd/system/vpp.service"
  test -e "$mnt/etc/systemd/system/vpp-dpdk-prepare.service"
  test -e "$mnt/etc/systemd/system/vpp-lcp.service"
  test -s "$mnt/etc/systemd/system/frr.service.d/30-vpp.conf"
  ! grep -q 'network.target' "$mnt/etc/systemd/system/vpp.service"
  [[ ! -e "$mnt/etc/systemd/system/vpp.service.d" ]]
  [[ ! -e "$mnt/lib/systemd/system/vpp.service.d" ]]
  for unit in vpp.service vpp-dpdk-prepare.service vpp-lcp.service; do
    chroot "$mnt" systemctl is-enabled "$unit" >/dev/null
    test -L "$mnt/etc/systemd/system/multi-user.target.wants/$unit"
  done
fi
