#!/bin/sh
# chroot-setup.sh — Configure the chroot environment for DayShield.
# Must be run after mmdebstrap with ROOTFS_DIR and CONFIG_DIR set.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"
: "${CONFIG_DIR:?CONFIG_DIR must be set}"

# ── Hostname ─────────────────────────────────────────────────────────────────
printf '  -> Setting hostname to dayshield\n'
printf 'dayshield\n' > "${ROOTFS_DIR}/etc/hostname"

# ── Root password (live/installer session only) ───────────────────────────────
# Default: dayshield  —  must be changed after installation via the web UI.
printf '  -> Setting default root password\n'
printf 'root:dayshield\n' | chroot "${ROOTFS_DIR}" chpasswd

# ── /etc/hosts ────────────────────────────────────────────────────────────────
printf '  -> Writing /etc/hosts (IPv4 only)\n'
cat > "${ROOTFS_DIR}/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   dayshield
EOF

# ── DayShield directory layout ───────────────────────────────────────────────
printf '  -> Creating /etc/dayshield directory tree\n'
mkdir -p \
    "${ROOTFS_DIR}/etc/dayshield/config" \
    "${ROOTFS_DIR}/etc/dayshield/certs" \
    "${ROOTFS_DIR}/etc/dayshield/logs"

printf '  -> Creating /var/lib/dayshield directory tree\n'
mkdir -p \
    "${ROOTFS_DIR}/var/lib/dayshield/aliases" \
    "${ROOTFS_DIR}/var/lib/dayshield/crowdsec" \
    "${ROOTFS_DIR}/var/lib/dayshield/acme"

# ── Install base configs ──────────────────────────────────────────────────────
printf '  -> Installing sysctl.conf\n'
cp "${CONFIG_DIR}/sysctl.conf" "${ROOTFS_DIR}/etc/sysctl.d/99-dayshield.conf"

printf '  -> Installing nftables.conf\n'
mkdir -p "${ROOTFS_DIR}/etc/nftables"
cp "${CONFIG_DIR}/nftables.conf" "${ROOTFS_DIR}/etc/nftables.conf"

printf '  -> Installing unbound.conf\n'
mkdir -p "${ROOTFS_DIR}/etc/unbound"
cp "${CONFIG_DIR}/unbound.conf" "${ROOTFS_DIR}/etc/unbound/unbound.conf"

printf '  -> Installing suricata.yaml\n'
mkdir -p "${ROOTFS_DIR}/etc/suricata"
cp "${CONFIG_DIR}/suricata.yaml" "${ROOTFS_DIR}/etc/suricata/suricata.yaml"

printf '  -> Installing crowdsec.yaml\n'
mkdir -p "${ROOTFS_DIR}/etc/crowdsec"
cp "${CONFIG_DIR}/crowdsec.yaml" "${ROOTFS_DIR}/etc/crowdsec/config.yaml"

printf '  -> Installing hardened sshd_config\n'
mkdir -p "${ROOTFS_DIR}/etc/ssh"
cp "${CONFIG_DIR}/sshd_config" "${ROOTFS_DIR}/etc/ssh/sshd_config"

# Copy DayShield config/certs placeholders
printf '  -> Copying config/dayshield skeleton\n'
cp -r "${CONFIG_DIR}/dayshield/config/." "${ROOTFS_DIR}/etc/dayshield/config/"
cp -r "${CONFIG_DIR}/dayshield/certs/."  "${ROOTFS_DIR}/etc/dayshield/certs/"

# ── systemd-networkd — deterministic interface naming ─────────────────────────
printf '  -> Configuring systemd-networkd\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/network"
cat > "${ROOTFS_DIR}/etc/systemd/network/10-dayshield-eth.network" <<'EOF'
[Match]
Name=eth0

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF

# ── Disable IPv6 system-wide via sysctl ───────────────────────────────────────
printf '  -> Disabling IPv6 in sysctl\n'
cat > "${ROOTFS_DIR}/etc/sysctl.d/99-disable-ipv6.conf" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# ── Kernel cmdline placeholder for bootloader ─────────────────────────────────
printf '  -> Writing kernel cmdline placeholder\n'
mkdir -p "${ROOTFS_DIR}/etc/dayshield"
cat > "${ROOTFS_DIR}/etc/dayshield/kernel-cmdline" <<'EOF'
# Extra kernel command-line parameters appended by the ISO builder.
# IPv6 is disabled at the kernel level via this file.
ipv6.disable=1
EOF

# ── Install systemd service units from config ─────────────────────────────────
printf '  -> Installing service unit files\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
for svc in unbound nftables suricata crowdsec wireguard acme; do
    src="${CONFIG_DIR}/services/${svc}.service"
    if [ -f "${src}" ]; then
        cp "${src}" "${ROOTFS_DIR}/etc/systemd/system/${svc}.service"
    fi
done
