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

grep -q -- '--mode=fakechroot' ci/build.sh || { echo 'mmdebstrap must use unprivileged fakechroot mode' >&2; exit 1; }
grep -q -- '--format=tar' ci/build.sh || { echo 'mmdebstrap tar output missing' >&2; exit 1; }
! grep -q 'qemu-system-' ci/build.sh || { echo 'QEMU must not be part of OS construction' >&2; exit 1; }
grep -q 'guestfish' ci/assemble-image.sh || { echo 'Direct image assembly missing' >&2; exit 1; }
grep -q 'grub-install --target=i386-pc' scripts/image-finalize || { echo 'BIOS GRUB install missing' >&2; exit 1; }
grep -q -- '--target=x86_64-efi' scripts/image-finalize || { echo 'UEFI GRUB install missing' >&2; exit 1; }
grep -q -- '--removable' scripts/image-finalize || { echo 'UEFI removable fallback install missing' >&2; exit 1; }
grep -q 'APPLIANCE_BOOT=READY' scripts/appliance-selftest || { echo 'Boot signal missing' >&2; exit 1; }
grep -q 'APPLIANCE_SELFTEST=PASS' scripts/appliance-selftest || { echo 'Self-test signal missing' >&2; exit 1; }
grep -q 'org.frr.appliance.selftest' ci/smoke-test.sh || { echo 'Dedicated smoke-test channel missing' >&2; exit 1; }
grep -q 'OVMF_CODE_4M.ms.fd' ci/smoke-test.sh || { echo 'Secure-Boot OVMF smoke test missing' >&2; exit 1; }

[[ ! -e ci/preseed.cfg ]] || { echo 'Legacy Debian Installer preseed still present' >&2; exit 1; }
[[ ! -e scripts/provision.sh ]] || { echo 'Legacy installer provisioning script still present' >&2; exit 1; }

echo STATIC_CHECKS=PASS
