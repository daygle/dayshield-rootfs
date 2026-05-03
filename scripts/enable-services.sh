#!/bin/sh
# enable-services.sh — Enable required systemd services in the rootfs.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"

# Helper: create a wants symlink for a service under a given target.
enable_service() {
    _target="$1"
    _service="$2"
    _wants_dir="${ROOTFS_DIR}/etc/systemd/system/${_target}.wants"
    _unit_path=""

    # Determine where the unit lives (system-installed or our custom one)
    if [ -f "${ROOTFS_DIR}/etc/systemd/system/${_service}" ]; then
        _unit_path="/etc/systemd/system/${_service}"
    elif [ -f "${ROOTFS_DIR}/lib/systemd/system/${_service}" ]; then
        _unit_path="/lib/systemd/system/${_service}"
    elif [ -f "${ROOTFS_DIR}/usr/lib/systemd/system/${_service}" ]; then
        _unit_path="/usr/lib/systemd/system/${_service}"
    else
        printf '  -> WARNING: unit file not found for %s; skipping enable\n' "${_service}"
        return 0
    fi

    mkdir -p "${_wants_dir}"
    ln -sf "${_unit_path}" "${_wants_dir}/${_service}"
    printf '  -> Enabled %s -> %s\n' "${_service}" "${_target}"
}

# ── Multi-user services ───────────────────────────────────────────────────────
for svc in \
    systemd-networkd.service \
    nftables.service \
    unbound.service \
    suricata.service \
    crowdsec.service \
    ssh.service \
    dayshield.service \
    console-wizard.service
do
    enable_service multi-user.target "${svc}"
done

# ── Network-online services ───────────────────────────────────────────────────
for svc in \
    systemd-networkd.service \
    systemd-networkd-wait-online.service
do
    enable_service network-online.target "${svc}" 2>/dev/null || true
done

# ── Timers / oneshot services (acme renewal) ──────────────────────────────────
if [ -f "${ROOTFS_DIR}/etc/systemd/system/acme.service" ] || \
   [ -f "${ROOTFS_DIR}/usr/lib/systemd/system/acme.service" ]; then
    enable_service multi-user.target acme.service
fi

# ── WireGuard — enable per the service unit placed in /etc/systemd/system ─────
if [ -f "${ROOTFS_DIR}/etc/systemd/system/wireguard.service" ]; then
    enable_service multi-user.target wireguard.service
fi

# ── Disable systemd-resolved in favour of unbound ─────────────────────────────
printf '  -> Masking systemd-resolved (replaced by unbound)\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null \
    "${ROOTFS_DIR}/etc/systemd/system/systemd-resolved.service" 2>/dev/null || true

# ── Point /etc/resolv.conf at localhost (unbound) ─────────────────────────────
printf '  -> Pointing /etc/resolv.conf at 127.0.0.1\n'
printf 'nameserver 127.0.0.1\noptions edns0\n' > "${ROOTFS_DIR}/etc/resolv.conf"
