#!/bin/sh
# cleanup.sh — Strip non-reproducible artifacts from the rootfs.
# Removes caches, machine-id, logs, and normalises timestamps to epoch 0.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"

# ── APT caches ────────────────────────────────────────────────────────────────
printf '  -> Removing APT caches\n'
rm -rf "${ROOTFS_DIR}/var/cache/apt/archives"/*.deb \
       "${ROOTFS_DIR}/var/cache/apt/archives/partial" \
       "${ROOTFS_DIR}/var/lib/apt/lists"/*

# ── machine-id ────────────────────────────────────────────────────────────────
printf '  -> Clearing machine-id\n'
# An empty (or single-newline) machine-id causes systemd to generate a
# transient one on first boot — this is the recommended approach for images.
printf '\n' > "${ROOTFS_DIR}/etc/machine-id"
# Also clear the D-Bus machine-id if present
if [ -e "${ROOTFS_DIR}/var/lib/dbus/machine-id" ]; then
    printf '\n' > "${ROOTFS_DIR}/var/lib/dbus/machine-id"
fi

# ── Temporary files ───────────────────────────────────────────────────────────
printf '  -> Removing temporary files\n'
rm -rf "${ROOTFS_DIR}/tmp"/*
rm -rf "${ROOTFS_DIR}/run"/*
rm -rf "${ROOTFS_DIR}/var/tmp"/*

# ── Zero out logs ─────────────────────────────────────────────────────────────
printf '  -> Zeroing logs\n'
find "${ROOTFS_DIR}/var/log" -type f | while IFS= read -r logfile; do
    : > "${logfile}"
done

# ── Reproducible timestamps ───────────────────────────────────────────────────
printf '  -> Normalising timestamps to epoch 0\n'
find "${ROOTFS_DIR}" \
    ! -path "${ROOTFS_DIR}/.git/*" \
    -exec touch -h -d '@0' {} + 2>/dev/null || true

printf '  -> Cleanup complete\n'
