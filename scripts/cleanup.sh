#!/bin/sh
# cleanup.sh - Strip non-reproducible artifacts from the rootfs.
# Removes caches, machine-id, logs, and normalises timestamps to epoch 0.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"

# ── Live-boot / live-config artifacts ────────────────────────────────────────
# These directories are only meaningful inside a squashfs live-root.  If they
# survived into the installed rootfs (e.g. from a previous build), remove them
# so no live-environment behaviour is triggered on the installed system.
printf '  -> Removing live-boot artifacts\n'
rm -rf \
    "${ROOTFS_DIR}/etc/live" \
    "${ROOTFS_DIR}/lib/live" \
    "${ROOTFS_DIR}/usr/lib/live" \
    "${ROOTFS_DIR}/usr/share/initramfs-tools/hooks/live" \
    "${ROOTFS_DIR}/usr/share/initramfs-tools/scripts/live" \
    "${ROOTFS_DIR}/usr/share/initramfs-tools/scripts/live-bottom" \
    "${ROOTFS_DIR}/usr/share/initramfs-tools/scripts/live-top"

# ── APT caches ────────────────────────────────────────────────────────────────
printf '  -> Removing APT caches\n'
rm -rf "${ROOTFS_DIR}/var/cache/apt/archives"/*.deb \
       "${ROOTFS_DIR}/var/cache/apt/archives/partial" \
       "${ROOTFS_DIR}/var/lib/apt/lists"/*

# ── machine-id ────────────────────────────────────────────────────────────────
printf '  -> Clearing machine-id\n'
# An empty (or single-newline) machine-id causes systemd to generate a
# transient one on first boot - this is the recommended approach for images.
printf '\n' > "${ROOTFS_DIR}/etc/machine-id"
# Also clear the D-Bus machine-id if present
if [ -e "${ROOTFS_DIR}/var/lib/dbus/machine-id" ]; then
    printf '\n' > "${ROOTFS_DIR}/var/lib/dbus/machine-id"
fi

# ── Temporary files ───────────────────────────────────────────────────────────
printf '  -> Removing temporary files\n'
rm -rf "${ROOTFS_DIR}/tmp"/*
rm -f "${ROOTFS_DIR}/run/"*.pid 2>/dev/null || true
rm -f "${ROOTFS_DIR}/run/"*.lock 2>/dev/null || true
rm -f "${ROOTFS_DIR}/run/"*.tmp 2>/dev/null || true
rm -rf "${ROOTFS_DIR}/var/tmp"/*

# ── Zero out logs ─────────────────────────────────────────────────────────────
printf '  -> Zeroing logs\n'
find "${ROOTFS_DIR}/var/log" \
    -type f \
    ! -path "${ROOTFS_DIR}/var/log/journal/*" | while IFS= read -r logfile; do
    : > "${logfile}"
done

# Remove any packaged journal files entirely. Binary .journal files must not be
# truncated because journald can treat them as corrupt and skip them.
printf '  -> Removing packaged journal files\n'
rm -rf "${ROOTFS_DIR}/var/log/journal"/*
mkdir -p "${ROOTFS_DIR}/var/log/journal"

# ── Remove special filesystem nodes ───────────────────────────────────────────
printf '  -> Removing special filesystem nodes\n'
find "${ROOTFS_DIR}" \
    -mindepth 1 \
    \( -type b -o -type c -o -type p -o -type s \) \
    -delete 2>/dev/null || true

# Recreate runtime temp directories after cleanup
mkdir -p "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/run" "${ROOTFS_DIR}/var/tmp"
chmod 1777 "${ROOTFS_DIR}/tmp" 2>/dev/null || true
chmod 1777 "${ROOTFS_DIR}/var/tmp" 2>/dev/null || true

# ── Reproducible timestamps ───────────────────────────────────────────────────
printf '  -> Normalising timestamps to epoch 0\n'
find "${ROOTFS_DIR}" \
    ! -path "${ROOTFS_DIR}/.git/*" \
    -exec touch -h -d '@0' {} + 2>/dev/null || true

printf '  -> Cleanup complete\n'
