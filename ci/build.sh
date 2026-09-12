#!/usr/bin/env bash
set -euo pipefail

variant=${1:?}
source work/base.env

name="frr-appliance-${variant}-amd64"
workdir="$PWD/work/$variant"
outdir="$PWD/out"
mkdir -p "$workdir/http" "$outdir"

tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$workdir/http/appliance-bundle.tar.gz" scripts config

bundle_sha256=$(sha256sum "$workdir/http/appliance-bundle.tar.gz" | awk '{print $1}')
sed -e "s/__VARIANT__/$variant/g" -e "s/__BUNDLE_SHA256__/$bundle_sha256/g" \
  ci/preseed.cfg > "$workdir/http/preseed.cfg"

xorriso -osirrox on -indev "$DEBIAN_ISO_PATH" \
  -extract /install.amd/vmlinuz "$workdir/vmlinuz" \
  -extract /install.amd/initrd.gz "$workdir/initrd.gz" >/dev/null 2>&1

(
  cd "$workdir/http"
  printf '%s\n' preseed.cfg | cpio --quiet -H newc -o | gzip -c
) > "$workdir/preseed-initrd.gz"
cat "$workdir/initrd.gz" "$workdir/preseed-initrd.gz" > "$workdir/initrd-custom.gz"

qemu-img create -f qcow2 "$workdir/$name.qcow2" "${DISK_SIZE:-4G}"

python3 -m http.server 8080 --bind 0.0.0.0 --directory "$workdir/http" >"$workdir/http.log" 2>&1 &
http_pid=$!
cleanup() {
  kill "$http_pid" 2>/dev/null || true
  [[ -n "${tail_pid:-}" ]] && kill "$tail_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

accel=${QEMU_ACCEL:-tcg}
qemu_args=(
  -machine q35,accel="$accel"
  -m 3072
  -smp 2
  -drive "file=$workdir/$name.qcow2,format=qcow2,if=virtio,cache=writeback"
  -drive "file=$DEBIAN_ISO_PATH,format=raw,media=cdrom,readonly=on"
  -netdev user,id=n0
  -device virtio-net-pci,netdev=n0
  -kernel "$workdir/vmlinuz"
  -initrd "$workdir/initrd-custom.gz"
  -append "auto=true priority=critical locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us hostname=frr-router domain=local interface=auto netcfg/choose_interface=auto console=ttyS0,115200n8 DEBIAN_FRONTEND=text"
  -nographic
  -no-reboot
)
if [[ "$accel" == tcg ]]; then
  qemu_args+=( -cpu Nehalem )
fi

install_log="$workdir/install-console.log"
: > "$install_log"
tail -n +1 -F "$install_log" &
tail_pid=$!

set +e
setsid timeout 5400 qemu-system-x86_64 "${qemu_args[@]}" >"$install_log" 2>&1 &
qemu_pid=$!
prompt_detected=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  if grep -qE '^Prompt:|Prompt: .*for help' "$install_log"; then
    echo "ERROR: unexpected interactive Debian Installer prompt detected" >&2
    prompt_detected=1
    kill -TERM -- "-$qemu_pid" 2>/dev/null || kill "$qemu_pid" 2>/dev/null || true
    break
  fi
  sleep 2
done
wait "$qemu_pid"
rc=$?
set -e

kill "$tail_pid" 2>/dev/null || true
tail_pid=

if [[ $prompt_detected -ne 0 ]]; then
  tail -200 "$install_log" >&2 || true
  exit 86
fi
if [[ $rc -ne 0 ]]; then
  echo "QEMU installer failed with status $rc" >&2
  tail -200 "$install_log" >&2 || true
  exit "$rc"
fi

kill "$http_pid" 2>/dev/null || true
trap - EXIT

qemu-img convert -p -O raw -S 4k "$workdir/$name.qcow2" "$outdir/$name.img"
cp --reflink=auto "$workdir/$name.qcow2" "$outdir/$name.qcow2"
zstd -T0 -15 --long=27 -f "$outdir/$name.img" -o "$outdir/$name.img.zst"

./ci/build-installer-iso.sh "$variant" "$DEBIAN_ISO_PATH" "$outdir/$name.img" "$outdir/$name-installer.iso"
