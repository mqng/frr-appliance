#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: pipeline.sh <vanilla|vpp>}
case "$variant" in vanilla|vpp) ;; *) echo "invalid variant: $variant" >&2; exit 2 ;; esac

rm -rf out work
mkdir -p out work

bash ci/static-check.sh
bash ci/resolve-base.sh "$variant"
bash ci/build.sh "$variant"
bash ci/verify-image.sh "$variant"
bash ci/smoke-test.sh "$variant"
bash ci/finalize-artifacts.sh "$variant"
bash ci/sign-artifacts.sh "$variant"
bash ci/publish.sh "$variant"
