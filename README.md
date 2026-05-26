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
- `ostree` (host-side OSTree commit/repo compose)
- GNU `tar`
- `systemd-container` / `systemd-nspawn` (optional)

Install on Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install mmdebstrap zstd ostree systemd-container
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

By default this now produces two artifacts:

- `rootfs.tar.zst` (rootfs archive)
- `rootfs-ostree-repo.tar.zst` (archived OSTree repository containing the composed commit)

### Custom options

```sh
make rootfs UI_DIR=../dayshield-ui/dist ARCH=arm64 SUITE=trixie \
  OUTPUT=dayshield-arm64.tar.zst \
  OSTREE_REF=dayshield/arm64
```

## Inputs

- `UI_DIR` must point to built frontend output, usually `../dayshield-ui/dist`
- A built `dayshield-core` binary is required for the rootfs build
- Missing inputs cause the build to fail clearly

## OSTree architecture (initial slice)

The rootfs build now composes an OSTree commit and repository artifact on the build host.
This is the first step toward immutable image-based updates driven by OSTree deployments.

### Build-time outputs

- Rootfs archive for installer/ISO integration (`*.tar.zst`)
- OSTree repository archive (`*-ostree-repo.tar.zst`) containing:
  - the composed commit for `OSTREE_REF`
  - repository metadata (`summary`)

### Runtime layout assumptions

- Managed OS tree is deployed via OSTree (`/sysroot` + `/ostree`)
- Persistent writable state is expected under `/var`
- DayShield app writable data remains under `/var/lib/dayshield` and `/var/log/dayshield`

### Update/boot assumptions

- OSTree remote stub is installed at `/etc/ostree/remotes.d/dayshield.conf`
- Initial helper exists at `/usr/local/lib/dayshield/ostree-update.sh`
  - `status`, `check`, `stage`, `rollback`
- Installer/ISO workflows are expected to finalize target partition labels/UUIDs and
  set the correct OSTree ref/remote URL for production environments.

### Local validation

```sh
# Verify extracted rootfs layout
make verify ROOTFS_DIR=/path/to/extracted/rootfs

# Inspect composed OSTree commit
mkdir -p /tmp/dayshield-ostree
tar --zstd -xf rootfs-ostree-repo.tar.zst -C /tmp/dayshield-ostree
ostree --repo=/tmp/dayshield-ostree refs
ostree --repo=/tmp/dayshield-ostree log dayshield/amd64
```

Replace `amd64` with your target architecture when using a non-amd64 build/ref.

## Notes

- This repo is focused on root filesystem assembly and packaging.
- The rootfs and OSTree artifacts are consumed by installer and ISO workflows.
- UI and backend runtime sources live in separate repositories.
