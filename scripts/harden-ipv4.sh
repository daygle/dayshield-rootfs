#!/bin/sh
# harden-ipv4.sh — Apply IPv4-only hardening to the rootfs.
# Disables IPv6 at every layer: sysctl, kernel modules, hosts,
# nftables, and unbound.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"

# ── sysctl ────────────────────────────────────────────────────────────────────
printf '  -> Writing IPv6 disable sysctl\n'
mkdir -p "${ROOTFS_DIR}/etc/sysctl.d"
cat > "${ROOTFS_DIR}/etc/sysctl.d/99-disable-ipv6.conf" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# ── Kernel module blacklist ───────────────────────────────────────────────────
printf '  -> Blacklisting IPv6 kernel module\n'
mkdir -p "${ROOTFS_DIR}/etc/modprobe.d"
printf 'blacklist ipv6\n' > "${ROOTFS_DIR}/etc/modprobe.d/disable-ipv6.conf"

# ── /etc/hosts — remove any IPv6 entries ─────────────────────────────────────
printf '  -> Stripping IPv6 entries from /etc/hosts\n'
if [ -f "${ROOTFS_DIR}/etc/hosts" ]; then
    # Remove lines starting with :: (IPv6 loopback and link-local)
    sed -i '/^[[:space:]]*::.*$/d' "${ROOTFS_DIR}/etc/hosts"
    # Remove lines containing "ip6-" hostnames written by Debian defaults
    sed -i '/ip6-/d' "${ROOTFS_DIR}/etc/hosts"
fi

# ── nftables — verify no inet6 tables ────────────────────────────────────────
printf '  -> Verifying nftables.conf contains no ip6/inet6 tables\n'
NFTABLES_CONF="${ROOTFS_DIR}/etc/nftables.conf"
if [ -f "${NFTABLES_CONF}" ]; then
    if grep -qiE '^[[:space:]]*(table[[:space:]]+ip6|table[[:space:]]+inet6)' "${NFTABLES_CONF}"; then
        printf 'ERROR: nftables.conf contains ip6/inet6 table definitions\n' >&2
        exit 1
    fi
fi

# ── unbound — ensure no IPv6 binds ───────────────────────────────────────────
printf '  -> Ensuring unbound does not bind IPv6\n'
UNBOUND_CONF="${ROOTFS_DIR}/etc/unbound/unbound.conf"
if [ -f "${UNBOUND_CONF}" ]; then
    # Remove any do-ip6 yes and interface: ::1 lines
    sed -i 's/do-ip6:[[:space:]]*yes/do-ip6: no/' "${UNBOUND_CONF}"
    sed -i '/^[[:space:]]*interface:[[:space:]]*::1/d' "${UNBOUND_CONF}"
    sed -i '/^[[:space:]]*interface:[[:space:]]*::/d' "${UNBOUND_CONF}"
fi

printf '  -> IPv4-only hardening complete\n'
