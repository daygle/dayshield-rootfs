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

## Notes

- This repo is focused on root filesystem assembly and packaging.
- The final archive is consumed by installer and ISO workflows.
- UI and backend runtime sources live in separate repositories.
