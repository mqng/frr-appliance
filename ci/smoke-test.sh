#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
source work/base.env
name="frr-appliance-${variant}-${APPLIANCE_ARCH}"
img="$PWD/out/$name.img"
iso="$PWD/out/$name-installer.iso"
workdir="$PWD/work/$variant/smoke"
mkdir -p "$workdir"

boot_timeout=420
mem=2048
if [[ "$variant" == vpp ]]; then
  boot_timeout=540
  mem=4096
fi

case "$APPLIANCE_ARCH" in
  amd64)
    qemu="qemu-system-x86_64"
    machine=q35
    cpu=Nehalem
    code=/usr/share/OVMF/OVMF_CODE_4M.ms.fd
    vars=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
    ;;
  arm64)
    qemu="qemu-system-aarch64"
    machine=virt
    cpu=max
    code=/usr/share/AAVMF/AAVMF_CODE.ms.fd
    vars=/usr/share/AAVMF/AAVMF_VARS.ms.fd
    ;;
  *) echo "unsupported architecture: $APPLIANCE_ARCH" >&2; exit 2 ;;
esac
[[ -r "$code" && -r "$vars" ]] || { echo "Secure Boot firmware not found: $code" >&2; exit 1; }

common=(
  -machine "${machine},accel=${QEMU_ACCEL:-tcg}" -cpu "$cpu"
  -display none -serial stdio -monitor none -no-reboot
)
net=(-netdev "user,id=n0" -device "virtio-net-pci,netdev=n0,romfile=")

firmware=()
set_firmware() {
  local copy="$workdir/$1-vars.fd"
  cp "$vars" "$copy"
  firmware=(
    -drive "if=pflash,format=raw,readonly=on,file=$code"
    -drive "if=pflash,format=raw,file=$copy"
  )
}

boot_wait() {
  local label=$1
  shift

  local log="$workdir/$label.log"
  local result="$workdir/$label.selftest"
  local pid ok=0 reason='' waited=0
  : > "$log"
  : > "$result"

  "$qemu" \
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
      reason='the self-test reported FAIL'
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      reason='qemu exited before the self-test finished'
      break
    fi
    waited=$((waited + 1))
    sleep 1
  done
  if [[ $ok -ne 1 && -z "$reason" ]]; then
    if grep -q 'APPLIANCE_BOOT=READY' "$result"; then
      reason="the self-test started but reached no verdict within ${boot_timeout}s"
    else
      reason="the appliance never reached the self-test within ${boot_timeout}s"
    fi
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [[ $ok -ne 1 ]]; then
    echo "variant=$variant phase=$label failed after ${waited}s: $reason" >&2
    echo "--- $variant $label console ---" >&2
    tail -160 "$log" >&2 || true
    echo "--- $variant $label result ---" >&2
    if [[ -s "$result" ]]; then
      cat "$result" >&2
    else
      echo 'nothing arrived on the self-test channel' >&2
    fi
    return 1
  fi
}

if [[ "$APPLIANCE_ARCH" == amd64 ]]; then
  qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/bios-overlay.qcow2"
  bios=(
    "${common[@]}" -m "$mem" -smp 2
    -drive "file=$workdir/bios-overlay.qcow2,format=qcow2,if=virtio"
    "${net[@]}"
  )
  boot_wait bios "${bios[@]}"
  boot_wait bios-reboot "${bios[@]}"
fi

set_firmware uefi
qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/uefi-overlay.qcow2"
uefi=(
  "${common[@]}" -m "$mem" -smp 2
  "${firmware[@]}"
  -drive "file=$workdir/uefi-overlay.qcow2,format=qcow2,if=virtio"
  "${net[@]}"
)
boot_wait uefi-secureboot "${uefi[@]}"
if [[ "$APPLIANCE_ARCH" != amd64 ]]; then
  boot_wait uefi-reboot "${uefi[@]}"
fi

run_until() {
  local label=$1 marker=$2 limit=$3
  shift 3
  local log="$workdir/$label.log" pid ok=0
  : > "$log"

  "$qemu" "$@" >"$log" 2>&1 &
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
firmware=()
case "$APPLIANCE_ARCH" in
  amd64)
    media=(-cdrom "$iso" -boot d)
    ;;
  arm64)
    media=(
      -drive "file=$iso,format=raw,if=none,id=cd0,media=cdrom"
      -device "virtio-scsi-pci,id=scsi0"
      -device "scsi-cd,drive=cd0,bus=scsi0.0"
    )
    set_firmware installer
    ;;
esac
installer=(
  "${common[@]}" -m 1536 -smp 1
  "${firmware[@]}"
  -drive "file=$workdir/blank.qcow2,format=qcow2,if=virtio"
  "${media[@]}"
)
run_until installer-prompt 'FRR_APPLIANCE_INSTALLER=READY' 180 "${installer[@]}"

kernel="$PWD/work/$variant/installer-iso/vmlinuz"
initrd="$PWD/work/$variant/installer-iso/installer-initrd.gz"
[[ -r "$kernel" && -r "$initrd" ]] || { echo 'installer kernel or initrd missing' >&2; exit 1; }
qemu-img create -q -f qcow2 "$workdir/target.qcow2" 6G
write_log="$workdir/installer-write.log"
timeout 1800 "$qemu" \
  "${common[@]}" -m 1536 -smp 2 \
  -kernel "$kernel" -initrd "$initrd" \
  -append "appliance.installer=1 appliance.autoinstall=1 appliance.target=/dev/vda console=${APPLIANCE_SERIAL},115200n8" \
  -drive "file=$workdir/target.qcow2,format=qcow2,if=virtio" \
  "${media[@]}" \
  >"$write_log" 2>&1 || true
grep -q 'Done, rebooting' "$write_log" || {
  echo 'unattended install did not finish' >&2
  tail -120 "$write_log" >&2 || true
  exit 1
}

firmware=()
if [[ "$APPLIANCE_ARCH" != amd64 ]]; then
  set_firmware installed
fi
installed=(
  "${common[@]}" -m "$mem" -smp 2
  "${firmware[@]}"
  -drive "file=$workdir/target.qcow2,format=qcow2,if=virtio"
  "${net[@]}"
)
boot_wait installed "${installed[@]}"
