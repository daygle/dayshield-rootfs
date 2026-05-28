#!/bin/sh
# build-rootfs.sh - Main entrypoint for the DayShield RootFS builder.
# Produces a deterministic, reproducible Debian-based root filesystem.
# POSIX shell compatible.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_DIR}/config"

# Defaults
ARCH="amd64"
SUITE="trixie"
OUTPUT="rootfs.tar.zst"
MIRROR="https://deb.debian.org/debian"
SECURITY_MIRROR="https://deb.debian.org/debian-security"
ENABLE_SUITE_UPDATES="1"
ROOTFS_IMAGE_OUTPUT=""
ROOTFS_MANIFEST_OUTPUT=""
UI_DIR=""
CORE_REPO_DIR=""
UI_REPO_DIR=""
ROOTFS_REPO_DIR=""
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --arch ARCH       Target architecture (default: amd64)
  --suite SUITE     Debian suite (default: trixie)
  --output FILE     Output file (default: rootfs.tar.zst)
  --mirror URL      Debian mirror URL (default: https://deb.debian.org/debian)
    --security-mirror URL
                                        Debian security mirror URL (default: https://deb.debian.org/debian-security)
    --enable-suite-updates
                        Include SUITE-updates source for stable-style suites (default: enabled)
    --image-output FILE
                        Output file for the immutable squashfs rootfs image
                        (default: <output>.squashfs)
    --manifest-output FILE
                        Output file for the rootfs release manifest JSON
                        (default: <output>-manifest.json)
    --source-date-epoch EPOCH
                        Explicit SOURCE_DATE_EPOCH for reproducible builds
  --ui-dir PATH     Built UI output directory to install into /usr/local/share/dayshield-ui (required)
    --core-repo-dir PATH   Core git repo to seed into /opt/dayshield-core
    --ui-repo-dir PATH     UI git repo to seed into /opt/dayshield-ui
    --rootfs-repo-dir PATH RootFS git repo to seed into /opt/dayshield-rootfs
  --help            Show this help message
EOF
    exit 0
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --arch|--suite|--output|--mirror|--security-mirror|--ui-dir|--core-repo-dir|--ui-repo-dir|--rootfs-repo-dir|--image-output|--manifest-output|--source-date-epoch)
            if [ $# -lt 2 ] || [ -z "${2}" ] || [ "${2#--}" != "${2}" ]; then
                printf 'ERROR: option %s requires a value\n' "$1" >&2
                exit 1
            fi
            case "$1" in
                --arch) ARCH="$2" ;;
                --suite) SUITE="$2" ;;
                --output) OUTPUT="$2" ;;
                --mirror) MIRROR="$2" ;;
                --security-mirror) SECURITY_MIRROR="$2" ;;
                --image-output) ROOTFS_IMAGE_OUTPUT="$2" ;;
                --manifest-output) ROOTFS_MANIFEST_OUTPUT="$2" ;;
                --source-date-epoch) SOURCE_DATE_EPOCH="$2" ;;
                --ui-dir) UI_DIR="$2" ;;
                --core-repo-dir) CORE_REPO_DIR="$2" ;;
                --ui-repo-dir) UI_REPO_DIR="$2" ;;
                --rootfs-repo-dir) ROOTFS_REPO_DIR="$2" ;;
            esac
            shift 2
            ;;
        --enable-suite-updates)
            ENABLE_SUITE_UPDATES="1"
            shift
            ;;
        --help)    usage ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage
            ;;
    esac
done

# Auto-detect sibling repos when explicit paths were not provided.
if [ -z "${CORE_REPO_DIR}" ] && [ -d "${REPO_DIR}/../dayshield-core/.git" ]; then
    CORE_REPO_DIR="${REPO_DIR}/../dayshield-core"
fi
if [ -z "${UI_REPO_DIR}" ] && [ -d "${REPO_DIR}/../dayshield-ui/.git" ]; then
    UI_REPO_DIR="${REPO_DIR}/../dayshield-ui"
fi
if [ -z "${ROOTFS_REPO_DIR}" ] && [ -d "${REPO_DIR}/.git" ]; then
    ROOTFS_REPO_DIR="${REPO_DIR}"
