#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
iso="$PWD/out/$name-installer.iso"
workdir="$PWD/work/$variant/smoke"
mkdir -p "$workdir"

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
    [[ -s "$result" ]] && { echo '--- result ---' >&2; cat "$result" >&2; }
    return 1
  fi
}

qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/bios-overlay.qcow2"
bios=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 2048 -smp 2
  -drive "file=$workdir/bios-overlay.qcow2,format=qcow2,if=virtio"
  -netdev "user,id=n0"
  -device "virtio-net-pci,netdev=n0"
  -display none -serial stdio -monitor none -no-reboot
)
boot_wait bios "${bios[@]}"
boot_wait bios-reboot "${bios[@]}"

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
  -netdev "user,id=n0"
  -device "virtio-net-pci,netdev=n0"
  -display none -serial stdio -monitor none -no-reboot
)
boot_wait uefi-secureboot "${uefi[@]}"

run_until() {
  local label=$1 marker=$2 limit=$3
  shift 3
  local log="$workdir/$label.log" pid ok=0
  : > "$log"

  qemu-system-x86_64 "$@" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 "$limit"); do
    grep -q "$marker" "$log" && { ok=1; break; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [[ $ok -eq 1 ]] || {
    echo "$label did not reach: $marker" >&2
    tail -120 "$log" >&2 || true
    return 1
  }
}

qemu-img create -q -f qcow2 "$workdir/blank.qcow2" 5G
installer=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 1536 -smp 1
  -drive "file=$workdir/blank.qcow2,format=qcow2,if=virtio"
  -cdrom "$iso" -boot d
  -display none -serial stdio -monitor none -no-reboot
)
run_until installer-prompt 'FRR_APPLIANCE_INSTALLER=READY' 180 "${installer[@]}"

kernel="$PWD/work/$variant/installer-iso/vmlinuz"
initrd="$PWD/work/$variant/installer-iso/installer-initrd.gz"
[[ -r "$kernel" && -r "$initrd" ]] || { echo 'installer kernel or initrd missing' >&2; exit 1; }
qemu-img create -q -f qcow2 "$workdir/target.qcow2" 6G
write_log="$workdir/installer-write.log"
timeout 1800 qemu-system-x86_64 \
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 1536 -smp 2 \
  -kernel "$kernel" -initrd "$initrd" \
  -append 'appliance.installer=1 appliance.autoinstall=1 appliance.target=/dev/vda console=ttyS0,115200n8' \
  -drive "file=$workdir/target.qcow2,format=qcow2,if=virtio" \
  -cdrom "$iso" \
  -display none -serial stdio -monitor none -no-reboot \
  >"$write_log" 2>&1 || true
grep -q 'Done, rebooting' "$write_log" || {
  echo 'unattended install did not finish' >&2
  tail -120 "$write_log" >&2 || true
  exit 1
}

installed=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}" -cpu Nehalem -m 2048 -smp 2
  -drive "file=$workdir/target.qcow2,format=qcow2,if=virtio"
  -netdev "user,id=n0"
  -device "virtio-net-pci,netdev=n0"
  -display none -serial stdio -monitor none -no-reboot
)
boot_wait installed "${installed[@]}"
