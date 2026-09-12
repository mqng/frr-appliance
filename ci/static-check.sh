#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(grep -rlZ '^#!/usr/bin/env bash' ci scripts)

python3 - <<'PY'
from pathlib import Path
compile(Path('ci/make-sbom.py').read_text(), 'ci/make-sbom.py', 'exec')
PY

if grep -RInE --exclude='static-check.sh' '(trusted=yes|curl[^|]*\|[[:space:]]*(sh|bash)|wget[^|]*\|[[:space:]]*(sh|bash)|--no-check-certificate|GIT_SSL_NO_VERIFY)' ci scripts config; then
  echo 'Unsafe bootstrap pattern found' >&2
  exit 1
fi

grep -q -- '--mode=root' ci/build.sh || { echo 'mmdebstrap root mode missing' >&2; exit 1; }
! grep -q -- '--mode=fakechroot' ci/build.sh || { echo 'fakechroot must not be used' >&2; exit 1; }
grep -q -- '--format=tar' ci/build.sh || { echo 'mmdebstrap tar output missing' >&2; exit 1; }
grep -qE '(^| )cracklib-runtime( |$)' ci/build.sh || { echo 'cracklib-runtime missing: libpam-pwquality would reject every password' >&2; exit 1; }
grep -q 'update-cracklib' scripts/provision-rootfs.sh || { echo 'cracklib dictionary is not verified at build time' >&2; exit 1; }
! grep -q 'qemu-system-' ci/build.sh || { echo 'QEMU must not be part of OS construction' >&2; exit 1; }
! grep -RInE --exclude='static-check.sh' 'guestfish|virt-cat|libguestfs|supermin' ci scripts >/dev/null || { echo 'libguestfs/supermin must not be in the build path' >&2; exit 1; }
grep -q 'attach_loop' ci/assemble-image.sh || { echo 'Loop-backed image assembly missing' >&2; exit 1; }
grep -q 'grub-install --target=i386-pc' scripts/image-finalize || { echo 'BIOS GRUB install missing' >&2; exit 1; }
grep -q -- '--target=x86_64-efi' scripts/image-finalize || { echo 'UEFI GRUB install missing' >&2; exit 1; }
grep -q -- '--removable' scripts/image-finalize || { echo 'UEFI removable fallback install missing' >&2; exit 1; }
grep -q 'Signed-By: /usr/share/keyrings/frrouting.gpg' scripts/install-frr.sh || { echo 'FRR repository keyring missing' >&2; exit 1; }
grep -q 'Signed-By: /etc/apt/keyrings/fdio-release.asc' scripts/install-vpp.sh || { echo 'VPP repository keyring missing' >&2; exit 1; }
! grep -RInE --exclude='static-check.sh' 'A90FC36D|4A56C773|3D9968AC|BBC9ACA9|9CD45627' scripts ci >/dev/null || { echo 'Hard-coded upstream repository signer detected' >&2; exit 1; }
# frr.service is Before=network.target upstream, so any unit that FRR must wait
# for has to stay off the far side of network.target or systemd breaks the
# resulting ordering cycle by dropping the frr.service job.
grep -qx 'After=' config/vpp/etc/systemd/system/vpp.service.d/20-appliance.conf || {
  echo 'vpp.service must reset After= or it orders itself behind network.target and deadlocks frr.service' >&2
  exit 1
}
# lsblk's PARTN column only exists from util-linux 2.40, which bookworm predates.
! grep -RInE --exclude='static-check.sh' '^[^#]*lsblk[^|]*PARTN' ci scripts >/dev/null || {
  echo 'lsblk PARTN is unavailable on bookworm; read the partition number from sysfs' >&2
  exit 1
}
# A router must keep forwarding transit traffic by default, but its own control
# plane is an allowlist. Losing either property silently would be bad.
grep -q 'hook input priority filter; policy drop' config/common/etc/nftables.conf || {
  echo 'Appliance control plane must be default-deny' >&2
  exit 1
}
grep -q 'hook forward priority filter; policy accept' config/common/etc/nftables.conf || {
  echo 'A router must forward by default; transit filtering is operator policy' >&2
  exit 1
}
grep -q 'nft --check --file /etc/nftables.conf' scripts/provision-rootfs.sh || {
  echo 'Firewall policy is not validated at build time' >&2
  exit 1
}
grep -q 'APPLIANCE_BOOT=READY' scripts/appliance-selftest || { echo 'Boot signal missing' >&2; exit 1; }
grep -q 'APPLIANCE_SELFTEST=PASS' scripts/appliance-selftest || { echo 'Self-test signal missing' >&2; exit 1; }
grep -q 'org.frr.appliance.selftest' ci/smoke-test.sh || { echo 'Dedicated smoke-test channel missing' >&2; exit 1; }
grep -q 'OVMF_CODE_4M.ms.fd' ci/smoke-test.sh || { echo 'Secure-Boot OVMF smoke test missing' >&2; exit 1; }

[[ ! -e ci/preseed.cfg ]] || { echo 'Legacy Debian Installer preseed still present' >&2; exit 1; }
[[ ! -e scripts/provision.sh ]] || { echo 'Legacy installer provisioning script still present' >&2; exit 1; }

grep -q "printf 'router\\\\n' > /etc/hostname" scripts/provision-rootfs.sh || { echo 'Default appliance hostname is not pinned' >&2; exit 1; }
! grep -q 'hostnamectl' scripts/appliance-firstboot || { echo 'First boot must not depend on systemd-hostnamed' >&2; exit 1; }
grep -q 'exec </dev/console >/dev/console 2>&1' ci/build-installer-iso.sh || { echo 'Installer must use /dev/console' >&2; exit 1; }
! grep -q 'appliance.console=' ci/build-installer-iso.sh || { echo 'Installer has duplicate console routing' >&2; exit 1; }

# An installer boot carries no root=, so if the initramfs hook ever returns to
# init the kernel panics. The hook must trap its own exit and it must never let
# the rescue shell be the last process standing.
grep -q "trap 'fail_shell" ci/build-installer-iso.sh || { echo 'Installer is missing its exit trap' >&2; exit 1; }
grep -q 'halt_forever' ci/build-installer-iso.sh || { echo 'Installer has no terminal halt path' >&2; exit 1; }
! grep -q "exec setsid sh -c" ci/build-installer-iso.sh || { echo 'Installer must not exec its rescue shell over the hook' >&2; exit 1; }
grep -qx 'default appliance-vga' ci/build-installer-iso.sh || { echo 'Installer default entry must be interactive on VGA' >&2; exit 1; }

# Every installer entry must register both consoles so kernel output and the
# installer status lines stay visible whichever console the operator watches.
installer_entries=0
while IFS= read -r entry; do
  installer_entries=$((installer_entries + 1))
  case "$entry" in
    *console=tty0*console=ttyS0,115200n8*|*console=ttyS0,115200n8*console=tty0*) ;;
    *) echo "Installer boot entry does not register both consoles:$entry" >&2; exit 1 ;;
  esac
done < <(grep -E '^ +(append|linux) .*appliance\.installer=1' ci/build-installer-iso.sh)
[[ $installer_entries -eq 4 ]] || { echo "Expected 4 installer boot entries (isolinux + grub), found $installer_entries" >&2; exit 1; }
grep -q '^source work/base.env$' ci/finalize-artifacts.sh || { echo 'Provenance base metadata is not loaded' >&2; exit 1; }

echo STATIC_CHECKS=PASS
