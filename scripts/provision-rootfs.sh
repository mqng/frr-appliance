#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: provision-rootfs.sh <vanilla|vpp>}
case "$variant" in vanilla|vpp) ;; *) exit 2 ;; esac
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
suite=${VERSION_CODENAME:?}

bash /tmp/scripts/install-frr.sh "$suite"
if [[ "$variant" == vpp ]]; then
  bash /tmp/scripts/install-vpp.sh "$suite"
fi

install -d -m 0755 /etc/appliance /usr/local/sbin /etc/sudoers.d
cp -a /tmp/config/common/etc/. /etc/
if [[ "$variant" == vpp ]]; then
  cp -a /tmp/config/vpp/etc/. /etc/
fi

# Git only carries an executable bit, and checkout umasks vary across runners.
# Systemd refuses to treat world-writable unit files as a sane configuration.
find /etc/systemd/system -type d -exec chmod 0755 {} +
find /etc/systemd/system -type f -exec chmod 0644 {} +

for s in frr-login appliance-firstboot appliance-grow-root appliance-selftest appliance-info appliance-identity; do
  install -m 0755 "/tmp/scripts/$s" "/usr/local/sbin/$s"
done
install -d -m 0755 /usr/local/libexec
install -m 0755 /tmp/scripts/image-finalize /usr/local/libexec/frr-appliance-image-finalize
if [[ "$variant" == vpp ]]; then
  install -m 0755 /tmp/scripts/vpp-dpdk-prepare /usr/local/sbin/vpp-dpdk-prepare
  install -m 0755 /tmp/scripts/vpp-lcp-setup /usr/local/sbin/vpp-lcp-setup
fi

# The root image is assembled later with these filesystem labels.
cat > /etc/fstab <<'FSTAB'
LABEL=rootfs / ext4 defaults,errors=remount-ro 0 1
LABEL=EFI /boot/efi vfat umask=0077 0 1
FSTAB

# FRR owns interface addressing and routing. Linux only brings up loopback.
cat > /etc/network/interfaces <<'NET'
auto lo
iface lo inet loopback
NET
rm -f /etc/network/interfaces.d/* 2>/dev/null || true

getent group netadmin >/dev/null || groupadd --system netadmin
if ! id admin >/dev/null 2>&1; then
  useradd --create-home --shell /usr/local/sbin/frr-login --groups netadmin,frrvty admin
else
  usermod --shell /usr/local/sbin/frr-login --append --groups netadmin,frrvty admin
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

cat > /etc/systemd/system/appliance-grow-root.service <<'UNIT'
[Unit]
Description=Grow appliance root filesystem
After=local-fs.target
ConditionPathExists=!/var/lib/appliance/root-grown

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/appliance-grow-root

[Install]
WantedBy=multi-user.target
UNIT

selftest_timeout=240
if [[ "$variant" == vpp ]]; then
  selftest_timeout=360
fi
cat > /etc/systemd/system/appliance-selftest.service <<UNIT
[Unit]
Description=FRR appliance CI self-test
After=local-fs.target systemd-udevd.service
ConditionPathExists=/dev/virtio-ports/org.frr.appliance.selftest

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/appliance-selftest $variant
TimeoutStartSec=$selftest_timeout

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /var/lib/appliance /var/log/frr /var/log/vpp
chown frr:frr /var/log/frr
chmod 0750 /var/log/frr

mkdir -p /etc/default/grub.d
if [[ "$variant" == vpp ]]; then
  cat > /etc/default/grub.d/99-appliance.cfg <<'GRUB'
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB
else
  cat > /etc/default/grub.d/99-appliance.cfg <<'GRUB'
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB
fi

# Ensure generic virtio guests can boot and expose the CI result channel.
cat > /etc/initramfs-tools/modules <<'MODULES'
virtio_pci
virtio_blk
virtio_net
virtio_console
ext4
MODULES

build_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
frr_version=$(dpkg-query -W -f='${Version}' frr)
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
VPP_VERSION=$vpp_version
FRR_KEYRING_SHA256=$frr_keyring_sha256
VPP_KEYRING_SHA256=$vpp_keyring_sha256
ENV

dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort > /etc/appliance/packages.txt

apt-mark hold frr frr-pythontools frr-rpki-rtrlib frr-snmp >/dev/null 2>&1 || true
if [[ "$variant" == vpp ]]; then
  apt-mark hold vpp vpp-plugin-core vpp-plugin-dpdk vpp-drivers >/dev/null 2>&1 || true
fi

# Service enablement and the final initramfs are generated after the tarball is
# placed on its real disk so GRUB/initramfs are built against the final layout.

rm -f /etc/ssh/ssh_host_* /etc/machine-id /var/lib/dbus/machine-id
: > /etc/machine-id

# Do not bake the CI runner's resolver into the appliance.
printf '# Configure DNS for this appliance if name resolution is required.\n' > /etc/resolv.conf

apt-get clean
rm -rf /var/lib/apt/lists/* /var/tmp/*
