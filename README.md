# DayShield Firewall RootFS

Deterministic, reproducible Debian-based root filesystem builder for the
**DayShield Firewall**. The output is a `rootfs.tar.zst` archive suitable
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
|   |-- harden-ipv4.sh           # IPv4-first hardening defaults
|   |-- cleanup.sh               # Strip non-reproducible artifacts
|   `-- verify.sh                # Verify rootfs integrity
|-- config/
|   |-- packages.txt             # Deterministic package list
|   |-- services/
|   |   |-- unbound.service
|   |   |-- nftables.service
|   |   |-- suricata.service
|   |   |-- crowdsec.service
|   |   |-- cloudflared.service
|   |   |
|   |   |-- wireguard.service
|   |   |-- dayshield-disable-offloads.service
|   |   |-- acme.service
|   |   |-- acme.timer
|   |   `-- console-wizard.service
|   |-- sysctl.conf              # Kernel hardening parameters
|   |-- nftables.conf            # IPv4-first default firewall ruleset
|   |-- unbound.conf             # Local recursive DNS resolver
|   |-- suricata.yaml            # Intrusion Detection System config
|   |-- crowdsec.yaml            # CrowdSec security engine config
|   `-- dayshield/
|       |-- config/              # DayShield runtime config skeleton
|       |-- certs/               # TLS certificate placeholder
|       `-- installer-finalize.sh # Shared installer post-install finalization
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
apt-get install mmdebstrap zstd systemd-container
```

---

## Building the RootFS

The normal production path is GitHub Actions for this repository. `dayshield-core`,
`dayshield-ui`, and `dayshield-rootfs` now use independent tags/versions.
Local rootfs builds are still useful for development, debugging, and installer work.

Always build the management UI first, then pass its output to the rootfs builder:

```sh
cd ../dayshield-ui
npm install
npm run build

cd ../dayshield-rootfs
make rootfs UI_DIR=../dayshield-ui/dist
```

Custom parameters:

```sh
make rootfs UI_DIR=../dayshield-ui/dist ARCH=arm64 SUITE=trixie OUTPUT=dayshield-arm64.tar.zst
```

Or invoke the script directly:

```sh
./scripts/build-rootfs.sh \
    --arch amd64 \
    --suite trixie \
    --output rootfs.tar.zst \
    --mirror https://deb.debian.org/debian \
   --ui-dir ../dayshield-ui/dist \
   --core-repo-dir ../dayshield-core \
   --ui-repo-dir ../dayshield-ui \
   --rootfs-repo-dir ../dayshield-rootfs
```

The build pipeline:

1. **mmdebstrap** bootstraps a minimal Debian `trixie` root with the
   packages listed in `config/packages.txt`. The build directory is made
   traversable for the `_apt` sandbox user so package downloads stay within
   APT's default privilege boundary.
2. **chroot-setup.sh** sets the hostname, writes a placeholder `/etc/fstab`,
   creates the DayShield directory tree, installs all config files, and
   configures systemd-networkd (matching both legacy `eth0` and predictable
   `en*` interface names). It also installs the shared installer finalization
   script at `/usr/local/lib/dayshield/installer-finalize.sh`.
3. **install-dayshield-core.sh** installs the `dayshield-core` binary and its
   systemd unit, with an installer-live guard
   (`ConditionKernelCommandLine=!installer`) so it only starts on
   installed-system boot. The build now fails fast if the binary is absent.
   The installed appliance update path is registry/manifest-based: it downloads
   prebuilt `core`, `ui`, and `rootfs` artifacts referenced by a central
   registry manifest instead of building on the appliance.
4. **enable-services.sh** creates `wants/` symlinks for all required services
   and masks `systemd-resolved` (replaced by unbound).
5. **harden-ipv4.sh** keeps IPv6 disabled by default through sysctl and service
   config while leaving the kernel module and localhost entries available for
   the DayShield global IPv6 toggle.
   The initramfs is then (re)generated via `update-initramfs` with proc/dev/sys
   bind-mounted into the chroot so module dependency resolution succeeds.
6. **cleanup.sh** removes APT caches, clears `machine-id`, removes any
   live-boot artifacts, zeroes logs, and normalises all timestamps to epoch 0
   for reproducibility.
7. The finished tree is archived with `tar --sort=name --mtime=@0` and
   compressed with `zstd -19` to produce the final `rootfs.tar.zst`.

### Providing the `dayshield-core` binary (required)

Place the compiled binary at the repository root before building:

```sh
cp /path/to/dayshield-core ./dayshield-core
make rootfs
```

If the binary is absent, the build fails with an explicit error.

### Providing the Management UI (required)

The management UI is a required component. Always build it before building
the rootfs and pass its `dist` directory via `UI_DIR`:

```sh
cd ../dayshield-ui
npm install
npm run build

