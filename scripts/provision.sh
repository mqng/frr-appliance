#!/usr/bin/env bash
set -euo pipefail

variant=${1:?usage: provision.sh <vanilla|vpp>}
case "$variant" in vanilla|vpp) ;; *) exit 2;; esac
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
suite=${VERSION_CODENAME:?}

apt-get update
apt-get full-upgrade -y
apt-get install -y --no-install-recommends \
  linux-image-amd64 grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed dosfstools \
  openssh-server sudo ca-certificates curl gnupg \
  iproute2 ethtool pciutils kmod tcpdump lsof jq less vim-tiny bash-completion \
  nftables chrony auditd apparmor apparmor-utils unattended-upgrades \
  libpam-pwquality cloud-guest-utils initramfs-tools

/opt/frr-appliance-build/scripts/install-frr.sh "$suite"
if [[ "$variant" == vpp ]]; then
  /opt/frr-appliance-build/scripts/install-vpp.sh "$suite"
fi

install -d -m 0755 /etc/appliance /usr/local/sbin /etc/sudoers.d /etc/security/pwquality.conf.d
cp -a /opt/frr-appliance-build/config/common/etc/. /etc/
if [[ "$variant" == vpp ]]; then
  cp -a /opt/frr-appliance-build/config/vpp/etc/. /etc/
fi

install -m 0755 /opt/frr-appliance-build/scripts/frr-login /usr/local/sbin/frr-login
install -m 0755 /opt/frr-appliance-build/scripts/appliance-firstboot /usr/local/sbin/appliance-firstboot
install -m 0755 /opt/frr-appliance-build/scripts/appliance-grow-root /usr/local/sbin/appliance-grow-root
install -m 0755 /opt/frr-appliance-build/scripts/appliance-selftest /usr/local/sbin/appliance-selftest
install -m 0755 /opt/frr-appliance-build/scripts/appliance-info /usr/local/sbin/appliance-info
install -m 0755 /opt/frr-appliance-build/scripts/appliance-identity /usr/local/sbin/appliance-identity
if [[ "$variant" == vpp ]]; then
  install -m 0755 /opt/frr-appliance-build/scripts/vpp-dpdk-prepare /usr/local/sbin/vpp-dpdk-prepare
  install -m 0755 /opt/frr-appliance-build/scripts/vpp-lcp-setup /usr/local/sbin/vpp-lcp-setup
fi

# FRR preference
cat > /etc/network/interfaces <<'NET'
auto lo
iface lo inet loopback
NET
rm -f /etc/network/interfaces.d/* 2>/dev/null || true

# Administrative account
getent group netadmin >/dev/null || groupadd --system netadmin
if ! id admin >/dev/null 2>&1; then
  useradd --create-home --shell /usr/local/sbin/frr-login --groups netadmin,frrvty admin
else
  usermod --shell /usr/local/sbin/frr-login --append --groups netadmin,frrvty admin
fi
passwd -d admin
passwd -l root || true
if ! grep -qxF /usr/local/sbin/frr-login /etc/shells; then echo /usr/local/sbin/frr-login >> /etc/shells; fi

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

cat > /etc/systemd/system/appliance-selftest.service <<UNIT
[Unit]
Description=FRR appliance boot self-test
After=appliance-identity.service frr.service
Wants=appliance-identity.service frr.service
$( [[ "$variant" == vpp ]] && printf 'After=vpp-lcp.service\nWants=vpp-lcp.service\n' )

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/appliance-selftest $variant
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /var/lib/appliance /var/log/frr /var/log/vpp
chown frr:frr /var/log/frr
chmod 0750 /var/log/frr

# Serial and IOMMU config
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

build_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
frr_version=$(dpkg-query -W -f='${Version}' frr)
vpp_version=none
if dpkg-query -W vpp >/dev/null 2>&1; then vpp_version=$(dpkg-query -W -f='${Version}' vpp); fi
cat > /etc/appliance/build.env <<ENV
APPLIANCE_VARIANT=$variant
APPLIANCE_BUILD_TIME=$build_time
DEBIAN_VERSION=$VERSION_ID
DEBIAN_CODENAME=$suite
FRR_VERSION=$frr_version
VPP_VERSION=$vpp_version
ENV

dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort > /etc/appliance/packages.txt

apt-mark hold frr frr-pythontools frr-rpki-rtrlib frr-snmp >/dev/null 2>&1 || true
if [[ "$variant" == vpp ]]; then
  apt-mark hold vpp vpp-plugin-core vpp-plugin-dpdk vpp-drivers >/dev/null 2>&1 || true
fi

root_src=$(findmnt -n -o SOURCE /)
disk=$(lsblk -no PKNAME "$root_src" | head -1)
[[ -n "$disk" ]] && disk=/dev/$disk
if [[ -n "${disk:-}" && -b "$disk" ]]; then
  grub-install --target=i386-pc --recheck "$disk" || true
fi
if mountpoint -q /boot/efi; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=FRRAppliance --uefi-secure-boot --force-extra-removable --no-nvram --recheck
fi
update-grub

# Fail during image construction if the installed GRUB entries lost the serial
# kernel console. This catches the Debian 13 serial-console failure before the
# expensive smoke-test stage.
if ! grep -Eq '^[[:space:]]*linux[[:space:]].*console=ttyS0,115200n8' /boot/grub/grub.cfg; then
  echo 'ERROR: generated GRUB config has no ttyS0 kernel console' >&2
  grep -E '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg >&2 || true
  exit 1
fi

grep -E '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg | head -3 || true
update-initramfs -u -k all

systemctl enable ssh nftables chrony auditd apparmor frr appliance-identity.service appliance-grow-root.service appliance-selftest.service serial-getty@ttyS0.service
if [[ "$variant" == vpp ]]; then
  systemctl enable vpp vpp-dpdk-prepare.service vpp-lcp.service
fi

systemctl enable getty@tty1.service serial-getty@ttyS0.service

rm -f /etc/ssh/ssh_host_* /etc/machine-id
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
sync
fstrim -av || true
