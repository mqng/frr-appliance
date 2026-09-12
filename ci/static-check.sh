#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r -d '' file; do
  bash -n "$file"
done < <(find ci scripts -type f -name '*.sh' -print0)

python3 - <<'PY'
from pathlib import Path
compile(Path('ci/make-sbom.py').read_text(), 'ci/make-sbom.py', 'exec')
PY

if grep -RInE --exclude='static-check.sh' '(trusted=yes|curl[^|]*\|[[:space:]]*(sh|bash)|wget[^|]*\|[[:space:]]*(sh|bash)|--no-check-certificate|GIT_SSL_NO_VERIFY)' ci scripts config; then
  echo 'Unsafe bootstrap pattern found' >&2
  exit 1
fi

grep -q 'media=cdrom,readonly=on' ci/build.sh || { echo 'Debian ISO is not attached to QEMU' >&2; exit 1; }
grep -q 'initrd-custom.gz' ci/build.sh || { echo 'Preseed is not embedded into installer initrd' >&2; exit 1; }
grep -q 'unexpected interactive Debian Installer prompt' ci/build.sh || { echo 'Installer prompt guard missing' >&2; exit 1; }
grep -q 'debian-installer/exit/poweroff boolean true' ci/preseed.cfg || { echo 'Installer completion is not unattended' >&2; exit 1; }
grep -q 'passwd/make-user boolean false' ci/preseed.cfg || { echo 'Installer account creation is not disabled' >&2; exit 1; }

# Boot smoke-test success must not depend on ttyS0 output. Debian 13 can boot
# while a serial-only harness appears stuck after GRUB's initramfs message.
grep -q 'org.frr.appliance.selftest' ci/smoke-test.sh || { echo 'Dedicated self-test channel missing' >&2; exit 1; }
grep -q 'org.frr.appliance.selftest' scripts/appliance-selftest || { echo 'Guest self-test result channel missing' >&2; exit 1; }
grep -q 'APPLIANCE_BOOT=READY' scripts/appliance-boot-beacon || { echo 'Early boot beacon missing' >&2; exit 1; }
grep -q 'generated GRUB config has no ttyS0 kernel console' scripts/provision.sh || { echo 'GRUB serial-console build assertion missing' >&2; exit 1; }

echo STATIC_CHECKS=PASS
