#!/bin/sh
# build-rootfs.sh — Main entrypoint for the DayShield RootFS builder.
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
MIRROR="http://deb.debian.org/debian"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --arch ARCH       Target architecture (default: amd64)
  --suite SUITE     Debian suite (default: bookworm)
  --output FILE     Output file (default: rootfs.tar.zst)
  --mirror URL      Debian mirror URL (default: http://deb.debian.org/debian)
  --help            Show this help message
EOF
    exit 0
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)    ARCH="$2";   shift 2 ;;
        --suite)   SUITE="$2";  shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --mirror)  MIRROR="$2"; shift 2 ;;
        --help)    usage ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage
            ;;
    esac
done

# Validate required tools
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

cleanup_build() {
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
printf '==> Step 3: install-dayshield-core\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    REPO_DIR="${REPO_DIR}" \
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

# ── 6. Run cleanup.sh ────────────────────────────────────────────────────────
printf '==> Step 6: cleanup\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/cleanup.sh"

# ── 7. Package the rootfs ────────────────────────────────────────────────────
printf '==> Step 7: packaging rootfs -> %s\n' "${OUTPUT}"
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
    | zstd -T0 -19 -o "${OUTPUT_ABS}"

printf '==> Done: %s\n' "${OUTPUT}"
