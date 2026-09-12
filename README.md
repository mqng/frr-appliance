# FRR appliance

Debian disk images running [FRRouting](https://frrouting.org/). Configured in
`vtysh`.

| Variant | Base | Dataplane |
| --- | --- | --- |
| `vanilla` | Debian 13 | kernel |
| `vpp` | Debian 12 | [VPP](https://fd.io/) + DPDK, paired to FRR via LCP |

amd64 only. `vpp` stays on Debian 12 since fd.io has no trixie packages, and
needs an IOMMU plus real NICs.

## Install

Per variant: `*-installer.iso`, `*.img.zst`, `*.qcow2`, `*-SHA256SUMS` and
Sigstore bundles.

Boot the ISO from USB or virtual media. Pick the VGA or serial entry (115200
8N1) to match your console. It lists target disks and wants `ERASE` typed. The
disk it booted from is not offered.

Unattended: `appliance.installer=1 appliance.autoinstall=1 appliance.target=/dev/sda`

Or write the image directly:

```
zstd -d frr-appliance-vanilla-amd64.img.zst
dd if=frr-appliance-vanilla-amd64.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Root grows to fill the disk on first boot.

## First boot

Log in on the console. Setup asks for hostname, admin password, and whether to
auto-install security updates. Before that the console needs no password and SSH
does not work.

Then you get `vtysh`. `exit` drops to bash. `admin` has full `sudo`.
`appliance-info` shows build and versions.

## Backup

```
ssh admin@router sudo appliance-backup > router.tgz
ssh admin@router sudo appliance-restore < router.tgz
```

Covers FRR, `/etc/nftables.d`, hostname, hosts, resolver, chrony, snmpd,
`vpp-dpdk.conf`, update setting. Not passwords or host keys. Restore reloads FRR
and nftables, and refuses rules that fail `nft --check`.

## Configuration

Routing in `vtysh`, `write memory`. All FRR daemons are enabled but
unconfigured, so `router bgp` and friends work without editing
`/etc/frr/daemons`.

`/etc/nftables.conf` allows SSH, ICMP and every protocol FRR can start, drops
the rest, and does not filter forwarding. Own rules in `/etc/nftables.d/*.nft`.

Serial and VGA both work at 115200 8N1, GRUB through login.

## Included

- Secure Boot, signed shim and GRUB
- AppArmor
- auditd rules for FRR and firewall config, users, sudo, modules, clock
- SSH: `admin` only, no root, no empty passwords, rate limited
- Passwords: 12 characters, 3 classes, cracklib
- Sysctl: no redirects, no source routing, no unprivileged BPF, restricted
  `dmesg`, `kptr`, `ptrace`
- `/tmp` on tmpfs, `nosuid`, `nodev`
- `snmpd` installed, disabled
- CycloneDX SBOM, package list, build manifest, SLSA provenance, Sigstore signed

## Versions

| Component | Tracks | Set in |
| --- | --- | --- |
| Debian | frozen suite, point releases only | `expected_major`, `ci/resolve-base.sh` |
| FRR | `frr-10.4` patch line | `channel`, `scripts/install-frr.sh` |
| VPP | fd.io `release` for the suite | apt hold, no per-line repo exists |
| cosign | sha256 | `COSIGN_VERSION`, `ci/install-build-deps.sh` |

Releases list what they were built from. `apt upgrade` takes FRR patches but
cannot leave the line, since `preferences.d/50-frr` outranks Debian's `frr`.

Security updates are off by default, login notice instead, no auto reboots.
Signing keys are checked against `key_sha256` in the install scripts.

## Options

`/etc/appliance/vpp-dpdk.conf`:

| Setting | Default | Effect |
| --- | --- | --- |
| `MODE` | `all` | `all` binds every PCI NIC to DPDK, anything else binds none |
| `IOMMU_REQUIRED` | `1` | Leave NICs under Linux when there is no IOMMU |
| `EXCLUDE_IFACES` | empty | Interface names to leave under Linux |
| `EXCLUDE_PCI` | empty | PCI addresses to leave under Linux |

Build:

| Variable | Default | Effect |
| --- | --- | --- |
| `DISK_SIZE` | `4G` | Image size before first-boot growth |
| `QEMU_ACCEL` | `tcg` | Accelerator for the boot tests |
| `PUBLISH_RAW_IMG` | `true` | Also publish and sign the raw image |

## Build

Privileged Linux host, since it uses loop devices and a chroot. `make lint` needs
`shellcheck` and `nftables`.

```
make lint
make build-vanilla
make build-vpp
```

`ci/pipeline.sh` builds the rootfs with `mmdebstrap`, assembles the disk, then
boots it under QEMU on BIOS, on UEFI Secure Boot, and after an unattended install
to a blank disk. Artifacts in `out/`.

Every boot self-tests FRR, `vtysh`, sshd, the firewall, and a route from `vtysh`
reaching the kernel.

Same scripts run from `.gitlab-ci.yml` and `.github/workflows/appliance.yml`.
