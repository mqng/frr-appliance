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
! grep -q 'qemu-system-' ci/build.sh || { echo 'QEMU must not be part of OS construction' >&2; exit 1; }
! grep -RInE --exclude='static-check.sh' 'guestfish|virt-cat|libguestfs|supermin' ci scripts >/dev/null || { echo 'libguestfs/supermin must not be in the build path' >&2; exit 1; }
grep -q 'attach_loop' ci/assemble-image.sh || { echo 'Loop-backed image assembly missing' >&2; exit 1; }
grep -q 'grub-install --target=i386-pc' scripts/image-finalize || { echo 'BIOS GRUB install missing' >&2; exit 1; }
grep -q -- '--target=x86_64-efi' scripts/image-finalize || { echo 'UEFI GRUB install missing' >&2; exit 1; }
grep -q -- '--removable' scripts/image-finalize || { echo 'UEFI removable fallback install missing' >&2; exit 1; }
grep -q 'Signed-By: /usr/share/keyrings/frrouting.gpg' scripts/install-frr.sh || { echo 'FRR repository keyring missing' >&2; exit 1; }
grep -q 'Signed-By: /etc/apt/keyrings/fdio-release.asc' scripts/install-vpp.sh || { echo 'VPP repository keyring missing' >&2; exit 1; }
! grep -RInE --exclude='static-check.sh' 'A90FC36D|4A56C773|3D9968AC|BBC9ACA9|9CD45627' scripts ci >/dev/null || { echo 'Hard-coded upstream repository signer detected' >&2; exit 1; }
grep -q 'APPLIANCE_BOOT=READY' scripts/appliance-selftest || { echo 'Boot signal missing' >&2; exit 1; }
grep -q 'APPLIANCE_SELFTEST=PASS' scripts/appliance-selftest || { echo 'Self-test signal missing' >&2; exit 1; }
grep -q 'org.frr.appliance.selftest' ci/smoke-test.sh || { echo 'Dedicated smoke-test channel missing' >&2; exit 1; }
grep -q 'OVMF_CODE_4M.ms.fd' ci/smoke-test.sh || { echo 'Secure-Boot OVMF smoke test missing' >&2; exit 1; }

[[ ! -e ci/preseed.cfg ]] || { echo 'Legacy Debian Installer preseed still present' >&2; exit 1; }
[[ ! -e scripts/provision.sh ]] || { echo 'Legacy installer provisioning script still present' >&2; exit 1; }

echo STATIC_CHECKS=PASS
