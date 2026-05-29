#!/bin/sh
# enable-services.sh - Enable required systemd services in the rootfs.
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

# ── Early-boot firewall (sysinit) ────────────────────────────────────────────
enable_service sysinit.target nftables.service

# ── Multi-user services ───────────────────────────────────────────────────────
for svc in \
    unbound.service \
    dayshield-disable-offloads.service \
    suricata.service \
    ssh.service \
    dayshield.service \
    dayshield-boot-success.service
do
    enable_service multi-user.target "${svc}"
done

# console-wizard.service is installer-only and remains installed as a unit file,
# but the installed rootfs must not enable it by default.  The post-login
# profile hook launches the menu on installed systems without stealing tty1
# from getty during normal boots or image-update reboots.

# Optional services (acme, wireguard, crowdsec) are intentionally not enabled
# by default. They should be enabled by DayShield only after valid runtime
# configuration exists to avoid noisy failed states on first boot.