fi

if [ -z "${SOURCE_DATE_EPOCH}" ] && command -v git >/dev/null 2>&1 && [ -n "${ROOTFS_REPO_DIR}" ]; then
    if SOURCE_DATE_EPOCH="$(git -C "${ROOTFS_REPO_DIR}" log -1 --format=%ct 2>/dev/null)"; then
        :
    else
        SOURCE_DATE_EPOCH=""
    fi
fi
if [ -z "${SOURCE_DATE_EPOCH}" ]; then
    printf 'ERROR: SOURCE_DATE_EPOCH not provided and git timestamp unavailable; set SOURCE_DATE_EPOCH or pass --source-date-epoch\n' >&2
    exit 1
fi
export DEBIAN_FRONTEND=noninteractive

case "${SOURCE_DATE_EPOCH}" in
    *[!0-9]*)
        printf 'ERROR: SOURCE_DATE_EPOCH must be an integer epoch timestamp\n' >&2
        exit 1
        ;;
esac

if SOURCE_DATE_UTC="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    :
else
    printf 'ERROR: failed to convert SOURCE_DATE_EPOCH to UTC timestamp: %s\n' "${SOURCE_DATE_EPOCH}" >&2
    exit 1
fi

# Validate required inputs
if [ -z "${UI_DIR}" ]; then
    printf 'ERROR: --ui-dir <path-to-dayshield-ui-dist> is required\n' >&2
    exit 1
fi
if [ ! -d "${UI_DIR}" ]; then
    printf 'ERROR: UI build directory not found: %s\n' "${UI_DIR}" >&2
    exit 1
fi
if [ ! -f "${UI_DIR}/index.html" ]; then
    printf 'ERROR: UI build directory does not look like a Vite dist output: %s\n' "${UI_DIR}" >&2
    exit 1
fi

if [ -n "${CORE_REPO_DIR}" ] && [ ! -d "${CORE_REPO_DIR}/.git" ]; then
    printf 'ERROR: core repo path is not a git repo: %s\n' "${CORE_REPO_DIR}" >&2
    exit 1
fi
if [ -n "${UI_REPO_DIR}" ] && [ ! -d "${UI_REPO_DIR}/.git" ]; then
    printf 'ERROR: UI repo path is not a git repo: %s\n' "${UI_REPO_DIR}" >&2
    exit 1
fi
if [ -n "${ROOTFS_REPO_DIR}" ] && [ ! -d "${ROOTFS_REPO_DIR}/.git" ]; then
    printf 'ERROR: rootfs repo path is not a git repo: %s\n' "${ROOTFS_REPO_DIR}" >&2
    exit 1
fi

# All listed host tools are mandatory for the current build contract. The
# archive remains the installer/ISO input, and every build now also emits the
# immutable squashfs image plus release manifest used by the image-update flow.
for tool in mmdebstrap zstd tar mksquashfs sha256sum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool not found: %s\n' "${tool}" >&2
        exit 1
    fi
done

# Validate dayshield-core binary and repo paths before starting any build work.
if [ ! -f "${REPO_DIR}/dayshield-core" ]; then
    printf 'ERROR: missing dayshield-core binary at %s/dayshield-core\n' "${REPO_DIR}" >&2
    printf '       Build dayshield-core and copy target/release/dayshield-core there before running rootfs build.\n' >&2
    exit 1
fi
if [ -z "${CORE_REPO_DIR}" ]; then
    printf 'WARNING: core repo path not provided; /opt/dayshield-core repo seeding will be skipped\n' >&2
fi
if [ -z "${UI_REPO_DIR}" ]; then
    printf 'WARNING: UI repo path not provided; /opt/dayshield-ui repo seeding will be skipped\n' >&2
fi
if [ -z "${ROOTFS_REPO_DIR}" ]; then
    printf 'ERROR: rootfs repo path not provided and current repo git metadata was not found\n' >&2
    printf '       Pass --rootfs-repo-dir <path-to-dayshield-rootfs>\n' >&2
    exit 1
fi

