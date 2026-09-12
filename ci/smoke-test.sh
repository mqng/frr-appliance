#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
iso="$PWD/out/$name-installer.iso"
workdir="$PWD/work/$variant/smoke"
mkdir -p "$workdir"

# upper bound, not a wait. Longer than the selftest deadlines
boot_timeout=420
if [[ "$variant" == vpp ]]; then
  boot_timeout=540
fi

boot_wait() {
  local label=$1
  shift

  local log="$workdir/$label.log"
  local result="$workdir/$label.selftest"
  local pid ok=0
  : > "$log"
  : > "$result"

  qemu-system-x86_64 \
    "$@" \
    -device virtio-serial-pci \
    -chardev "file,id=appliance_selftest,path=$result" \
    -device virtserialport,chardev=appliance_selftest,name=org.frr.appliance.selftest \
    >"$log" 2>&1 &
  pid=$!

  for _ in $(seq 1 "$boot_timeout"); do
    if grep -q 'APPLIANCE_SELFTEST=PASS' "$result"; then
      ok=1
      break
    fi
    if grep -q 'APPLIANCE_SELFTEST=FAIL' "$result"; then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [[ $ok -ne 1 ]]; then
    echo "$label self-test failed" >&2
    echo '--- console ---' >&2
    tail -160 "$log" >&2 || true
    # last, so it ends the log
    [[ -s "$result" ]] && { echo '--- result ---' >&2; cat "$result" >&2; }
    return 1
  fi
}

qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/bios-overlay.qcow2"
bios=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 2048 -smp 2
  -drive "file=$workdir/bios-overlay.qcow2,format=qcow2,if=virtio"
  -netdev user,id=n0
  -device virtio-net-pci,netdev=n0
  -display none -serial stdio -monitor none -no-reboot
)
boot_wait bios "${bios[@]}"

# Microsoft-enrolled vars, so this is Secure Boot and not just UEFI
code=/usr/share/OVMF/OVMF_CODE_4M.ms.fd
vars=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
[[ -r "$code" && -r "$vars" ]] || { echo 'Secure Boot OVMF firmware not found' >&2; exit 1; }
cp "$vars" "$workdir/OVMF_VARS.fd"
qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/uefi-overlay.qcow2"
uefi=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 2048 -smp 2
  -drive "if=pflash,format=raw,readonly=on,file=$code"
  -drive "if=pflash,format=raw,file=$workdir/OVMF_VARS.fd"
  -drive "file=$workdir/uefi-overlay.qcow2,format=qcow2,if=virtio"
  -netdev user,id=n0
  -device virtio-net-pci,netdev=n0
  -display none -serial stdio -monitor none -no-reboot
)
boot_wait uefi-secureboot "${uefi[@]}"

# only needs to reach the prompt
iso_log="$workdir/installer-iso.log"
qemu-img create -q -f qcow2 "$workdir/blank.qcow2" 5G
qemu-system-x86_64 \
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 1536 -smp 1 \
  -drive "file=$workdir/blank.qcow2,format=qcow2,if=virtio" \
  -cdrom "$iso" -boot d -display none -serial stdio -monitor none -no-reboot \
  >"$iso_log" 2>&1 &
pid=$!
ok=0
for _ in $(seq 1 180); do
  grep -q 'FRR_APPLIANCE_INSTALLER=READY' "$iso_log" && { ok=1; break; }
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
[[ $ok -eq 1 ]] || { echo 'installer ISO did not reach the confirmation prompt' >&2; tail -120 "$iso_log" >&2; exit 1; }
