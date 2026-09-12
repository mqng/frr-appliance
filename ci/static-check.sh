#!/usr/bin/env bash
set -euo pipefail

scripts=()
while IFS= read -r -d '' file; do
  bash -n "$file"
  scripts+=("$file")
done < <(grep -rlZ '^#!/usr/bin/env bash' ci scripts)

shellcheck --severity=warning --external-sources "${scripts[@]}"
nft --check --file config/common/etc/nftables.conf

python3 - <<'PY'
from pathlib import Path
compile(Path('ci/make-sbom.py').read_text(), 'ci/make-sbom.py', 'exec')
PY

if grep -RInE --exclude='static-check.sh' '(trusted=yes|curl[^|]*\|[[:space:]]*(sh|bash)|wget[^|]*\|[[:space:]]*(sh|bash)|--no-check-certificate|GIT_SSL_NO_VERIFY)' ci scripts config; then
  echo 'unsafe bootstrap pattern' >&2
  exit 1
fi

fail() { echo "$1" >&2; exit 1; }

# real chroot on loop devices, no emulation
grep -q -- '--mode=root' ci/build.sh || fail 'mmdebstrap root mode missing'
! grep -q -- '--mode=fakechroot' ci/build.sh || fail 'fakechroot must not be used'
grep -q -- '--format=tar' ci/build.sh || fail 'mmdebstrap tar output missing'
! grep -q 'qemu-system-' ci/build.sh || fail 'QEMU must not build the OS'
! grep -RInE --exclude='static-check.sh' 'guestfish|virt-cat|libguestfs|supermin' ci scripts >/dev/null || fail 'libguestfs must not be in the build path'
grep -q 'attach_loop' ci/assemble-image.sh || fail 'loop-backed assembly missing'

# boot paths
grep -q 'grub-install --target=i386-pc' scripts/image-finalize || fail 'BIOS GRUB install missing'
grep -q -- '--target=x86_64-efi' scripts/image-finalize || fail 'UEFI GRUB install missing'
grep -q -- '--removable' scripts/image-finalize || fail 'UEFI removable fallback missing'
grep -q 'OVMF_CODE_4M.ms.fd' ci/smoke-test.sh || fail 'Secure Boot test missing'

# signed package sources
grep -q 'Signed-By: /usr/share/keyrings/frrouting.gpg' scripts/install-frr.sh || fail 'FRR keyring missing'
grep -q 'Signed-By: /etc/apt/keyrings/fdio-release.asc' scripts/install-vpp.sh || fail 'VPP keyring missing'
grep -qE '^key_sha256=[0-9a-f]{64}$' scripts/install-frr.sh || fail 'FRR key is not pinned'
grep -qE '^key_sha256=[0-9a-f]{64}$' scripts/install-vpp.sh || fail 'VPP key is not pinned'
# frr-stable follows feature and major releases
grep -qE '^channel=frr-[0-9]+\.[0-9]+$' scripts/install-frr.sh || fail 'FRR must track a patch line'
# Debian ships frr too, so the line pin only holds if the repo outranks it
grep -q 'Pin: origin deb.frrouting.org' config/common/etc/apt/preferences.d/50-frr || fail 'FRR is not pinned to its own repo'
! grep -q 'apt-mark hold frr' scripts/provision-rootfs.sh || fail 'holding frr hides patch releases'
! grep -RInE --exclude='static-check.sh' 'A90FC36D|4A56C773|3D9968AC|BBC9ACA9|9CD45627' scripts ci >/dev/null || fail 'hard-coded repository signer'

# frr is Before=network.target, so nothing it waits on may be after
grep -qx 'After=' config/vpp/etc/systemd/system/vpp.service.d/20-appliance.conf || fail 'vpp.service must reset After='
# PARTN needs util-linux 2.40
! grep -RInE --exclude='static-check.sh' '^[^#]*lsblk[^|]*PARTN' ci scripts >/dev/null || fail 'lsblk PARTN is unavailable on bookworm'

