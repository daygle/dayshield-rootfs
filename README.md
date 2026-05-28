# DayShield RootFS

`dayshield-rootfs` builds the DayShield appliance root filesystem and publishes
versioned rootfs artifacts for installer, ISO, and system-update flows.

## What this repo contains

- deterministic Debian rootfs build scripts
- package, service, and runtime configuration for the appliance image
- installation of `dayshield-core`, built UI assets, and DayShield helper hooks
- versioned rootfs archive, immutable squashfs image, and release manifest output

## Update model

DayShield is migrating away from OSTree-based rootfs deployment to a seamless
image-based update flow:

- users see versions and update status, not slots or A/B terminology
- `dayshield-rootfs` publishes versioned rootfs artifacts to GitHub releases
- a release manifest describes the archive and immutable rootfs image for a
  specific rootfs version
- updater/boot logic in other DayShield repos can stage the squashfs image and
  hand off to initramfs for verified boot into the next rootfs version

The running system keeps version discoverability via `/etc/dayshield/version`
and `/usr/local/share/dayshield-updates/rootfs-image-layout.json`.

## Requirements

- `mmdebstrap` >= 0.8.4
- `zstd` >= 1.4
- GNU `tar`
- `squashfs-tools`
- `git` (optional; required only to seed source repos under `/opt` and to derive
  `SOURCE_DATE_EPOCH`)

On Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install mmdebstrap zstd tar squashfs-tools git
```

## Build

The rootfs build is primarily produced by CI, but local builds are supported for
development and debugging.

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

3. Build the rootfs artifacts:

```sh
cd ../dayshield-rootfs
sudo make rootfs UI_DIR=../dayshield-ui/dist
```

If `git` is available and the current rootfs repository is a git repo, the build
automatically derives `SOURCE_DATE_EPOCH` from the latest commit timestamp.

### Required inputs

- `UI_DIR` must point to a built UI output directory containing `index.html`
- `dayshield-core` must exist as `dayshield-core` in the `dayshield-rootfs`
  repository root
- `ROOTFS_REPO_DIR` is auto-detected from the current repo if it contains `.git`

### Optional repo seeding

The build can optionally seed source repositories inside the rootfs image:

- `CORE_REPO_DIR` seeds `/opt/dayshield-core`
- `UI_REPO_DIR` seeds `/opt/dayshield-ui`
- `ROOTFS_REPO_DIR` seeds `/opt/dayshield-rootfs`

These paths are not required for the runtime image, but they are used to
populate packaged repository metadata when provided.

### Example custom build

```sh
sudo make rootfs UI_DIR=../dayshield-ui/dist ARCH=arm64 SUITE=trixie \
  OUTPUT=rootfs-v1.2.3.tar.zst \
  ROOTFS_IMAGE_OUTPUT=rootfs-v1.2.3.squashfs \
  ROOTFS_MANIFEST_OUTPUT=rootfs-v1.2.3-manifest.json
```

## Outputs

By default, the build produces:

- `rootfs.tar.zst`: packaged root filesystem archive used by installer/ISO flows
- `rootfs.squashfs`: immutable rootfs image for initramfs-driven system updates
- `rootfs-manifest.json`: machine-readable metadata describing the version,
  archive/image artifact names, and update strategy

The rootfs archive also embeds
`/usr/local/share/dayshield-updates/rootfs-image-layout.json` so other DayShield
components know the expected on-device image-store layout.

## GitHub versioning and consumption

Core, UI, and rootfs versions are pulled from GitHub independently.

- `dayshield-core` and `dayshield-ui` release versions are resolved in CI
- `dayshield-rootfs` publishes its own versioned release artifacts
- the release manifest is the contract another repo can consume to discover the
  correct rootfs archive and squashfs image for a given rootfs version

Recommended updater behavior:

1. Read current rootfs version from `/etc/dayshield/version`
2. Fetch the latest rootfs release manifest from GitHub
3. Compare the running version with the manifest `version`
4. Download and verify the squashfs artifact referenced by the manifest
5. Stage it for the initramfs/boot flow without exposing internal redundancy to
   the user

## Verification

```sh
make verify ROOTFS_DIR=/path/to/extracted/rootfs
```

The verification target checks boot artifacts, required directories, systemd
units, image-update layout, and bundled update tooling.

## Integration notes

- This repository assembles the appliance runtime rootfs; it does not itself
  build the backend or frontend sources.
- The rootfs archive remains the installer/ISO input during the migration.
- The squashfs image and release manifest are the foundation for the new
  GitHub-hosted, initramfs-driven rootfs update path.
- Follow-up work in `dayshield-iso`/boot logic and `dayshield-core` will consume
  the manifest and stage the published rootfs image for seamless system updates.
