# DayShield RootFS

Deterministic, reproducible Debian-based root filesystem builder for the
**DayShield Firewall OS**. The output is a `rootfs.tar.zst` archive suitable
for direct injection into the `dayshield-iso` build pipeline.

---

## Contents

```
.
|-- scripts/
|   |-- build-rootfs.sh          # Main entrypoint - mmdebstrap pipeline
|   |-- chroot-setup.sh          # Configure chroot environment
|   |-- install-dayshield-core.sh# Install dayshield-core binary & service
|   |-- enable-services.sh       # Enable systemd services
|   |-- harden-ipv4.sh           # IPv4-only hardening
|   |-- cleanup.sh               # Strip non-reproducible artifacts
|   `-- verify.sh                # Verify rootfs integrity
|-- config/
|   |-- packages.txt             # Deterministic package list (includes live-boot)
|   |-- services/
|   |   |-- unbound.service
|   |   |-- nftables.service
|   |   |-- suricata.service
|   |   |-- crowdsec.service
|   |   |-- wireguard.service
|   |   `-- acme.service
|   |-- sysctl.conf              # Kernel hardening parameters
|   |-- nftables.conf            # IPv4-only firewall ruleset
|   |-- unbound.conf             # Local recursive DNS resolver
|   |-- suricata.yaml            # Intrusion Detection System config
|   |-- crowdsec.yaml            # CrowdSec security engine config
|   `-- dayshield/
|       |-- config/              # DayShield runtime config skeleton
|       `-- certs/               # TLS certificate placeholder
|-- Makefile
`-- README.md
```

---

## Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| `mmdebstrap` | >= 0.8.4 | Bootstrap deterministic Debian root filesystem |
| `zstd` | >= 1.4 | Compress rootfs archive |
| `tar` | GNU tar | Create deterministic archive |
| `systemd-nspawn` | >= 247 | (optional) Test rootfs in a container |

Install on Debian/Ubuntu:

```sh
sudo apt-get install mmdebstrap zstd systemd-container
```

---

## Building the RootFS

```sh
# Default: amd64, trixie, output rootfs.tar.zst
make rootfs

# Custom parameters
make rootfs ARCH=arm64 SUITE=trixie OUTPUT=dayshield-arm64.tar.zst

# Or invoke the script directly
./scripts/build-rootfs.sh \
    --arch amd64 \
    --suite trixie \
    --output rootfs.tar.zst \
    --mirror http://deb.debian.org/debian
```

The build pipeline:

1. **mmdebstrap** bootstraps a minimal Debian `trixie` root with the
   packages listed in `config/packages.txt`.  APT sandboxing is explicitly set
   to `root` during this step to avoid `_apt` permission warnings in temporary
   build directories.
2. **chroot-setup.sh** sets the hostname, writes a placeholder `/etc/fstab`,
   creates the DayShield directory tree, installs all config files, and
   configures systemd-networkd (matching both legacy `eth0` and predictable
   `en*` interface names).
3. **install-dayshield-core.sh** installs the `dayshield-core` binary (or a
   placeholder if the binary is absent) and its systemd unit.
4. **enable-services.sh** creates `wants/` symlinks for all required services
   and masks `systemd-resolved` (replaced by unbound).
5. **harden-ipv4.sh** disables IPv6 at every layer: sysctl, kernel module
   blacklist, `/etc/hosts`, `/etc/resolv.conf`, nftables, and unbound.
   The initramfs is then (re)generated via `update-initramfs` with proc/dev/sys
   bind-mounted into the chroot so module dependency resolution succeeds.
6. **cleanup.sh** removes APT caches, clears `machine-id`, removes any
   live-boot artifacts, zeroes logs, and normalises all timestamps to epoch 0
   for reproducibility.
7. The finished tree is archived with `tar --sort=name --mtime=@0` and
   compressed with `zstd -19` to produce the final `rootfs.tar.zst`.

### Providing the `dayshield-core` binary

Place the compiled binary at the repository root before building:

```sh
cp /path/to/dayshield-core ./dayshield-core
make rootfs
```

If the binary is absent, a shell placeholder is written to
`/usr/local/sbin/dayshield-core`. The placeholder exits with an error at
runtime - replace it before deploying.

---

## Verifying the RootFS

Extract the archive and run the verification script:

```sh
mkdir -p /tmp/dayshield-rootfs-test
tar -I zstd -xf rootfs.tar.zst -C /tmp/dayshield-rootfs-test

