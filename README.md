# FRR appliance

Debian images preconfigured as an [FRRouting](https://frrouting.org/) router.
Configured in vtysh.

| Variant | Base | Dataplane |
| --- | --- | --- |
| `vanilla` | Debian 13 | Linux kernel |
| `vpp` | Debian 12 | [VPP](https://fd.io/) with DPDK, paired to FRR via LCP |

vpp needs 4 GB Memory, an IOMMU and NICs that
can bind to vfio-pci, and uses Debian 12 because fd.io publishes no trixie
packages.

## Install

Boot the installer ISO from USB or virtual media and pick the VGA or serial
(115200 8N1) entry.

Unattended, via kernel command line:

```
appliance.installer=1 appliance.autoinstall=1 appliance.target=/dev/sda
```

Or write the image directly:

```
zstd -d frr-appliance-vanilla-amd64.img.zst
dd if=frr-appliance-vanilla-amd64.img of=/dev/sdX bs=4M conv=fsync status=progress
```

## First boot

Setup asks for a hostname, a password for the `admin` account, and whether to
install security updates automatically. SSH does not work until it has run, since
the account has no password before that.

Later logins go to vtysh. `exit` drops to a shell. `admin` has sudo, and
`appliance-info` shows the Debian and FRR versions.

## Configuration

Routing in vtysh, saved with `write memory`. Extra firewall rules go in
`/etc/nftables.d/`.

FRR is pinned to 10.4.x, so `apt upgrade` brings patch releases only. A newer FRR
needs a new image.

## Backup

```
ssh admin@router sudo appliance-backup > router.tgz
ssh admin@router sudo appliance-restore < router.tgz
```

Covers FRR, `/etc/nftables.d`, hostname, resolver, chrony, snmpd and the vpp
interface settings. Not the admin password or the SSH host keys.

To upgrade: install the new image, run through setup, restore.

## Hardening

- Secure Boot with signed shim and GRUB
- AppArmor
- auditd, with rules for configuration, account and privilege changes
- SSH restricted to `admin`, no root login, no empty passwords, rate limited
- Passwords: 12 characters, 3 character classes, cracklib checked
- `/tmp` on tmpfs, `nosuid`, `nodev`
- No ICMP redirects or source routing, no unprivileged BPF, restricted `dmesg`,
  `kptr`, `ptrace`
- `snmpd` installed but disabled
- CycloneDX SBOM, build manifest and SLSA provenance, Sigstore signed

## Settings

`/etc/appliance/vpp-dpdk.conf`, vpp variant:

| Setting | Default | Effect |
| --- | --- | --- |
| `MODE` | `all` | `all` binds every PCI NIC to DPDK, any other value binds none |
| `IOMMU_REQUIRED` | `1` | Skip NICs when no IOMMU is present |
| `EXCLUDE_IFACES` | empty | Interface names to keep under Linux |
| `EXCLUDE_PCI` | empty | PCI addresses to keep under Linux |
| `HUGEPAGES_MB` | `512` | Hugepages to reserve, once a NIC is bound |

## Build

Needs a privileged Linux host, plus `shellcheck` for `make lint`.

```
make lint
make build-vanilla
make build-vpp
```

Artifacts land in `out/`: installer ISO, raw image, qcow2, checksums and
signatures. `.gitlab-ci.yml` and `.github/workflows/appliance.yml` run the same
scripts.
