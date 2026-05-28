#!/bin/sh
# install-dayshield-core.sh - Install the dayshield-core binary and service.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"
: "${REPO_DIR:?REPO_DIR must be set}"

BINARY_SRC="${REPO_DIR}/dayshield-core"
SERVICE_SRC="${REPO_DIR}/config/services/dayshield.service"
TEMPLATE_DIR="${REPO_DIR}/config/templates"
CORE_REPO_SRC="${DAYSHIELD_CORE_REPO_DIR:-}"
UI_REPO_SRC="${DAYSHIELD_UI_REPO_DIR:-}"
ROOTFS_REPO_SRC="${DAYSHIELD_ROOTFS_REPO_DIR:-}"

CORE_REPO_DEST="${ROOTFS_DIR}/opt/dayshield-core"
UI_REPO_DEST="${ROOTFS_DIR}/opt/dayshield-ui"
ROOTFS_REPO_DEST="${ROOTFS_DIR}/opt/dayshield-rootfs"

CORE_REMOTE_URL="https://github.com/daygle/dayshield-core"
UI_REMOTE_URL="https://github.com/daygle/dayshield-ui"
ROOTFS_REMOTE_URL="https://github.com/daygle/dayshield-rootfs"

seed_repo() {
    component="$1"
    src="$2"
    dest="$3"
    remote="$4"

    if [ -z "${src}" ]; then
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        printf 'ERROR: git is required on the build host to seed %s repo\n' "${component}" >&2
        exit 1
    fi

    if [ ! -d "${src}/.git" ]; then
        printf 'ERROR: %s source is not a git repo: %s\n' "${component}" "${src}" >&2
        exit 1
    fi

    printf '  -> Seeding %s git repo from %s\n' "${component}" "${src}"
    mkdir -p "$(dirname "${dest}")"
    rm -rf "${dest}"
    git -c advice.detachedHead=false clone --quiet --no-hardlinks "${src}" "${dest}"
    git -C "${dest}" remote set-url origin "${remote}" >/dev/null 2>&1 || true
    chmod -R a+rX "${dest}"
}

# ── Binary ────────────────────────────────────────────────────────────────────
mkdir -p "${ROOTFS_DIR}/usr/local/sbin"

if [ -f "${BINARY_SRC}" ]; then
    printf '  -> Installing dayshield-core binary\n'
    cp "${BINARY_SRC}" "${ROOTFS_DIR}/usr/local/sbin/dayshield-core"
    chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/dayshield-core"
else
    printf 'ERROR: dayshield-core binary not found at %s\n' "${BINARY_SRC}" >&2
    printf '       Build dayshield-core and copy the release binary to this path before building rootfs.\n' >&2
    exit 1
fi

# ── Rootfs update helper ──────────────────────────────────────────────────────
ROOTFS_HELPER_SRC="${REPO_DIR}/rootfs-update.sh"
if [ -f "${ROOTFS_HELPER_SRC}" ]; then
    printf '  -> Installing rootfs update helper\n'
    mkdir -p "${ROOTFS_DIR}/usr/local/lib/dayshield"
    install -m 0755 "${ROOTFS_HELPER_SRC}" "${ROOTFS_DIR}/usr/local/lib/dayshield/rootfs-update.sh"
else
    printf 'ERROR: rootfs-update.sh not found at %s\n' "${ROOTFS_HELPER_SRC}" >&2
    exit 1
fi

# ── Seed update repositories for runtime updater ─────────────────────────────
# Ensure /opt/dayshield-* directories exist for the runtime updater,
# whether or not repos are seeded during build.
mkdir -p "${ROOTFS_DIR}/opt"
mkdir -p "${CORE_REPO_DEST}"
mkdir -p "${UI_REPO_DEST}"
mkdir -p "${ROOTFS_REPO_DEST}"
mkdir -p "${ROOTFS_DIR}/var/log/dayshield"

seed_repo "core" "${CORE_REPO_SRC}" "${CORE_REPO_DEST}" "${CORE_REMOTE_URL}"
seed_repo "ui" "${UI_REPO_SRC}" "${UI_REPO_DEST}" "${UI_REMOTE_URL}"
seed_repo "rootfs" "${ROOTFS_REPO_SRC}" "${ROOTFS_REPO_DEST}" "${ROOTFS_REMOTE_URL}"

# ── Systemd service unit ──────────────────────────────────────────────────────
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"

if [ ! -f "${SERVICE_SRC}" ]; then
    printf 'ERROR: dayshield.service not found at %s\n' "${SERVICE_SRC}" >&2
    exit 1
fi
printf '  -> Installing dayshield.service\n'
cp "${SERVICE_SRC}" "${ROOTFS_DIR}/etc/systemd/system/dayshield.service"

# Ensure engines can update their config files under ProtectSystem=strict.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/dayshield.service.d"
if [ -f "${TEMPLATE_DIR}/dayshield-engine-paths.conf" ]; then
    cp "${TEMPLATE_DIR}/dayshield-engine-paths.conf" "${ROOTFS_DIR}/etc/systemd/system/dayshield.service.d/dayshield-engine-paths.conf"
else
    printf 'ERROR: missing template %s\n' "${TEMPLATE_DIR}/dayshield-engine-paths.conf" >&2
    exit 1
fi

# ── Installer/live mode guard ────────────────────────────────────────────────
# dayshield-core must not start while booted as installer live media.
if [ -f "${TEMPLATE_DIR}/dayshield-installer.conf" ]; then
    cp "${TEMPLATE_DIR}/dayshield-installer.conf" "${ROOTFS_DIR}/etc/systemd/system/dayshield.service.d/dayshield-installer.conf"
else
    printf 'ERROR: missing template %s\n' "${TEMPLATE_DIR}/dayshield-installer.conf" >&2
    exit 1
fi

# ── Required Management UI assets ───────────────────────────────────────────
if [ -z "${DAYSHIELD_UI_DIR:-}" ]; then
    printf 'ERROR: DAYSHIELD_UI_DIR is required and must point to a built UI dist directory.\n' >&2
    exit 1
fi
if [ ! -d "${DAYSHIELD_UI_DIR}" ]; then
    printf 'ERROR: DayShield UI build directory not found: %s\n' "${DAYSHIELD_UI_DIR}" >&2
    exit 1
fi
if [ ! -f "${DAYSHIELD_UI_DIR}/index.html" ]; then
    printf 'ERROR: DayShield UI build directory does not look like a Vite build output: %s\n' "${DAYSHIELD_UI_DIR}" >&2
    exit 1
fi

printf '  -> Installing DayShield UI static assets from %s\n' "${DAYSHIELD_UI_DIR}"
mkdir -p "${ROOTFS_DIR}/usr/local/share/dayshield-ui"
cp -a "${DAYSHIELD_UI_DIR}/." "${ROOTFS_DIR}/usr/local/share/dayshield-ui/"
chmod -R a+rX "${ROOTFS_DIR}/usr/local/share/dayshield-ui"

# ── Enable the service via symlink ────────────────────────────────────────────
printf '  -> Enabling dayshield.service\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
ln -sf \
    /etc/systemd/system/dayshield.service \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/dayshield.service"
