#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
iso="$PWD/out/$name-installer.iso"
workdir="$PWD/work/$variant/smoke"
mkdir -p "$workdir"

# GitLab SaaS runners normally use TCG rather than KVM.
# VPP images can take considerably longer to boot under software emulation.
boot_timeout=600
if [[ "$variant" == "vpp" ]]; then
  boot_timeout=900
fi

boot_wait() {
  local label=$1
  shift

  local log="$workdir/$label.log"
  local pid
  local ok=0

  : > "$log"

  qemu-system-x86_64 "$@" >"$log" 2>&1 &
  pid=$!

  for second in $(seq 1 "$boot_timeout"); do
    if grep -q 'APPLIANCE_SELFTEST=PASS' "$log"; then
      ok=1
      break
    fi

    if grep -q 'APPLIANCE_SELFTEST=FAIL' "$log"; then
      break
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi

    # Once GRUB hands off to Linux, serial kernel output should appear quickly.
    # Fail early instead of burning the full CI timeout on a kernel/console hang.
    if [[ $second -eq 120 ]] && ! grep -Eq 'Linux version|APPLIANCE_SELFTEST=START' "$log"; then
      echo "$label kernel handoff produced no serial output after 120 seconds" >&2
      break
    fi

    if grep -Eq 'Kernel panic|Entering emergency mode|You are in emergency mode' "$log"; then
      break
    fi

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

# BIOS boot test.
qemu-img create \
  -q \
  -f qcow2 \
  -F raw \
  -b "$img" \
  "$workdir/bios-overlay.qcow2"

common=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}"
  -m 2048
  -smp 2
  -drive "file=$workdir/bios-overlay.qcow2,format=qcow2,if=virtio"
  -netdev user,id=n0
  -device virtio-net-pci,netdev=n0
  -nographic
  -no-reboot
)

if [[ ${QEMU_ACCEL:-tcg} == "tcg" ]]; then
  common+=( -cpu Nehalem )
fi

boot_wait bios "${common[@]}"

# UEFI boot test.
code=""
vars=""

for f in \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE_4M.fd
do
  if [[ -r "$f" ]]; then
    code=$f
    break
  fi
done

for f in \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/OVMF/OVMF_VARS_4M.fd
do
  if [[ -r "$f" ]]; then
    vars=$f
    break
  fi
done

if [[ -n "$code" && -n "$vars" ]]; then
  cp "$vars" "$workdir/OVMF_VARS.fd"

  qemu-img create \
    -q \
    -f qcow2 \
    -F raw \
    -b "$img" \
    "$workdir/uefi-overlay.qcow2"

  uefi=(
    -machine "q35,accel=${QEMU_ACCEL:-tcg}"
    -m 2048
    -smp 2
    -drive "if=pflash,format=raw,readonly=on,file=$code"
    -drive "if=pflash,format=raw,file=$workdir/OVMF_VARS.fd"
    -drive "file=$workdir/uefi-overlay.qcow2,format=qcow2,if=virtio"
    -netdev user,id=n0
    -device virtio-net-pci,netdev=n0
    -nographic
    -no-reboot
  )

  if [[ ${QEMU_ACCEL:-tcg} == "tcg" ]]; then
    uefi+=( -cpu Nehalem )
  fi

  boot_wait uefi "${uefi[@]}"
else
  echo "OVMF not found; refusing to publish without UEFI smoke test" >&2
  exit 1
fi

# Verify that the generated installer ISO boots far enough to show
# the appliance installer rather than only validating the ISO structure.
iso_log="$workdir/installer-iso.log"

qemu-img create \
  -q \
  -f qcow2 \
  "$workdir/blank.qcow2" \
  5G

iso_args=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}"
  -m 1536
  -smp 1
  -drive "file=$workdir/blank.qcow2,format=qcow2,if=virtio"
  -cdrom "$iso"
  -boot d
  -nographic
  -no-reboot
)

if [[ ${QEMU_ACCEL:-tcg} == "tcg" ]]; then
  iso_args+=( -cpu Nehalem )
fi

qemu-system-x86_64 "${iso_args[@]}" >"$iso_log" 2>&1 &
pid=$!

ok=0
iso_timeout=300

for _ in $(seq 1 "$iso_timeout"); do
  if grep -q 'FRR Appliance installer' "$iso_log"; then
    ok=1
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
  echo "Installer ISO smoke-test failed" >&2
  tail -200 "$iso_log" >&2 || true
  exit 1
fi
