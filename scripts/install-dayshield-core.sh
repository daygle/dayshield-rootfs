#!/bin/sh
# install-dayshield-core.sh - Install the dayshield-core binary and service.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"
: "${REPO_DIR:?REPO_DIR must be set}"

BINARY_SRC="${REPO_DIR}/dayshield-core"
SERVICE_SRC="${REPO_DIR}/config/services/dayshield.service"

# ── Binary ────────────────────────────────────────────────────────────────────
mkdir -p "${ROOTFS_DIR}/usr/local/sbin"

if [ -f "${BINARY_SRC}" ]; then
    printf '  -> Installing dayshield-core binary\n'
    cp "${BINARY_SRC}" "${ROOTFS_DIR}/usr/local/sbin/dayshield-core"
    chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/dayshield-core"
else
    printf '  -> dayshield-core binary not found at %s; creating placeholder\n' "${BINARY_SRC}"
    # Create a placeholder script so the service can be enabled during build
    cat > "${ROOTFS_DIR}/usr/local/sbin/dayshield-core" <<'PLACEHOLDER'
#!/bin/sh
# Placeholder - replace with the real dayshield-core binary before deployment.
printf 'dayshield-core: not yet installed\n' >&2
exit 1
PLACEHOLDER
    chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/dayshield-core"
fi

# ── Systemd service unit ──────────────────────────────────────────────────────
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"

if [ -f "${SERVICE_SRC}" ]; then
    printf '  -> Installing dayshield.service\n'
    cp "${SERVICE_SRC}" "${ROOTFS_DIR}/etc/systemd/system/dayshield.service"
else
    printf '  -> Writing default dayshield.service\n'
    cat > "${ROOTFS_DIR}/etc/systemd/system/dayshield.service" <<'UNIT'
[Unit]
Description=DayShield Firewall Core
Documentation=https://github.com/daygle/dayshield
After=network-online.target nftables.service unbound.service
Wants=network-online.target
Requires=nftables.service

[Service]
Type=exec
Environment=DAYSHIELD_PORT=8443
ExecStart=/usr/local/sbin/dayshield-core
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/dayshield /var/lib/dayshield
PrivateTmp=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN

[Install]
WantedBy=multi-user.target
UNIT
fi

# ── Optional Management UI assets ───────────────────────────────────────────
if [ -n "${DAYSHIELD_UI_DIR:-}" ]; then
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
fi

# ── Enable the service via symlink ────────────────────────────────────────────
printf '  -> Enabling dayshield.service\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
ln -sf \
    /etc/systemd/system/dayshield.service \
    "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/dayshield.service"
