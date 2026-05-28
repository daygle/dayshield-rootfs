# DayShield RootFS

`dayshield-rootfs` builds the appliance root filesystem archive used by DayShield installers and ISO images.

## What this repo contains

- deterministic Debian rootfs build scripts
- package, service, and runtime configuration for the appliance image
- installation of `dayshield-core` binary, built UI assets, and updater tooling
- packaging of rootfs and OSTree artifacts consumed by installer/ISO workflows

## Requirements

- `mmdebstrap` >= 0.8.4
- `zstd` >= 1.4
- GNU `tar`
- `ostree` (required when OSTree compose is enabled, default: enabled)
- `git` (optional; required only to seed source repos under `/opt` and to derive `SOURCE_DATE_EPOCH`)

On Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install mmdebstrap zstd tar ostree git
```

## Build

The rootfs build is primarily produced by CI, but local builds are supported for development and debugging.

### Local build steps

1. Build the UI assets:

```sh
cd ../dayshield-ui
npm install
npm run build
```

2. Build the DayShield core binary and place it in the rootfs repo root:

```sh
cd ../dayshield-core
cargo build --release
cp target/release/dayshield-core ../dayshield-rootfs/
```

3. Build the rootfs archive:

```sh
cd ../dayshield-rootfs
make rootfs UI_DIR=../dayshield-ui/dist
```

If `git` is available and the current rootfs repository is a git repo, the build will automatically derive `SOURCE_DATE_EPOCH` from the latest commit timestamp.

### Required inputs

- `UI_DIR` must point to a built UI output directory containing `index.html`
- `dayshield-core` must exist as `dayshield-core` in the `dayshield-rootfs` repository root
- `ROOTFS_REPO_DIR` is auto-detected from the current repo if it contains `.git`

### Optional repo seeding

The build can optionally seed source repositories inside the rootfs image:

- `CORE_REPO_DIR` seeds `/opt/dayshield-core`
- `UI_REPO_DIR` seeds `/opt/dayshield-ui`
- `ROOTFS_REPO_DIR` seeds `/opt/dayshield-rootfs`

These paths are not required for the runtime image, but they are used to populate the packaged repository metadata when provided.

### Example custom build

```sh
make rootfs UI_DIR=../dayshield-ui/dist ARCH=arm64 SUITE=trixie \
  OUTPUT=dayshield-arm64.tar.zst OSTREE_REF=dayshield/arm64
```

## Outputs

By default, the build produces:

- `rootfs.tar.zst`: the packaged root filesystem archive
- `rootfs-ostree-repo.tar.zst`: the host-side OSTree repository archive containing the composed commit

If OSTree compose is disabled with `ENABLE_OSTREE_COMPOSE=0` or `--disable-ostree-compose`, only `rootfs.tar.zst` is produced.

## Rootfs and OSTree behavior

- The build installs UI assets under `/usr/local/share/dayshield-ui`
- `dayshield-core` is installed to `/usr/local/sbin/dayshield-core`
- OSTree tooling and update helper are installed in the rootfs
- The build writes a version marker to `/etc/dayshield/version`
- When OSTree compose is enabled, the rootfs image also contains an OSTree repo at `/ostree/repo` and `/sysroot/ostree/repo`

## Verification

```sh
make verify ROOTFS_DIR=/path/to/extracted/rootfs
```

The verification target checks boot artifacts, required directories, systemd units, OSTree layout, and update tooling.

## Notes

- This repository assembles the appliance runtime rootfs; it does not itself build the backend or frontend sources.
- The rootfs archive is consumed by installer and ISO pipelines under `dayshield-installer-ui` and `dayshield-iso`.
