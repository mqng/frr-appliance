#!/usr/bin/env bash
set -euo pipefail
suite=${1:?}

install -d -m 0755 /usr/share/keyrings
curl --fail --location --retry 4 --retry-all-errors --proto '=https' --tlsv1.2 \
  https://deb.frrouting.org/frr/keys.gpg -o /tmp/frrouting.gpg

allowed=(
  4A56C7738BB3F81595A805D2A832769908F13ED1
  3D9968AC9AE7BE1169288DDB1FD5839895F57FDA
  BBC9ACA9D13025A2C186FF7F741E92A1F6E3975B
)
mapfile -t fetched < <(gpg --batch --show-keys --with-colons /tmp/frrouting.gpg | awk -F: '
  $1=="pub" {want=1; next}
  $1=="fpr" && want {print toupper($10); want=0}
')
[[ ${#fetched[@]} -gt 0 ]] || { echo "FRR keyring contains no primary-key fingerprints" >&2; exit 1; }
for got in "${fetched[@]}"; do
  approved=0
  for want in "${allowed[@]}"; do
    [[ "$got" == "$want" ]] && approved=1
  done
  [[ $approved -eq 1 ]] || { echo "Unreviewed FRR primary signing key: $got" >&2; exit 1; }
done
install -m 0644 /tmp/frrouting.gpg /usr/share/keyrings/frrouting.gpg

cat > /etc/apt/sources.list.d/frr.list <<APT
deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr $suite frr-stable
APT
apt-get update
apt-get install -y --no-install-recommends frr frr-pythontools frr-rpki-rtrlib frr-snmp
