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
ENABLE_OSTREE_COMPOSE="1"
OSTREE_REPO_OUTPUT=""
OSTREE_REF=""
OSTREE_REF_SET="0"
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
                        Include SUITE-updates source for stable-style suites (default: disabled)
    --disable-ostree-compose
                        Skip host-side OSTree repo/commit generation (default: enabled)
    --ostree-repo-output FILE
                        Output file for archived OSTree repo (default: <output>-ostree-repo.tar.zst)
    --ostree-ref REF   OSTree ref for commits (default: dayshield/<arch>)
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
        --arch|--suite|--output|--mirror|--security-mirror|--ui-dir|--core-repo-dir|--ui-repo-dir|--rootfs-repo-dir|--ostree-repo-output|--ostree-ref)
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
                --ostree-repo-output) OSTREE_REPO_OUTPUT="$2" ;;
                --ostree-ref) OSTREE_REF="$2"; OSTREE_REF_SET="1" ;;
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
        --disable-ostree-compose)
            ENABLE_OSTREE_COMPOSE="0"
            shift
            ;;
        --help)    usage ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage
            ;;
    esac
done

if [ "${OSTREE_REF_SET}" != "1" ]; then
    OSTREE_REF="dayshield/${ARCH}"
fi

if [ -z "${SOURCE_DATE_EPOCH}" ] && command -v git >/dev/null 2>&1 && [ -n "${ROOTFS_REPO_DIR}" ]; then
    if SOURCE_DATE_EPOCH="$(git -C "${ROOTFS_REPO_DIR}" log -1 --format=%ct 2>/dev/null)"; then
        :
    else
        SOURCE_DATE_EPOCH=""
        printf 'WARNING: failed to derive SOURCE_DATE_EPOCH from git history; using current time\n' >&2
    fi
fi
if [ -z "${SOURCE_DATE_EPOCH}" ]; then
    printf 'WARNING: SOURCE_DATE_EPOCH not provided and git timestamp unavailable; using current time\n' >&2
    SOURCE_DATE_EPOCH="$(date +%s)"
fi

case "${SOURCE_DATE_EPOCH}" in
    *[!0-9]*)
        printf 'ERROR: SOURCE_DATE_EPOCH must be an integer epoch timestamp\n' >&2
        exit 1
        ;;
esac

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
if [ "${ENABLE_OSTREE_COMPOSE}" = "1" ]; then
    printf '    OSTree ref   : %s\n' "${OSTREE_REF}"
else
    printf '    OSTree ref   : disabled\n'
fi
printf '\n'

# ── 1. Run mmdebstrap ────────────────────────────────────────────────────────
printf '==> Step 1: mmdebstrap\n'
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

# ── 2. Run chroot-setup.sh ───────────────────────────────────────────────────
printf '==> Step 2: chroot-setup\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    CONFIG_DIR="${CONFIG_DIR}" \
    REPO_DIR="${REPO_DIR}" \
    sh "${SCRIPT_DIR}/chroot-setup.sh"

# ── 2b. Stamp rootfs version ─────────────────────────────────────────────────
printf '==> Step 2b: stamp version\n'
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

# ── 3. Run install-dayshield-core.sh ────────────────────────────────────────
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

# ── 5. Run harden-ipv4.sh default hardening ──────────────────────────────────
printf '==> Step 5: harden-ipv4\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/harden-ipv4.sh"
# ── 5b. Generate initramfs (required for boot) ──────────────────
printf '==> Step 5b: generating initramfs\n'
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
printf '==> Step 6: cleanup\n'
env ROOTFS_DIR="${ROOTFS_DIR}" \
    sh "${SCRIPT_DIR}/cleanup.sh"

# ── 7. Compose OSTree repo commit (host-side) ───────────────────────────────
if [ "${ENABLE_OSTREE_COMPOSE}" = "1" ]; then
    printf '==> Step 7: composing OSTree repo\n'
    if ! command -v ostree >/dev/null 2>&1; then
        printf 'ERROR: required tool not found: ostree (needed for OSTree compose)\n' >&2
        printf '       Install ostree or run with --disable-ostree-compose\n' >&2
        exit 1
    fi
    if [ -z "${OSTREE_REPO_OUTPUT}" ]; then
        _base_output="$(basename "${OUTPUT}")"
        case "${_base_output}" in
            *.tar.zst) _base_output="${_base_output%.tar.zst}" ;;
            *.tar) _base_output="${_base_output%.tar}" ;;
        esac
        [ -n "${_base_output}" ] || _base_output="rootfs"
        OSTREE_REPO_OUTPUT="$(dirname "${OUTPUT}")/${_base_output}-ostree-repo.tar.zst"
    fi
    OSTREE_OUTPUT_DIR="$(dirname "${OSTREE_REPO_OUTPUT}")"
    if [ "${OSTREE_OUTPUT_DIR}" != "." ] && [ ! -d "${OSTREE_OUTPUT_DIR}" ]; then
        mkdir -p "${OSTREE_OUTPUT_DIR}"
    fi
    OSTREE_REPO_OUTPUT_ABS="$(cd "$(dirname "${OSTREE_REPO_OUTPUT}")" && pwd)/$(basename "${OSTREE_REPO_OUTPUT}")"
    OSTREE_REPO_DIR="${BUILD_DIR}/ostree-repo"
    rm -rf "${OSTREE_REPO_DIR}"
    mkdir -p "${OSTREE_REPO_DIR}"

    ostree --repo="${OSTREE_REPO_DIR}" init --mode=archive-z2
    ostree --repo="${OSTREE_REPO_DIR}" commit \
        --branch="${OSTREE_REF}" \
        --tree="dir=${ROOTFS_DIR}" \
        --subject="DayShield rootfs ${_rootfs_tag}" \
        --timestamp="${SOURCE_DATE_EPOCH}" \
        --add-metadata-string="dayshield.version=${_rootfs_tag}"
    ostree --repo="${OSTREE_REPO_DIR}" summary -u
    OSTREE_COMMIT="$(ostree --repo="${OSTREE_REPO_DIR}" rev-parse "${OSTREE_REF}")"
    mkdir -p "${ROOTFS_DIR}/usr/local/share/dayshield-updates"
    cat > "${ROOTFS_DIR}/usr/local/share/dayshield-updates/ostree-build-manifest.json" <<EOF
{
  "ref": "${OSTREE_REF}",
  "commit": "${OSTREE_COMMIT}",
  "version": "${_rootfs_tag}"
}
EOF
    tar \
        --sort=name \
        --mtime="@${SOURCE_DATE_EPOCH}" \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        -C "${OSTREE_REPO_DIR}" \
        -cf - \
        . \
        | zstd -T0 -19 --force -o "${OSTREE_REPO_OUTPUT_ABS}"
    printf '    OSTree commit : %s\n' "${OSTREE_COMMIT}"
    printf '    OSTree artifact: %s\n' "${OSTREE_REPO_OUTPUT}"
fi

# ── 8. Package the rootfs ───────────────────────────────────────
printf '==> Step 8: packaging rootfs -> %s\n' "${OUTPUT}"
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

printf '==> Done: %s\n' "${OUTPUT}"
