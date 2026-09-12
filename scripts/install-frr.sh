#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}

install -d -m 0755 /usr/share/keyrings
keyring=/usr/share/keyrings/frrouting.gpg

curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://deb.frrouting.org/frr/keys.gpg -o "$keyring"
chmod 0644 "$keyring"

# Keep read-only key inspection isolated from the image's persistent GnuPG state.
gpg_home=$(mktemp -d)
chmod 0700 "$gpg_home"
trap 'rm -rf "$gpg_home"' EXIT

# FRRouting publishes a bundle containing current and historical keys. Verify
# that every reviewed current signer is present, then restrict APT to those
# exact fingerprints via Signed-By. No key import or gpg-agent is required.
allowed=(
  4A56C7738BB3F81595A805D2A832769908F13ED1
  3D9968AC9AE7BE1169288DDB1FD5839895F57FDA
  BBC9ACA9D13025A2C186FF7F741E92A1F6E3975B
)

mapfile -t fetched < <(gpg --homedir "$gpg_home" --batch --no-options --with-colons --show-keys "$keyring" | awk -F: '
  $1=="pub" {want=1; next}
  $1=="fpr" && want {print toupper($10); want=0}
')
[[ ${#fetched[@]} -gt 0 ]] || { echo 'FRR keyring contains no primary-key fingerprints' >&2; exit 1; }

for want in "${allowed[@]}"; do
  found=0
  for got in "${fetched[@]}"; do
    [[ "$got" == "$want" ]] && found=1
  done
  [[ $found -eq 1 ]] || { echo "Required FRR signing key missing: $want" >&2; exit 1; }
done

cat > /etc/apt/sources.list.d/frr.sources <<APT
Types: deb
URIs: https://deb.frrouting.org/frr
Suites: $suite
Components: frr-stable
Signed-By: /usr/share/keyrings/frrouting.gpg ${allowed[*]}
APT

apt-get update
apt-get install -y --no-install-recommends \
  frr frr-pythontools frr-rpki-rtrlib frr-snmp