# admin works without sudo
grep -q '/usr/local/sbin' config/common/etc/profile.d/99-appliance.sh || fail 'admin PATH lacks sbin'
grep -q 'systemd-journal' scripts/provision-rootfs.sh || fail 'admin cannot read the journal'
grep -qE '(^| )dbus( |$)' ci/build.sh || fail 'no system bus, systemctl fails for admin'
grep -q 'gid netadmin' scripts/vpp-dpdk-prepare || fail 'VPP CLI socket would need sudo'
grep -q '^kernel.printk' config/common/etc/sysctl.d/99-frr-appliance.conf || fail 'console loglevel not pinned'

# control plane closed, transit open
grep -q 'hook input priority filter; policy drop' config/common/etc/nftables.conf || fail 'control plane must be default-deny'
grep -q 'hook forward priority filter; policy accept' config/common/etc/nftables.conf || fail 'a router must forward by default'
grep -q 'nft --check --file /etc/nftables.conf' scripts/provision-rootfs.sh || fail 'firewall not validated at build time'

# deleting a drop-in needs a daemon-reload, so appliance-getty decides instead
! grep -q 'rm -f /etc/systemd/system/.*getty' scripts/appliance-firstboot || fail 'autologin must not be disabled by deleting a drop-in'
grep -q 'firstboot.done' scripts/appliance-getty || fail 'appliance-getty must gate autologin'
for unit in getty@tty1 serial-getty@ttyS0; do
  conf="config/common/etc/systemd/system/$unit.service.d/10-appliance-console.conf"
  grep -q '/usr/local/sbin/appliance-getty' "$conf" || fail "$conf must call appliance-getty"
done
grep -q 'appliance-getty' scripts/provision-rootfs.sh || fail 'appliance-getty not installed'
! grep -q 'hostnamectl' scripts/appliance-firstboot || fail 'first boot must not need systemd-hostnamed'

# self-test signalling
grep -q 'APPLIANCE_BOOT=READY' scripts/appliance-selftest || fail 'boot signal missing'
grep -q 'APPLIANCE_SELFTEST=PASS' scripts/appliance-selftest || fail 'self-test signal missing'
grep -q 'org.frr.appliance.selftest' ci/smoke-test.sh || fail 'self-test channel missing'
grep -q "printf 'router\\\\n' > /etc/hostname" scripts/provision-rootfs.sh || fail 'default hostname not pinned'
grep -q '^source work/base.env$' ci/finalize-artifacts.sh || fail 'base metadata not loaded'

# no root= on an installer boot, so it must never return
grep -q 'exec </dev/console >/dev/console 2>&1' ci/build-installer-iso.sh || fail 'installer must use /dev/console'
! grep -q 'appliance.console=' ci/build-installer-iso.sh || fail 'duplicate console routing'
grep -q "trap 'fail_shell" ci/build-installer-iso.sh || fail 'installer exit trap missing'
grep -q 'halt_forever' ci/build-installer-iso.sh || fail 'installer halt path missing'
! grep -q 'exec setsid sh -c' ci/build-installer-iso.sh || fail 'rescue shell must not exec over the hook'
grep -qx 'default appliance-vga' ci/build-installer-iso.sh || fail 'installer default must be VGA'

installer_entries=0
while IFS= read -r entry; do
  installer_entries=$((installer_entries + 1))
  case "$entry" in
    *console=tty0*console=ttyS0,115200n8*|*console=ttyS0,115200n8*console=tty0*) ;;
    *) fail "installer entry lacks both consoles:$entry" ;;
  esac
done < <(grep -E '^ +(append|linux) .*appliance\.installer=1' ci/build-installer-iso.sh)
[[ $installer_entries -eq 4 ]] || fail "expected 4 installer boot entries, found $installer_entries"

echo STATIC_CHECKS=PASS