# Load package list (strip comments and blank lines)
PACKAGES_FILE="${CONFIG_DIR}/packages.txt"
if [ ! -f "${PACKAGES_FILE}" ]; then
    printf 'ERROR: package list not found: %s\n' "${PACKAGES_FILE}" >&2
    exit 1
fi
PACKAGES="$(grep -v '^[[:space:]]*#' "${PACKAGES_FILE}" | grep -v '^[[:space:]]*$' | tr '\n' ',' | sed 's/,$//')"

# Create a temporary build directory
BUILD_DIR="$(mktemp -d /tmp/dayshield-rootfs-XXXXXX)"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
mkdir -p "${ROOTFS_DIR}"
# Let the `_apt` sandbox user traverse the temp path used by mmdebstrap.
# Without this, apt falls back to unsandboxed downloads and emits a warning.
chmod 755 "${BUILD_DIR}" "${ROOTFS_DIR}" 2>/dev/null || true

# Helper: bind-mount virtual filesystems into the chroot.
# Required by update-initramfs / mkinitramfs (needs /proc for depmod and
# /dev for device-node access).
chroot_mount() {
    mount -t proc  proc              "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs             "${ROOTFS_DIR}/sys"
    mount --bind   /dev              "${ROOTFS_DIR}/dev"
    mount --bind   /dev/pts          "${ROOTFS_DIR}/dev/pts"
}

chroot_umount() {
    umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev"     2>/dev/null || true
    umount "${ROOTFS_DIR}/sys"     2>/dev/null || true
    umount "${ROOTFS_DIR}/proc"    2>/dev/null || true
}

cleanup_build() {
    chroot_umount
    printf 'Cleaning up build directory: %s\n' "${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
}
trap cleanup_build EXIT

print_step() {
    printf '\n'
    printf -- '------------------------------------------------------------\n'
    printf 'STEP: %s\n' "$1"
    printf -- '------------------------------------------------------------\n'
}

security_suite_enabled() {
    case "$1" in
        unstable|sid|testing|experimental)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

SECURITY_MIRROR_ENTRY=""
UPDATES_MIRROR_ENTRY=""
if security_suite_enabled "${SUITE}"; then
    SECURITY_MIRROR_ENTRY="deb ${SECURITY_MIRROR} ${SUITE}-security main"
    if [ "${ENABLE_SUITE_UPDATES}" = "1" ]; then
        UPDATES_MIRROR_ENTRY="deb ${MIRROR} ${SUITE}-updates main"
    fi
fi

printf '==> Building DayShield RootFS\n'
printf '    Architecture : %s\n' "${ARCH}"
printf '    Suite        : %s\n' "${SUITE}"
printf '    Output       : %s\n' "${OUTPUT}"
printf '    Mirror       : %s\n' "${MIRROR}"
if [ -n "${SECURITY_MIRROR_ENTRY}" ]; then
    printf '    Security     : %s (%s-security)\n' "${SECURITY_MIRROR}" "${SUITE}"
else
    printf '    Security     : disabled for suite %s\n' "${SUITE}"
fi
if [ -n "${UPDATES_MIRROR_ENTRY}" ]; then
    printf '    Updates      : enabled (%s-updates from %s)\n' "${SUITE}" "${MIRROR}"
else
    printf '    Updates      : disabled\n'
fi
printf '    Packages     : %s\n' "${PACKAGES}"
printf '    UI dir       : %s\n' "${UI_DIR:-<none>}"
printf '    Core repo    : %s\n' "${CORE_REPO_DIR:-<none>}"
printf '    UI repo      : %s\n' "${UI_REPO_DIR:-<none>}"
printf '    RootFS repo  : %s\n' "${ROOTFS_REPO_DIR:-<none>}"
printf '\n'

print_step "mmdebstrap"
# Build the mmdebstrap positional-argument list dynamically so that optional
# security and updates sources are only appended when enabled.  By this point
# in the script all argument parsing is complete so reusing $@ is safe.
set -- \
    --arch="${ARCH}" \
    --variant=minbase \
    --include="${PACKAGES}" \
    --aptopt='Acquire::Languages=none' \
    --aptopt='Acquire::Retries=3' \
    --aptopt='Acquire::http::Timeout=30' \
    "${SUITE}" \
    "${ROOTFS_DIR}" \
    "${MIRROR}"
