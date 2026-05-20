# DayShield RootFS

`dayshield-rootfs` builds the appliance root filesystem archive used by DayShield installers and ISO images.

## What this repo contains

- deterministic Debian rootfs build scripts
- package and service configuration for the appliance runtime
- packaging of the `dayshield-core` backend and built UI assets
- output archive for installer/ISO pipeline consumption

## Requirements

- `mmdebstrap` >= 0.8.4
- `zstd` >= 1.4
- GNU `tar`
- `systemd-container` / `systemd-nspawn` (optional)

Install on Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install mmdebstrap zstd systemd-container
```

## Build

The rootfs build is primarily produced by GitHub Actions. Local builds are supported for development and debugging.

### Build steps

1. Build the UI assets:

```sh
cd ../dayshield-ui
npm install
npm run build
```

2. Build the rootfs archive:

```sh
cd ../dayshield-rootfs
make rootfs UI_DIR=../dayshield-ui/dist
```

### Custom options

```sh
make rootfs UI_DIR=../dayshield-ui/dist ARCH=arm64 SUITE=trixie OUTPUT=dayshield-arm64.tar.zst
```

## Inputs

- `UI_DIR` must point to built frontend output, usually `../dayshield-ui/dist`
- A built `dayshield-core` binary is required for the rootfs build
- Missing inputs cause the build to fail clearly

## Release model

`dayshield-rootfs` is released independently from `dayshield-core` and `dayshield-ui`.
Release artifacts are versioned by this repo and consumed by the appliance update manifest.

## Notes

- This repo is focused on root filesystem assembly and packaging.
- The final archive is consumed by installer and ISO workflows.
- UI and backend runtime sources live in separate repositories.

## Contributing

Validate changes by running the rootfs build flow and confirming the generated archive is usable in the appliance pipeline.

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
