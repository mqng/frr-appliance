#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: pipeline.sh <vanilla|vpp>}
case "$variant" in vanilla|vpp) ;; *) echo "invalid variant: $variant" >&2; exit 2;; esac

rm -rf out work
mkdir -p out work

./ci/static-check.sh
./ci/resolve-base.sh "$variant"
./ci/build.sh "$variant"
./ci/smoke-test.sh "$variant"
./ci/finalize-artifacts.sh "$variant"
./ci/sign-artifacts.sh "$variant"
./ci/publish.sh "$variant"
