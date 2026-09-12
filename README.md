# FRR appliance

Debian disk images with [FRRouting](https://frrouting.org/) set up as a router.
You configure it in `vtysh`.

Two variants, amd64 only:

| Variant | Base | Dataplane |
| --- | --- | --- |
| `vanilla` | Debian 13 | kernel |
| `vpp` | Debian 12 | [VPP](https://fd.io/) with DPDK, linked to FRR through LCP |

`vpp` is on Debian 12 because fd.io has no trixie packages. It binds NICs to
`vfio-pci`, so it needs an IOMMU and physical or passed-through hardware.

## Versions

Nothing crosses a feature release on its own. Debian comes from a frozen suite,
so builds pick up point releases and security updates only. FRR tracks a patch
line, `frr-10.4`, set as `channel` in `scripts/install-frr.sh`. VPP comes from
fd.io's `release` repo, which holds the last tagged release for the suite.

Each release lists the exact versions it was built from, so two runs can be
compared without downloading anything.

Three things stop a build on purpose:

- A new Debian major, blocked by `expected_major` in `ci/resolve-base.sh`
- A changed FRR or fd.io signing key, checked against `key_sha256` in the
  install scripts
- `COSIGN_VERSION` in `ci/install-build-deps.sh`, pinned with a hash

Moving to a newer FRR means changing `channel` and reading their release notes.
A patch line stops getting fixes eventually, so it is worth checking yearly.

## Install

Each build produces, per variant:

- `*-installer.iso`, writes the image to a disk you pick
- `*.img.zst`, the raw image
- `*.qcow2`, for libvirt or QEMU
- `*-SHA256SUMS` plus Sigstore bundles

### Installer ISO

Boot it from USB or virtual media. The menu has a VGA entry and a serial entry
(115200 8N1), pick the one for the console you are on. It lists the disks it can
write to and asks you to type `ERASE` first. The disk it booted from is not
offered.

Unattended:

```
appliance.installer=1 appliance.autoinstall=1 appliance.target=/dev/sda
```

### Disk image

```
zstd -d frr-appliance-vanilla-amd64.img.zst
dd if=frr-appliance-vanilla-amd64.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Root grows to fill the disk on first boot.

### First boot

Log in on the console. Setup asks for a hostname, an admin password, and whether
to install security updates automatically. Until it finishes, the console logs in
without a password and SSH does not work.

After that you land in `vtysh`. `exit` leaves it for a shell. `admin` has full
`sudo`. `appliance-info` prints the build and versions.

## Configuration

Routing goes in `vtysh`, saved with `write memory`. Every FRR daemon is enabled
but unconfigured, so `router bgp`, `router ospf` and the rest work without
touching `/etc/frr/daemons`.

`/etc/nftables.conf` allows SSH, ICMP and every protocol FRR can start, and drops
everything else. Forwarding is not filtered. Put your own rules in
`/etc/nftables.d/*.nft`.

Serial and VGA consoles both work at 115200 8N1, from GRUB to login.

## Included

- Secure Boot with signed shim and GRUB
- AppArmor
- auditd, with rules for FRR and firewall config, user and sudo changes, module
  loading and clock changes
- SSH: `admin` only, no root, no empty passwords, rate limited on new connections
- Passwords: 12 characters, 3 character classes, checked against cracklib
- Sysctl: no redirects, no source routing, no unprivileged BPF, restricted
  `dmesg`, `kptr` and `ptrace`
- `/tmp` on tmpfs, `nosuid` and `nodev`
- Security updates: off by default, with a notice at login instead. Turn them on
  at first boot or with `APT::Periodic::Unattended-Upgrade "1"`. Never reboots on
  its own, but tells you at login when a newer kernel is waiting
- `snmpd` installed but disabled. FRR exports MIBs over AgentX once you enable it
- FRR and VPP packages held, so an upgrade cannot move them
- CycloneDX SBOM, package list, build manifest and SLSA provenance, all signed
  with Sigstore

## Options

`/etc/appliance/vpp-dpdk.conf`, `vpp` variant:

| Setting | Default | Effect |
| --- | --- | --- |
| `MODE` | `all` | `all` binds every PCI NIC to DPDK, anything else binds none |
| `IOMMU_REQUIRED` | `1` | Leave NICs under Linux when there is no IOMMU |
| `EXCLUDE_IFACES` | empty | Interface names to leave under Linux |
| `EXCLUDE_PCI` | empty | PCI addresses to leave under Linux |

Build:

| Variable | Default | Effect |
| --- | --- | --- |
| `DISK_SIZE` | `4G` | Image size before it grows on first boot |
| `QEMU_ACCEL` | `tcg` | Accelerator for the boot tests |
| `PUBLISH_RAW_IMG` | `true` | Also publish and sign the uncompressed image |

## Build

Needs a privileged Linux host, since the image is built on loop devices and
finished in a chroot. `make lint` also needs `shellcheck` and `nftables`.

```
make lint
make build-vanilla
make build-vpp
```

Both run `ci/pipeline.sh`: verify the Debian ISO signature, build the rootfs with
`mmdebstrap`, assemble the disk, check it offline, then under QEMU boot it on
BIOS, boot it a second time, boot it on UEFI with Secure Boot, boot the installer
ISO, do an unattended install to a blank disk and boot the result. Then write
metadata and signatures. Artifacts end up in `out/`.

Each boot runs an in-guest self-test that checks FRR, `vtysh`, sshd, the firewall
and that a route configured in `vtysh` reaches the kernel.

`.gitlab-ci.yml` and `.github/workflows/appliance.yml` run the same scripts.
