#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
name="frr-appliance-${variant}-amd64"
img="$PWD/out/$name.img"
iso="$PWD/out/$name-installer.iso"
workdir="$PWD/work/$variant/smoke"
mkdir -p "$workdir"

# GitLab SaaS normally runs QEMU with TCG. The self-test result is transported
# over a dedicated virtio serial port so success does not depend on the guest's
# human console remaining visible after GRUB hands off to Linux.
boot_timeout=300
[[ "$variant" == "vpp" ]] && boot_timeout=600

boot_wait() {
  local label=$1
  local ssh_port=$2
  shift 2

  local log="$workdir/$label.log"
  local result="$workdir/$label.selftest"
  local qemu_debug="$workdir/$label.qemu-debug.log"
  local pid
  local ready=0
  local ssh_ready=0
  local ok=0
  local ready_deadline=$((SECONDS + 240))
  local test_deadline=0

  : > "$log"
  : > "$result"
  : > "$qemu_debug"

  qemu-system-x86_64 \
    "$@" \
    -device virtio-serial-pci \
    -chardev "file,id=appliance_selftest,path=$result" \
    -device virtserialport,chardev=appliance_selftest,name=org.frr.appliance.selftest \
    -d guest_errors,cpu_reset \
    -D "$qemu_debug" \
    >"$log" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if grep -q 'APPLIANCE_BOOT=READY' "$result" 2>/dev/null; then
      ready=1
    fi

    # SSH is an independent userspace signal. This prevents a missing
    # virtio_console module from being misreported as a kernel boot failure.
    if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$ssh_port; IFS= read -r banner <&3; [[ \$banner == SSH-* ]]" 2>/dev/null; then
      ssh_ready=1
      ready=1
    fi

    if [[ $ready -eq 1 && $test_deadline -eq 0 ]]; then
      test_deadline=$((SECONDS + 300))
    fi

    if grep -q 'APPLIANCE_SELFTEST=PASS' "$result" 2>/dev/null; then
      ok=1
      break
    fi
    if grep -q 'APPLIANCE_SELFTEST=FAIL' "$result" 2>/dev/null; then
      break
    fi

    if [[ $ready -eq 0 && $SECONDS -ge $ready_deadline ]]; then
      echo "$label produced neither the boot beacon nor an SSH banner" >&2
      break
    fi
    if [[ $ready -eq 1 && $SECONDS -ge $test_deadline ]]; then
      echo "$label reached userspace but appliance self-test timed out" >&2
      break
    fi

    sleep 1
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [[ $ok -ne 1 ]]; then
    echo "$label boot self-test failed" >&2
    echo "userspace: beacon=$ready ssh=$ssh_ready" >&2
    if [[ -s "$result" ]]; then
      echo "--- appliance result channel ---" >&2
      cat "$result" >&2 || true
    fi
    echo "--- serial console ---" >&2
    tail -200 "$log" >&2 || true
    echo "--- qemu debug ---" >&2
    tail -100 "$qemu_debug" >&2 || true
    return 1
  fi
}

# BIOS boot test.
qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/bios-overlay.qcow2"
common=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}"
  -m 2048
  -smp 2
  -drive "file=$workdir/bios-overlay.qcow2,format=qcow2,if=virtio"
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:22022-:22
  -device virtio-net-pci,netdev=n0
  -display none
  -serial stdio
  -monitor none
  -no-reboot
)
if [[ ${QEMU_ACCEL:-tcg} == "tcg" ]]; then
  common+=( -cpu Nehalem )
fi
boot_wait bios 22022 "${common[@]}"

# UEFI boot test.
code=""
vars=""
for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
  [[ -r "$f" ]] && { code=$f; break; }
done
for f in /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd; do
  [[ -r "$f" ]] && { vars=$f; break; }
done

if [[ -n "$code" && -n "$vars" ]]; then
  cp "$vars" "$workdir/OVMF_VARS.fd"
  qemu-img create -q -f qcow2 -F raw -b "$img" "$workdir/uefi-overlay.qcow2"
  uefi=(
    -machine "q35,accel=${QEMU_ACCEL:-tcg}"
    -m 2048
    -smp 2
    -drive "if=pflash,format=raw,readonly=on,file=$code"
    -drive "if=pflash,format=raw,file=$workdir/OVMF_VARS.fd"
    -drive "file=$workdir/uefi-overlay.qcow2,format=qcow2,if=virtio"
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:22023-:22
    -device virtio-net-pci,netdev=n0
    -display none
    -serial stdio
    -monitor none
    -no-reboot
  )
  if [[ ${QEMU_ACCEL:-tcg} == "tcg" ]]; then
    uefi+=( -cpu Nehalem )
  fi
  boot_wait uefi 22023 "${uefi[@]}"
else
  echo "OVMF not found; refusing to publish without UEFI smoke test" >&2
  exit 1
fi

# Installer ISO test: verify that the remastered ISO reaches our installer.
iso_log="$workdir/installer-iso.log"
qemu-img create -q -f qcow2 "$workdir/blank.qcow2" 5G
iso_args=(
  -machine "q35,accel=${QEMU_ACCEL:-tcg}"
  -m 1536
  -smp 1
  -drive "file=$workdir/blank.qcow2,format=qcow2,if=virtio"
  -cdrom "$iso"
  -boot d
  -display none
  -serial stdio
  -monitor none
  -no-reboot
)
if [[ ${QEMU_ACCEL:-tcg} == "tcg" ]]; then
  iso_args+=( -cpu Nehalem )
fi

qemu-system-x86_64 "${iso_args[@]}" >"$iso_log" 2>&1 &
pid=$!
ok=0
for _ in $(seq 1 300); do
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
