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
UI_DIR=""
CORE_REPO_DIR=""
UI_REPO_DIR=""
ROOTFS_REPO_DIR=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --arch ARCH       Target architecture (default: amd64)
  --suite SUITE     Debian suite (default: trixie)
  --output FILE     Output file (default: rootfs.tar.zst)
  --mirror URL      Debian mirror URL (default: https://deb.debian.org/debian)
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
        --arch|--suite|--output|--mirror|--ui-dir|--core-repo-dir|--ui-repo-dir|--rootfs-repo-dir)
            if [ $# -lt 2 ] || [ -z "${2}" ] || [ "${2#--}" != "${2}" ]; then
                printf 'ERROR: option %s requires a value\n' "$1" >&2
                exit 1
            fi
            case "$1" in
                --arch) ARCH="$2" ;;
                --suite) SUITE="$2" ;;
                --output) OUTPUT="$2" ;;
                --mirror) MIRROR="$2" ;;
                --ui-dir) UI_DIR="$2" ;;
                --core-repo-dir) CORE_REPO_DIR="$2" ;;
                --ui-repo-dir) UI_REPO_DIR="$2" ;;
                --rootfs-repo-dir) ROOTFS_REPO_DIR="$2" ;;
            esac
            shift 2
            ;;
        --help)    usage ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage
            ;;
    esac
done

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

for tool in mmdebstrap zstd tar; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        printf 'ERROR: required tool not found: %s\n' "${tool}" >&2
        exit 1
    fi
done

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

printf '==> Building DayShield RootFS\n'
printf '    Architecture : %s\n' "${ARCH}"
printf '    Suite        : %s\n' "${SUITE}"
printf '    Output       : %s\n' "${OUTPUT}"
printf '    Mirror       : %s\n' "${MIRROR}"
printf '    Packages     : %s\n' "${PACKAGES}"
printf '    UI dir       : %s\n' "${UI_DIR:-<none>}"
printf '    Core repo    : %s\n' "${CORE_REPO_DIR:-<none>}"
printf '    UI repo      : %s\n' "${UI_REPO_DIR:-<none>}"
printf '    RootFS repo  : %s\n' "${ROOTFS_REPO_DIR:-<none>}"
printf '\n'

# ── 1. Run mmdebstrap ────────────────────────────────────────────────────────
printf '==> Step 1: mmdebstrap\n'
mmdebstrap \
    --arch="${ARCH}" \
    --variant=minbase \
    --include="${PACKAGES}" \
    --aptopt='Acquire::Languages=none' \
    --aptopt='Acquire::IPv6::Disable=true' \
    --aptopt='Acquire::Retries=0' \
    --aptopt='Acquire::http::Timeout=10' \
    "${SUITE}" \
    "${ROOTFS_DIR}" \
    "${MIRROR}"

# ── 2. Run chroot-setup.sh ───────────────────────────────────────────────────
printf '==> Step 2: chroot-setup\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    REPO_DIR="${REPO_DIR}" \
    sh "${SCRIPT_DIR}/chroot-setup.sh"

# ── 3. Run install-dayshield-core.sh ────────────────────────────────────────
if [ ! -f "${REPO_DIR}/dayshield-core" ]; then
    printf 'ERROR: missing dayshield-core binary at %s/dayshield-core\n' "${REPO_DIR}" >&2
    printf '       Build dayshield-core and copy target/release/dayshield-core there before running rootfs build.\n' >&2
    exit 1
fi
if [ -z "${CORE_REPO_DIR}" ]; then
    printf 'ERROR: core repo path not provided and sibling ../dayshield-core was not found\n' >&2
    printf '       Pass --core-repo-dir <path-to-dayshield-core>\n' >&2
    exit 1
fi
if [ -z "${UI_REPO_DIR}" ]; then
    printf 'ERROR: UI repo path not provided and sibling ../dayshield-ui was not found\n' >&2
    printf '       Pass --ui-repo-dir <path-to-dayshield-ui>\n' >&2
    exit 1
fi
if [ -z "${ROOTFS_REPO_DIR}" ]; then
    printf 'ERROR: rootfs repo path not provided and current repo git metadata was not found\n' >&2
    printf '       Pass --rootfs-repo-dir <path-to-dayshield-rootfs>\n' >&2
    exit 1
fi
printf '==> Step 3: install-dayshield-core\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    REPO_DIR="${REPO_DIR}" \
    DAYSHIELD_UI_DIR="${UI_DIR}" \
    DAYSHIELD_CORE_REPO_DIR="${CORE_REPO_DIR}" \
    DAYSHIELD_UI_REPO_DIR="${UI_REPO_DIR}" \
    DAYSHIELD_ROOTFS_REPO_DIR="${ROOTFS_REPO_DIR}" \
    sh "${SCRIPT_DIR}/install-dayshield-core.sh"

# ── 4. Run enable-services.sh ────────────────────────────────────────────────
printf '==> Step 4: enable-services\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    sh "${SCRIPT_DIR}/enable-services.sh"

# ── 5. Run harden-ipv4.sh ────────────────────────────────────────────────────
printf '==> Step 5: harden-ipv4\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/harden-ipv4.sh"
# ── 5b. Generate initramfs (required for boot) ──────────────────
printf '==> Step 6: generating initramfs\n'
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
# ── 6. Run cleanup.sh ────────────────────────────────────────────────────────
printf '==> Step 7: cleanup\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/cleanup.sh"

# ── 7. Package the rootfs ────────────────────────────────────────
printf '==> Step 8: packaging rootfs -> %s\n' "${OUTPUT}"
OUTPUT_ABS="$(cd "$(dirname "${OUTPUT}")" && pwd)/$(basename "${OUTPUT}")"
tar \
    --sort=name \
    --mtime='@0' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "${ROOTFS_DIR}" \
    -cf - \
    . \
    | zstd -T0 -19 --force -o "${OUTPUT_ABS}"

printf '==> Done: %s\n' "${OUTPUT}"
