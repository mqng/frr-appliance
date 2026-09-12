#!/usr/bin/env bash
set -euo pipefail

suite=${1:?}

install -d -m 0755 /usr/share/keyrings

curl \
  --fail \
  --location \
  --retry 4 \
  --retry-all-errors \
  --proto '=https' \
  --tlsv1.2 \
  https://deb.frrouting.org/frr/keys.gpg \
  -o /usr/share/keyrings/frrouting.gpg

chmod 0644 /usr/share/keyrings/frrouting.gpg

cat >/etc/apt/sources.list.d/frr.sources <<EOF
Types: deb
URIs: https://deb.frrouting.org/frr
Suites: ${suite}
Components: frr-stable
Signed-By: /usr/share/keyrings/frrouting.gpg
EOF

apt-get update
apt-get install -y --no-install-recommends \
  frr \
  frr-pythontools
