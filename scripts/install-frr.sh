#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}

key=/usr/share/keyrings/frrouting.gpg
key_sha256=bf10935b9296e2ce7c5d9855fa29ef30c35810b0fc4b1f53005494a04a33554d

install -d -m 0755 /usr/share/keyrings
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://deb.frrouting.org/frr/keys.gpg \
  -o "$key"
chmod 0644 "$key"

got=$(sha256sum "$key" | awk '{print $1}')
[[ "$got" == "$key_sha256" ]] || {
  echo "FRR signing keyring changed, now $got" >&2
  echo 'Check the new key, then set key_sha256 in scripts/install-frr.sh' >&2
  exit 1
}

channel=frr-10.4

cat > /etc/apt/sources.list.d/frr.sources <<APT
Types: deb
URIs: https://deb.frrouting.org/frr
Suites: $suite
Components: $channel
Signed-By: /usr/share/keyrings/frrouting.gpg
APT

apt-get update
apt-get install -y --no-install-recommends \
  frr frr-pythontools frr-rpki-rtrlib frr-snmp