make verify ROOTFS_DIR=/tmp/dayshield-rootfs-test
# or
ROOTFS_DIR=/tmp/dayshield-rootfs-test ./scripts/verify.sh
```

The script checks:

- All required directories exist
- All required systemd service units are present
- `dayshield-core` binary exists and is executable
- Kernel image (`vmlinuz-*`) and initramfs (`initrd.img-*`) are present in `/boot`
- `/etc/fstab` exists and contains a root (`/`) mount entry
- `live-boot` and `live-config` are **not** installed (they must not be in the installed rootfs)
- IPv6 is fully disabled (sysctl, module blacklist, `/etc/hosts`)
- `nftables.conf` contains no `ip6`/`inet6` tables
- `unbound.conf` has `do-ip6: no`
- Config files for suricata and crowdsec are present

Exit code 0 = all checks passed.

---

## Testing in a Container

```sh
sudo systemd-nspawn \
    --directory /tmp/dayshield-rootfs-test \
    --boot \
    --capability=CAP_NET_ADMIN,CAP_NET_RAW
```

---

## Integrating with dayshield-iso

The ISO builder expects the rootfs archive at a configurable path.  Pass it
via the `ROOTFS` variable (or equivalent) in the ISO build configuration:

```sh
make -C ../dayshield-iso iso ROOTFS=$(pwd)/rootfs.tar.zst
```

> **Important - live-boot overlay:** `live-boot` and `live-config` are **not**
> included in `rootfs.tar.zst`.  Embedding them in the base rootfs causes their
> initramfs hooks to run on the installed system, where they stall boot waiting
> for a squashfs live medium.  The `dayshield-iso` pipeline must install
> `live-boot`, `live-config`, and `squashfs-tools` as an additional layer on
> top of the extracted rootfs before building the squashfs image, e.g.:
>
> ```sh
> # After extracting rootfs.tar.zst into ${SQUASHFS_ROOT}:
> apt-get -o Dir="${SQUASHFS_ROOT}" install -y live-boot live-config squashfs-tools
> # …then mksquashfs ${SQUASHFS_ROOT} filesystem.squashfs
> ```

---

## Design decisions

| Decision | Rationale |
|----------|-----------|
| `mmdebstrap` instead of `debootstrap` | Runs unprivileged; produces more reproducible output |
| IPv4-only | Reduces attack surface; all services bind only to `127.0.0.1` or IPv4 |
| `unbound` instead of `systemd-resolved` | Full DNSSEC, local recursion, no stub-listener conflicts |
| `nftables` instead of `iptables` | Modern, performant, supported by Debian trixie |
| `tar --sort=name --mtime=@0` | Byte-for-byte reproducible archives across builds |
| Timestamps normalised to epoch 0 | Eliminates build-time variation from file metadata |
| Cleared `machine-id` | Forces unique ID generation on first boot |
| `live-boot`/`live-config` excluded from base rootfs | Prevents live initramfs hooks from stalling the installed-system boot; injected by `dayshield-iso` as a separate layer for squashfs-live operation only |
| Placeholder `/etc/fstab` | `systemd-remount-fs.service` and `local-fs.target` require a valid fstab; installer overwrites with real UUID entries |
| Two networkd configs (`eth0` + `en*`) | Covers both legacy QEMU/KVM interface names and predictable udev names used by modern kernels; without the `en*` config `systemd-networkd-wait-online` stalls forever on physical hardware |
