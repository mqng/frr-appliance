#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}

install -d -m 0755 /usr/share/keyrings
upstream_keyring=$(mktemp)
keyring=/usr/share/keyrings/frrouting.gpg

gpg_home=$(mktemp -d)
chmod 0700 "$gpg_home"
trap 'rm -rf "$gpg_home" "$upstream_keyring"' EXIT

curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://deb.frrouting.org/frr/keys.gpg -o "$upstream_keyring"

# These are the current repository signing keys published by FRRouting.
allowed=(
  4A56C7738BB3F81595A805D2A832769908F13ED1
  3D9968AC9AE7BE1169288DDB1FD5839895F57FDA
  BBC9ACA9D13025A2C186FF7F741E92A1F6E3975B
)

mapfile -t fetched < <(gpg --homedir "$gpg_home" --batch --no-options \
  --no-default-keyring --keyring "$upstream_keyring" --with-colons --list-keys 2>/dev/null | \
  awk -F: '$1=="fpr" {print toupper($10)}')

for want in "${allowed[@]}"; do
  printf '%s\n' "${fetched[@]}" | grep -Fxq "$want" || {
    echo "Required FRR signing key missing: $want" >&2
    exit 1
  }
done

# Build a keyring containing only the reviewed current FRR keys. APT then
# follows the upstream-recommended model: Signed-By points to one keyring file.
gpg --homedir "$gpg_home" --batch --no-options \
  --no-default-keyring --keyring "$upstream_keyring" \
  --export-options export-minimal --export "${allowed[@]}" > "$keyring"
chmod 0644 "$keyring"
[[ -s "$keyring" ]] || { echo 'Filtered FRR keyring is empty' >&2; exit 1; }

cat > /etc/apt/sources.list.d/frr.sources <<APT
Types: deb
URIs: https://deb.frrouting.org/frr
Suites: $suite
Components: frr-stable
Signed-By: /usr/share/keyrings/frrouting.gpg
APT

apt-get update
apt-get install -y --no-install-recommends \
  frr frr-pythontools frr-rpki-rtrlib frr-snmp
