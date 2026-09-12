#!/usr/bin/env bash
set -euo pipefail

ensure_loop_nodes() {
  if [[ ! -e /dev/loop-control ]]; then
    mknod -m 0660 /dev/loop-control c 10 237 || {
      echo 'cannot create /dev/loop-control; runner is not privileged' >&2
      return 1
    }
  fi
  local i
  for i in $(seq 0 127); do
    if [[ ! -e "/dev/loop$i" ]]; then
      mknod -m 0660 "/dev/loop$i" b 7 "$i" || {
        echo "cannot create /dev/loop$i; runner is not privileged" >&2
        return 1
      }
    fi
  done
}

attach_loop() {
  local image=${1:?}
  local mode=${2:-rw}
  local scan=${3:-no}
  local node i
  local -a opts=()
  [[ "$mode" == ro ]] && opts+=(--read-only)
  [[ "$scan" == yes ]] && opts+=(--partscan)

  ensure_loop_nodes
  for i in $(seq 0 127); do
    node="/dev/loop$i"
    if losetup "$node" >/dev/null 2>&1; then
      continue
    fi
    if losetup "${opts[@]}" "$node" "$image"; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  echo 'No usable loop device available' >&2
  return 1
}

create_partition_nodes() {
  local loopdev=${1:?}
  local count=${2:-3}
  local base part sysdev majmin major minor node i
  base=$(basename "$loopdev")

  partprobe "$loopdev" >/dev/null 2>&1 || true
  blockdev --rereadpt "$loopdev" >/dev/null 2>&1 || true

  for i in $(seq 1 "$count"); do
    part="${base}p${i}"
    sysdev="/sys/class/block/$part/dev"
    node="/dev/$part"
    rm -f "$node"
    for _ in $(seq 1 50); do
      if [[ -r "$sysdev" ]]; then
        majmin=$(cat "$sysdev")
        major=${majmin%%:*}
        minor=${majmin##*:}
        [[ -e "$node" ]] || mknod -m 0660 "$node" b "$major" "$minor"
      fi
      [[ -b "$node" ]] && break
      sleep 0.1
    done
    [[ -b "$node" ]] || {
      echo "partition device did not appear: $part" >&2
      return 1
    }
  done
}

loop_preflight() {
  local tmp loopdev='' mnt base
  tmp=$(mktemp)
  mnt=$(mktemp -d)
  truncate -s 64M "$tmp"

  cleanup_preflight() {
    set +e
    mountpoint -q "$mnt" && umount "$mnt" || true
    [[ -n "$loopdev" ]] && losetup -d "$loopdev" 2>/dev/null || true
    rm -f "$tmp"
    rmdir "$mnt" 2>/dev/null || true
  }
  trap cleanup_preflight RETURN

  loopdev=$(attach_loop "$tmp" rw yes)
  parted -s "$loopdev" mklabel gpt mkpart TEST ext4 1MiB 63MiB
  create_partition_nodes "$loopdev" 1
  base=$(basename "$loopdev")
  mkfs.ext4 -F "/dev/${base}p1" >/dev/null
  mount "/dev/${base}p1" "$mnt"
  printf 'ok\n' > "$mnt/preflight"
  sync
  [[ $(cat "$mnt/preflight") == ok ]]
  cleanup_preflight
  trap - RETURN
}
