#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: provision-rootfs.sh <vanilla|vpp>}
case "$variant" in vanilla|vpp) ;; *) exit 2 ;; esac
export DEBIAN_FRONTEND=noninteractive

# build containers often umask 0000
umask 0022

. /etc/os-release
suite=${VERSION_CODENAME:?}

bash /tmp/scripts/install-frr.sh "$suite"
if [[ "$variant" == vpp ]]; then
  bash /tmp/scripts/install-vpp.sh "$suite"
fi

install -d -m 0755 /etc/appliance /usr/local/sbin /etc/sudoers.d

# git only keeps the exec bit, so tighten what cp -a copied
copy_config() {
  local tree=$1
  cp -a "$tree/." /etc/
  (cd "$tree" && find . -mindepth 1 -type d -printf '%P\0') |
    while IFS= read -r -d '' path; do chmod go-w "/etc/$path"; done
  (cd "$tree" && find . -type f -printf '%P\0') |
    while IFS= read -r -d '' path; do chmod go-w,a-x "/etc/$path"; done
}
copy_config /tmp/config/common/etc

# bookworm keeps tmp.mount in /usr/share/systemd, where enable cannot see it
if [[ ! -e /usr/lib/systemd/system/tmp.mount && -e /usr/share/systemd/tmp.mount ]]; then
  install -m 0644 /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount
fi

if [[ "$variant" == vpp ]]; then
  copy_config /tmp/config/vpp/etc

  # we reset After=, catch new upstream ordering
  vpp_unit=$(dpkg -L vpp | grep -E '/systemd/system/vpp\.service$' | head -1 || true)
  [[ -n "$vpp_unit" && -r "$vpp_unit" ]] || { echo 'packaged vpp.service not found' >&2; exit 1; }
  vpp_extra_after=$(sed -n 's/^After=//p' "$vpp_unit" | tr ' ' '\n' |
    grep -v -e '^network\.target$' -e '^$' || true)
  [[ -z "$vpp_extra_after" ]] || {
    echo "unreviewed ordering in packaged vpp.service: $vpp_extra_after" >&2
    exit 1
  }
fi

# pwquality rejects every password without this
update-cracklib >/dev/null
compgen -G '/var/cache/cracklib/cracklib_dict.*' >/dev/null || {
  echo 'cracklib dictionary was not generated' >&2
  exit 1
}

# catch typos before first boot
nft --check --file /etc/nftables.conf

for s in frr-login appliance-getty appliance-firstboot appliance-grow-root \
         appliance-selftest appliance-info appliance-identity appliance-update-check \
         appliance-backup appliance-restore; do
  install -m 0755 "/tmp/scripts/$s" "/usr/local/sbin/$s"
done
install -d -m 0755 /usr/local/libexec
install -m 0755 /tmp/scripts/image-finalize /usr/local/libexec/frr-appliance-image-finalize
if [[ "$variant" == vpp ]]; then
  install -m 0755 /tmp/scripts/vpp-dpdk-prepare /usr/local/sbin/vpp-dpdk-prepare
  install -m 0755 /tmp/scripts/vpp-lcp-setup /usr/local/sbin/vpp-lcp-setup
fi

# assemble-image rewrites these to UUIDs
cat > /etc/fstab <<'FSTAB'
LABEL=rootfs / ext4 defaults,errors=remount-ro 0 1
LABEL=EFI /boot/efi vfat umask=0077 0 1
FSTAB

printf 'router\n' > /etc/hostname
cat > /etc/hosts <<'HOSTS'
127.0.0.1 localhost
127.0.1.1 router
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS

# FRR does the addressing
cat > /etc/network/interfaces <<'NET'
auto lo
iface lo inet loopback
NET
rm -f /etc/network/interfaces.d/* 2>/dev/null || true

getent group netadmin >/dev/null || groupadd --system netadmin
# vtysh, logs and vppctl without sudo
admin_groups=netadmin,frrvty,adm,systemd-journal
if ! id admin >/dev/null 2>&1; then
  useradd --create-home --shell /usr/local/sbin/frr-login --groups "$admin_groups" admin
else
  usermod --shell /usr/local/sbin/frr-login --append --groups "$admin_groups" admin
fi
passwd -d admin
passwd -l root || true
if ! grep -qxF /usr/local/sbin/frr-login /etc/shells; then
  echo /usr/local/sbin/frr-login >> /etc/shells
fi

cat > /etc/sudoers.d/appliance <<'SUDO'
Defaults:admin timestamp_timeout=5
admin ALL=(root) NOPASSWD: /usr/local/sbin/appliance-firstboot
%netadmin ALL=(ALL:ALL) ALL
SUDO
chmod 0440 /etc/sudoers.d/appliance

chown frr:frr /etc/frr/daemons /etc/frr/frr.conf
chmod 0640 /etc/frr/daemons /etc/frr/frr.conf
chown root:frrvty /etc/frr/vtysh.conf
chmod 0640 /etc/frr/vtysh.conf

mkdir -p /var/lib/appliance /var/log/frr /var/log/vpp
chown frr:frr /var/log/frr
chmod 0750 /var/log/frr

mkdir -p /etc/default/grub.d
if [[ "$variant" == vpp ]]; then
  cmdline_default="intel_iommu=on iommu=pt"
else
  cmdline_default=""
fi
cat > /etc/default/grub.d/99-appliance.cfg <<GRUB
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 audit=1 audit_backlog_limit=8192"
GRUB_CMDLINE_LINUX_DEFAULT="$cmdline_default"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB

cat > /etc/initramfs-tools/modules <<'MODULES'
virtio_pci
virtio_blk
virtio_net
virtio_console
ext4
MODULES

build_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
frr_version=$(dpkg-query -W -f='${Version}' frr)
frr_channel=$(awk -F': ' '/^Components:/{print $2}' /etc/apt/sources.list.d/frr.sources)
vpp_version=none
frr_keyring_sha256=$(sha256sum /usr/share/keyrings/frrouting.gpg | awk '{print $1}')
vpp_keyring_sha256=none
if dpkg-query -W vpp >/dev/null 2>&1; then
  vpp_version=$(dpkg-query -W -f='${Version}' vpp)
  vpp_keyring_sha256=$(sha256sum /etc/apt/keyrings/fdio-release.asc | awk '{print $1}')
fi
cat > /etc/appliance/build.env <<ENV
APPLIANCE_VARIANT=$variant
APPLIANCE_BUILD_TIME=$build_time
DEBIAN_VERSION=$VERSION_ID
DEBIAN_CODENAME=$suite
FRR_VERSION=$frr_version
FRR_CHANNEL=$frr_channel
VPP_VERSION=$vpp_version
FRR_KEYRING_SHA256=$frr_keyring_sha256
VPP_KEYRING_SHA256=$vpp_keyring_sha256
ENV

dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort > /etc/appliance/packages.txt

# frr unheld, the pinned line only offers patches. fd.io has no line to pin
if [[ "$variant" == vpp ]]; then
  apt-mark hold vpp vpp-plugin-core vpp-plugin-dpdk vpp-drivers >/dev/null 2>&1 || true
fi

rm -f /etc/ssh/ssh_host_* /etc/machine-id /var/lib/dbus/machine-id
: > /etc/machine-id

printf '# Set a resolver here if this appliance needs name resolution\n' > /etc/resolv.conf

apt-get clean
rm -rf /var/lib/apt/lists/* /var/tmp/*