cd ../dayshield-rootfs
make rootfs UI_DIR=../dayshield-ui/dist
```

This copies the UI output into `/usr/local/share/dayshield-ui` inside the
rootfs, which is the path expected by `dayshield-core`.

> **Warning:** If `UI_DIR` is omitted (or invalid), the build fails.

The installed management UI is served by `dayshield-core`. In this rootfs, the
`dayshield-core` service is configured with `DAYSHIELD_PORT=8443`, so the
management UI/API are exposed on port `8443` by default. (The core binary
itself also defaults to port `8443` when no service override is set.)

### Repo seed paths for updater (recommended)

`build-rootfs.sh` can seed local git clones into `/opt/dayshield-core`,
`/opt/dayshield-ui`, and `/opt/dayshield-rootfs` for updater compatibility.
When running in the standard sibling-repo layout, these are auto-detected.

If your repos are not siblings, pass explicit paths:

```sh
make rootfs \
   UI_DIR=../dayshield-ui/dist \
   CORE_REPO_DIR=/path/to/dayshield-core \
   UI_REPO_DIR=/path/to/dayshield-ui \
   ROOTFS_REPO_DIR=/path/to/dayshield-rootfs
```

## Releases

Rootfs releases are independent from `dayshield-core` and `dayshield-ui`
releases. This repository publishes its own rootfs artifacts from its own
tags/versions.

The updater resolves latest installable artifacts per component (`core`, `ui`,
`rootfs`) from a central registry manifest. Component versions are not required
to match each other.

Rootfs remains an image/staging artifact for installer and ISO workflows.
Runtime update checks for `core`/`ui` still consume their own component entries
from the same manifest and do not require a new rootfs tag for every core/ui
release.

### Build/release inputs

Rootfs build inputs remain:

- this repo's filesystem/config/scripts
- a built `dayshield-core` binary copied to this repo root as `./dayshield-core`
- a built `dayshield-ui/dist` passed via `UI_DIR`
- optional repo seed paths (`CORE_REPO_DIR`, `UI_REPO_DIR`, `ROOTFS_REPO_DIR`)

Releasing rootfs publishes a rootfs artifact for the rootfs tag/version; it
does not imply synchronized version bumps in `dayshield-core` or
`dayshield-ui`.

### Installer finalization contract (console + web)

Both installer entry points must use the same post-install finalization script:

- Path: `/usr/local/lib/dayshield/installer-finalize.sh`
- Purpose: write installed-system credentials + network config into the mounted
  target rootfs (including root password lock/update in target `/etc/shadow`).
- Validation criteria enforced by the script:
  - root password entry in target `/etc/shadow` must change from the pre-finalize state
  - no installer-live listener on TCP port `8443`
  - installed target must include `dayshield.service` guard
    (`ConditionKernelCommandLine=!installer`) so service startup is deferred to
    installed-system boot

The console installer already calls this path, and the web installer must call
the same script with equivalent inputs.

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
- IPv6 is disabled by default without kernel/module boot hard-disables
- `nftables.conf` contains no static `ip6`/`inet6` tables until the core enables IPv6
- `unbound.conf` has `do-ip6: no` by default
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
| IPv6 default-off | Reduces default attack surface while preserving runtime IPv6 support through the global DayShield setting |
| `unbound` instead of `systemd-resolved` | Full DNSSEC, local recursion, no stub-listener conflicts |
| `nftables` instead of `iptables` | Modern, performant, supported by Debian trixie |
| `tar --sort=name --mtime=@0` | Byte-for-byte reproducible archives across builds |
| Timestamps normalised to epoch 0 | Eliminates build-time variation from file metadata |
| Cleared `machine-id` | Forces unique ID generation on first boot |
| `live-boot`/`live-config` excluded from base rootfs | Prevents live initramfs hooks from stalling the installed-system boot; injected by `dayshield-iso` as a separate layer for squashfs-live operation only |
| Placeholder `/etc/fstab` | `systemd-remount-fs.service` and `local-fs.target` require a valid fstab; installer overwrites with real UUID entries |
| Two networkd configs (`eth0` + `en*`) | Covers both legacy QEMU/KVM interface names and predictable udev names used by modern kernels; without the `en*` config `systemd-networkd-wait-online` stalls forever on physical hardware |
