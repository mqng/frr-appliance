#!/usr/bin/env bash
set -euo pipefail
variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
iso="$PWD/out/$name-installer.iso"
workdir="$PWD/work/$variant/smoke"
mkdir -p "$workdir"

boot_wait() {
  local label=$1; shift
  local log="$workdir/$label.log"
  : > "$log"
  qemu-system-x86_64 "$@" >"$log" 2>&1 &
  local pid=$!
  local ok=0
  for _ in $(seq 1 240); do
    if grep -q 'APPLIANCE_SELFTEST=PASS' "$log"; then ok=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [[ $ok -ne 1 ]]; then
    echo "$label boot self-test failed" >&2
    tail -200 "$log" >&2 || true
    return 1
  fi
}

qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/bios-overlay.qcow2"
common=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}"
  -m 2048 -smp 2
  -drive "file=$workdir/bios-overlay.qcow2,format=qcow2,if=virtio"
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
  -nographic -no-reboot
)
if [[ ${QEMU_ACCEL:-tcg} == tcg ]]; then common+=( -cpu max ); fi
boot_wait bios "${common[@]}"

code=""
vars=""
for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do [[ -r "$f" ]] && { code=$f; break; }; done
for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do [[ -r "$f" ]] && { vars=$f; break; }; done
if [[ -n "$code" && -n "$vars" ]]; then
  cp "$vars" "$workdir/OVMF_VARS.fd"
  qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/uefi-overlay.qcow2"
  uefi=(
    -machine "q35,accel=${QEMU_ACCEL:-tcg}"
    -m 2048 -smp 2
    -drive "if=pflash,format=raw,readonly=on,file=$code"
    -drive "if=pflash,format=raw,file=$workdir/OVMF_VARS.fd"
    -drive "file=$workdir/uefi-overlay.qcow2,format=qcow2,if=virtio"
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    -nographic -no-reboot
  )
  if [[ ${QEMU_ACCEL:-tcg} == tcg ]]; then uefi+=( -cpu max ); fi
  boot_wait uefi "${uefi[@]}"
else
  echo "OVMF not found; refusing to publish without UEFI smoke test" >&2
  exit 1
fi

iso_log="$workdir/installer-iso.log"
qemu-img create -f qcow2 "$workdir/blank.qcow2" 5G >/dev/null
iso_args=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -m 1536 -smp 1
  -drive "file=$workdir/blank.qcow2,format=qcow2,if=virtio"
  -cdrom "$iso" -boot d -nographic -no-reboot
)
if [[ ${QEMU_ACCEL:-tcg} == tcg ]]; then iso_args+=( -cpu max ); fi
qemu-system-x86_64 "${iso_args[@]}" >"$iso_log" 2>&1 &
pid=$!
ok=0
for _ in $(seq 1 180); do
  if grep -q 'FRR Appliance installer' "$iso_log"; then ok=1; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
[[ $ok -eq 1 ]] || { echo "Installer ISO smoke-test failed" >&2; tail -120 "$iso_log" >&2; exit 1; }
