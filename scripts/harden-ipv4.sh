#!/bin/sh
# harden-ipv4.sh - Apply IPv4-first hardening defaults to the rootfs.
# IPv6 remains disabled by sysctl/config by default, while the kernel module
# and localhost entries are kept so the DayShield global IPv6 setting can
# enable it at runtime.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"

# ── sysctl ────────────────────────────────────────────────────────────────────
printf '  -> Writing IPv6 default-off sysctl\n'
mkdir -p "${ROOTFS_DIR}/etc/sysctl.d"
cat > "${ROOTFS_DIR}/etc/sysctl.d/99-disable-ipv6.conf" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF

# ── Kernel module blacklist ───────────────────────────────────────────────────
printf '  -> Ensuring IPv6 kernel module remains available\n'
mkdir -p "${ROOTFS_DIR}/etc/modprobe.d"
rm -f "${ROOTFS_DIR}/etc/modprobe.d/disable-ipv6.conf"

# ── /etc/hosts - remove any IPv6 entries ─────────────────────────────────────
printf '  -> Ensuring IPv6 localhost entries exist\n'
HOSTS_FILE="${ROOTFS_DIR}/etc/hosts"
if [ -f "${HOSTS_FILE}" ]; then
    if ! grep -qE '^[[:space:]]*::1[[:space:]]' "${HOSTS_FILE}"; then
        printf '::1         localhost ip6-localhost ip6-loopback\n' >> "${HOSTS_FILE}"
    fi
fi

# ── nftables - verify no inet6 tables ────────────────────────────────────────
printf '  -> Verifying default nftables.conf contains no static ip6/inet6 tables\n'
NFTABLES_CONF="${ROOTFS_DIR}/etc/nftables.conf"
if [ -f "${NFTABLES_CONF}" ]; then
    if grep -qiE '^[[:space:]]*(table[[:space:]]+ip6|table[[:space:]]+inet6)' "${NFTABLES_CONF}"; then
        printf 'ERROR: default nftables.conf contains ip6/inet6 table definitions\n' >&2
        exit 1
    fi
fi

# ── unbound - ensure no IPv6 binds ───────────────────────────────────────────
printf '  -> Ensuring unbound keeps IPv6 disabled by default\n'
UNBOUND_CONF="${ROOTFS_DIR}/etc/unbound/unbound.conf"
if [ -f "${UNBOUND_CONF}" ]; then
    # Remove any do-ip6 yes and interface: ::1 lines
    sed -i 's/do-ip6:[[:space:]]*yes/do-ip6: no/' "${UNBOUND_CONF}"
    sed -i '/^[[:space:]]*interface:[[:space:]]*::1/d' "${UNBOUND_CONF}"
    sed -i '/^[[:space:]]*interface:[[:space:]]*::/d' "${UNBOUND_CONF}"
fi

printf '  -> IPv4-first hardening defaults complete\n'
