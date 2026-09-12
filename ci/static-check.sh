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

if grep -RInE --exclude='static-check.sh' -- '-cpu[[:space:]]+max' ci; then
  echo 'Do not use QEMU -cpu max in TCG CI; use the reviewed named model' >&2
  exit 1
fi

grep -q -- '-cpu Nehalem' ci/smoke-test.sh || { echo 'TCG smoke-test CPU model missing' >&2; exit 1; }

echo STATIC_CHECKS=PASS