[ -n "${SECURITY_MIRROR_ENTRY}" ] && set -- "$@" "${SECURITY_MIRROR_ENTRY}"
[ -n "${UPDATES_MIRROR_ENTRY}" ]  && set -- "$@" "${UPDATES_MIRROR_ENTRY}"
mmdebstrap "$@"

print_step "chroot-setup.sh"
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    REPO_DIR="${REPO_DIR}" \
    sh "${SCRIPT_DIR}/chroot-setup.sh"

print_step "stamp-version"
_rootfs_tag=""
if command -v git >/dev/null 2>&1 && [ -n "${ROOTFS_REPO_DIR}" ]; then
    _rootfs_tag="$(git -C "${ROOTFS_REPO_DIR}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
if [ -z "${_rootfs_tag}" ]; then
    _derived="$(basename "${OUTPUT}" | sed 's/^rootfs-//;s/\.tar\.zst$//')"
    case "${_derived}" in
        rootfs|"") _rootfs_tag="unknown" ;;
        *) _rootfs_tag="${_derived#v}" ;;
    esac
fi
mkdir -p "${ROOTFS_DIR}/etc/dayshield"
printf '%s\n' "${_rootfs_tag}" > "${ROOTFS_DIR}/etc/dayshield/version"
printf '    Version: %s\n' "${_rootfs_tag}"

print_step "install-dayshield-core.sh"
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    REPO_DIR="${REPO_DIR}" \
    DAYSHIELD_UI_DIR="${UI_DIR}" \
    DAYSHIELD_CORE_REPO_DIR="${CORE_REPO_DIR}" \
    DAYSHIELD_UI_REPO_DIR="${UI_REPO_DIR}" \
    DAYSHIELD_ROOTFS_REPO_DIR="${ROOTFS_REPO_DIR}" \
    sh "${SCRIPT_DIR}/install-dayshield-core.sh"

print_step "enable-services.sh"
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    sh "${SCRIPT_DIR}/enable-services.sh"

print_step "harden-ipv4.sh"
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/harden-ipv4.sh"
print_step "generate-initramfs"
if [ -d "${ROOTFS_DIR}/boot" ]; then
    FSTAB_PATH="${ROOTFS_DIR}/etc/fstab"
    FSTAB_BACKUP="${ROOTFS_DIR}/etc/fstab.dayshield-build.bak"
    INITRAMFS_LOG="${BUILD_DIR}/update-initramfs.log"

    # initramfs-tools fsck hook can warn when root is a placeholder LABEL.
    # Use a build-only fstab root entry to keep logs clean, then restore.
    if [ -f "${FSTAB_PATH}" ]; then
        cp "${FSTAB_PATH}" "${FSTAB_BACKUP}"
        cat > "${FSTAB_PATH}" <<'EOF'
# build-only fstab for initramfs generation
/dev/root            /              ext4    errors=remount-ro  0       1
EOF
    fi

    chroot_mount
    if chroot "${ROOTFS_DIR}" /usr/bin/env LC_ALL=C LANG=C LANGUAGE=C update-initramfs -c -k all >"${INITRAMFS_LOG}" 2>&1; then
        sed "/Couldn't identify type of root file system .* for fsck hook/d" "${INITRAMFS_LOG}"
        printf '    Initramfs generated successfully\n'
    else
        sed "/Couldn't identify type of root file system .* for fsck hook/d" "${INITRAMFS_LOG}" >&2
        printf '    WARNING: initramfs generation may have failed; checking for /boot/initrd.img*\n'
        if ! ls "${ROOTFS_DIR}"/boot/initrd.img* >/dev/null 2>&1; then
            chroot_umount
            if [ -f "${FSTAB_BACKUP}" ]; then
                mv "${FSTAB_BACKUP}" "${FSTAB_PATH}"
            fi
            printf '    ERROR: No initrd files found in /boot after update-initramfs\n'
            exit 1
        fi
    fi
    chroot_umount

    if [ -f "${FSTAB_BACKUP}" ]; then
        mv "${FSTAB_BACKUP}" "${FSTAB_PATH}"
    fi
