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

echo STATIC_CHECKS=PASS