else
    printf '    ERROR: /boot directory not found in rootfs\n'
    exit 1
fi
print_step "kernel-module-symlinks"
for _kmod_dir in "${ROOTFS_DIR}/usr/lib/modules"/*/; do
    [ -d "${_kmod_dir}" ] || continue
    _kv="$(basename "${_kmod_dir}")"
    _kfile="${ROOTFS_DIR}/boot/vmlinuz-${_kv}"
    _ifile="${ROOTFS_DIR}/boot/initrd.img-${_kv}"
    if [ -f "${_kfile}" ] && [ ! -e "${_kmod_dir}/vmlinuz" ]; then
        ln -sf "/boot/vmlinuz-${_kv}" "${_kmod_dir}/vmlinuz"
        printf '    vmlinuz  -> /boot/vmlinuz-%s\n' "${_kv}"
    fi
    if [ -f "${_ifile}" ] && [ ! -e "${_kmod_dir}/initrd" ]; then
        ln -sf "/boot/initrd.img-${_kv}" "${_kmod_dir}/initrd"
        printf '    initrd   -> /boot/initrd.img-%s\n' "${_kv}"
    fi
done

print_step "cleanup.sh"
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/cleanup.sh"

print_step "validate-update-tooling"
if [ ! -x "${ROOTFS_DIR}/usr/local/lib/dayshield/rootfs-update.sh" ]; then
    printf '    ERROR: missing executable /usr/local/lib/dayshield/rootfs-update.sh in rootfs\n' >&2
    exit 1
fi
printf '    Rootfs update tooling present\n'

_base_output="$(basename "${OUTPUT}")"
case "${_base_output}" in
    *.tar.zst) _artifact_stem="${_base_output%.tar.zst}" ;;
    *.tar) _artifact_stem="${_base_output%.tar}" ;;
    *) _artifact_stem="${_base_output}" ;;
esac
[ -n "${_artifact_stem}" ] || _artifact_stem="rootfs"

if [ -z "${ROOTFS_IMAGE_OUTPUT}" ]; then
    ROOTFS_IMAGE_OUTPUT="$(dirname "${OUTPUT}")/${_artifact_stem}.squashfs"
fi
if [ -z "${ROOTFS_MANIFEST_OUTPUT}" ]; then
    ROOTFS_MANIFEST_OUTPUT="$(dirname "${OUTPUT}")/${_artifact_stem}-manifest.json"
fi

mkdir -p "${ROOTFS_DIR}/usr/local/share/dayshield-updates"
cat > "${ROOTFS_DIR}/usr/local/share/dayshield-updates/rootfs-image-layout.json" <<EOF
{
  "schema_version": 1,
  "component": "rootfs",
  "version": "${_rootfs_tag}",
  "boot_mode": "initramfs-image",
  "version_file": "/etc/dayshield/version",
  "image_store": {
    "directory": "/boot/dayshield/images",
    "metadata_directory": "/boot/dayshield/metadata",
    "workspace_directory": "/var/lib/dayshield-updates",
    "current_link": "/boot/dayshield/current",
    "previous_link": "/boot/dayshield/previous",
    "candidate_link": "/boot/dayshield/next"
  },
  "artifacts": {
    "archive": "$(basename "${OUTPUT}")",
    "image": "$(basename "${ROOTFS_IMAGE_OUTPUT}")",
    "manifest": "$(basename "${ROOTFS_MANIFEST_OUTPUT}")"
  }
}
EOF

print_step "package-rootfs-archive"
printf '    output: %s\n' "${OUTPUT}"
OUTPUT_DIR="$(dirname "${OUTPUT}")"
if [ "${OUTPUT_DIR}" != "." ] && [ ! -d "${OUTPUT_DIR}" ]; then
    mkdir -p "${OUTPUT_DIR}"
fi
OUTPUT_ABS="$(cd "$(dirname "${OUTPUT}")" && pwd)/$(basename "${OUTPUT}")"
tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "${ROOTFS_DIR}" \
    -cf - \
    . \
    | zstd -T0 -19 --force -o "${OUTPUT_ABS}"

print_step "build-squashfs"
printf '    output: %s\n' "${ROOTFS_IMAGE_OUTPUT}"
IMAGE_OUTPUT_DIR="$(dirname "${ROOTFS_IMAGE_OUTPUT}")"
if [ "${IMAGE_OUTPUT_DIR}" != "." ] && [ ! -d "${IMAGE_OUTPUT_DIR}" ]; then
    mkdir -p "${IMAGE_OUTPUT_DIR}"
fi
ROOTFS_IMAGE_OUTPUT_ABS="$(cd "$(dirname "${ROOTFS_IMAGE_OUTPUT}")" && pwd)/$(basename "${ROOTFS_IMAGE_OUTPUT}")"
MKSQUASHFS_LOG="${BUILD_DIR}/mksquashfs.log"
if mksquashfs "${ROOTFS_DIR}" "${ROOTFS_IMAGE_OUTPUT_ABS}" \
    -noappend \
    -comp zstd \
    -processors 1 \
    -mkfs-time "${SOURCE_DATE_EPOCH}" \
    -all-time "${SOURCE_DATE_EPOCH}" \
    -root-owned \
    >"${MKSQUASHFS_LOG}" 2>&1; then
    sed 's/^/    /' "${MKSQUASHFS_LOG}"
else
    sed 's/^/    /' "${MKSQUASHFS_LOG}" >&2
    printf '    ERROR: failed to build squashfs image\n' >&2
    exit 1
fi

print_step "write-manifest"
printf '    output: %s\n' "${ROOTFS_MANIFEST_OUTPUT}"
MANIFEST_OUTPUT_DIR="$(dirname "${ROOTFS_MANIFEST_OUTPUT}")"
if [ "${MANIFEST_OUTPUT_DIR}" != "." ] && [ ! -d "${MANIFEST_OUTPUT_DIR}" ]; then
    mkdir -p "${MANIFEST_OUTPUT_DIR}"
fi
ROOTFS_MANIFEST_OUTPUT_ABS="$(cd "$(dirname "${ROOTFS_MANIFEST_OUTPUT}")" && pwd)/$(basename "${ROOTFS_MANIFEST_OUTPUT}")"
ARCHIVE_SHA256="$(sha256sum "${OUTPUT_ABS}" | awk '{print $1}')"
IMAGE_SHA256="$(sha256sum "${ROOTFS_IMAGE_OUTPUT_ABS}" | awk '{print $1}')"
ARCHIVE_SIZE="$(wc -c < "${OUTPUT_ABS}" | tr -d '[:space:]')"
IMAGE_SIZE="$(wc -c < "${ROOTFS_IMAGE_OUTPUT_ABS}" | tr -d '[:space:]')"
cat > "${ROOTFS_MANIFEST_OUTPUT_ABS}" <<EOF
{
  "schema_version": 1,
  "component": "rootfs",
  "version": "${_rootfs_tag}",
  "architecture": "${ARCH}",
  "suite": "${SUITE}",
  "build_timestamp": "${SOURCE_DATE_UTC}",
  "version_file": "/etc/dayshield/version",
  "update_strategy": {
    "type": "initramfs-image",
    "image_format": "squashfs",
    "image_store_directory": "/boot/dayshield/images",
    "workspace_directory": "/var/lib/dayshield-updates"
  },
  "artifacts": {
    "archive": {
      "name": "$(basename "${OUTPUT}")",
      "format": "tar+zstd",
      "sha256": "${ARCHIVE_SHA256}",
      "size": ${ARCHIVE_SIZE}
    },
    "image": {
      "name": "$(basename "${ROOTFS_IMAGE_OUTPUT}")",
      "format": "squashfs",
      "sha256": "${IMAGE_SHA256}",
      "size": ${IMAGE_SIZE}
    }
  }
}
EOF

printf '==> Done: %s\n' "${OUTPUT}"
printf '           %s\n' "${ROOTFS_IMAGE_OUTPUT}"
printf '           %s\n' "${ROOTFS_MANIFEST_OUTPUT}"
