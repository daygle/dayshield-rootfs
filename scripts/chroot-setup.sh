#!/bin/sh
# chroot-setup.sh - Configure the chroot environment for DayShield.
# Must be run after mmdebstrap with ROOTFS_DIR and CONFIG_DIR set.
# POSIX shell compatible.

set -eu

: "${ROOTFS_DIR:?ROOTFS_DIR must be set}"
: "${CONFIG_DIR:?CONFIG_DIR must be set}"

# ── Hostname ─────────────────────────────────────────────────────────────────
printf '  -> Setting hostname to dayshield\n'
printf 'dayshield\n' > "${ROOTFS_DIR}/etc/hostname"

# ── Root password (live/installer session only) ───────────────────────────────
# Default: dayshield  -  must be changed after installation via the web UI.
printf '  -> Setting default root password\n'
printf 'root:dayshield\n' | chroot "${ROOTFS_DIR}" chpasswd

# ── /etc/hosts ────────────────────────────────────────────────────────────────
printf '  -> Writing /etc/hosts (IPv4 only)\n'
cat > "${ROOTFS_DIR}/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   dayshield
EOF

# ── /etc/fstab ────────────────────────────────────────────────────────────────
# A minimal fstab must exist so systemd-remount-fs.service and local-fs.target
# can operate correctly on the installed system.  The installer is expected to
# replace the LABEL values with real partition UUIDs after partitioning.
printf '  -> Writing placeholder /etc/fstab\n'
cat > "${ROOTFS_DIR}/etc/fstab" <<'EOF'
# /etc/fstab: static file system information.
# NOTE: The installer replaces these entries with UUID= lines.
#
# <file system>         <mount point>  <type>  <options>          <dump>  <pass>
LABEL=dayshield-root    /              ext4    errors=remount-ro  0       1
EOF

# Help initramfs-tools resolve the root fs type while building inside chroot.
# The installer always formats root as ext4.
mkdir -p "${ROOTFS_DIR}/etc/initramfs-tools/conf.d"
cat > "${ROOTFS_DIR}/etc/initramfs-tools/conf.d/dayshield-rootfs.conf" <<'EOF'
ROOTFSTYPE=ext4
EOF

# Skip remount-fs in installer live-boot mode. The live root uses
# overlay/squashfs semantics and the placeholder fstab labels are intended for
# the installed target where the installer writes final UUID-based entries.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/systemd-remount-fs.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/systemd-remount-fs.service.d/dayshield-installer.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!installer
EOF

# Unbound is not required in installer-live mode and may fail before the final
# installed network plan is applied. Skip it for installer boots.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/unbound.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/unbound.service.d/dayshield-installer.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!installer
EOF

# Kea DHCP should only start when a concrete config exists. This prevents
# boot-time failures on systems where the package default unit is enabled but
# /etc/dayshield/kea-dhcp4.conf has not been written yet.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/kea-dhcp4-server.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/kea-dhcp4-server.service.d/dayshield-guard.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!installer
ConditionPathExists=/etc/dayshield/kea-dhcp4.conf

[Service]
ConfigurationDirectoryMode=750
EOF

# ── DayShield directory layout ───────────────────────────────────────────────
printf '  -> Creating /etc/dayshield directory tree\n'
mkdir -p \
    "${ROOTFS_DIR}/etc/dayshield/config" \
    "${ROOTFS_DIR}/etc/dayshield/certs" \
    "${ROOTFS_DIR}/etc/dayshield/logs"
chmod 700 "${ROOTFS_DIR}/etc/dayshield/certs"

printf '  -> Creating /etc/wireguard directory\n'
mkdir -p "${ROOTFS_DIR}/etc/wireguard"
chmod 700 "${ROOTFS_DIR}/etc/wireguard"

printf '  -> Creating /var/lib/dayshield directory tree\n'
mkdir -p \
    "${ROOTFS_DIR}/var/lib/dayshield/aliases" \
    "${ROOTFS_DIR}/var/lib/dayshield/crowdsec" \
    "${ROOTFS_DIR}/var/lib/dayshield/acme"

printf '  -> Creating cloudflared runtime directories\n'
mkdir -p \
    "${ROOTFS_DIR}/etc/cloudflared" \
    "${ROOTFS_DIR}/var/lib/cloudflared"

# ── Install base configs ──────────────────────────────────────────────────────
printf '  -> Installing sysctl.conf\n'
cp "${CONFIG_DIR}/sysctl.conf" "${ROOTFS_DIR}/etc/sysctl.d/99-dayshield.conf"

printf '  -> Installing nftables.conf\n'
mkdir -p "${ROOTFS_DIR}/etc/nftables" "${ROOTFS_DIR}/etc/nftables.d"
cp "${CONFIG_DIR}/nftables.conf" "${ROOTFS_DIR}/etc/nftables.conf"

printf '  -> Installing unbound.conf\n'
mkdir -p "${ROOTFS_DIR}/etc/unbound"
cp "${CONFIG_DIR}/unbound.conf" "${ROOTFS_DIR}/etc/unbound/unbound.conf"

printf '  -> Installing suricata.yaml\n'
mkdir -p "${ROOTFS_DIR}/etc/suricata"
cp "${CONFIG_DIR}/suricata.yaml" "${ROOTFS_DIR}/etc/suricata/suricata.yaml"

printf '  -> Creating /etc/chrony directory (for NTP timesyncd/chrony config)\n'
mkdir -p "${ROOTFS_DIR}/etc/chrony"

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

# ── systemd-networkd-wait-online - don't block boot ──────────────────────────
# In installer mode there are no configured interfaces yet (wizard hasn't run),
# so wait-online would hang forever.  On installed systems, only wait for ANY
# one interface to come up (not all), with a 30-second cap.
printf '  -> Dropping systemd-networkd-wait-online override\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/systemd-networkd-wait-online.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/systemd-networkd-wait-online.service.d/dayshield.conf" <<'EOF'
[Unit]
# Skip entirely during installer live-boot - interfaces are unconfigured
ConditionKernelCommandLine=!installer

[Service]
# On the installed system: wait for any one interface, give up after 30 s
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=30
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
for unit in \
    unbound.service \
    nftables.service \
    dayshield-disable-offloads.service \
    suricata.service \
    crowdsec.service \
    cloudflared.service \
    wireguard.service \
    acme.service \
    acme.timer \
    console-wizard.service
do
    src="${CONFIG_DIR}/services/${unit}"
    if [ -f "${src}" ]; then
        cp "${src}" "${ROOTFS_DIR}/etc/systemd/system/${unit}"
    fi
done

# ── Install DayShield console wizard ─────────────────────────────────────────
printf '  -> Installing dayshield-console\n'
cp "${CONFIG_DIR}/dayshield/console-wizard.sh" \
    "${ROOTFS_DIR}/usr/local/bin/dayshield-console"
chmod 755 "${ROOTFS_DIR}/usr/local/bin/dayshield-console"

# Shared installer finalization path for console/web installers
printf '  -> Installing shared installer finalization script\n'
mkdir -p "${ROOTFS_DIR}/usr/local/lib/dayshield"
cp "${CONFIG_DIR}/dayshield/installer-finalize.sh" \
    "${ROOTFS_DIR}/usr/local/lib/dayshield/installer-finalize.sh"
chmod 755 "${ROOTFS_DIR}/usr/local/lib/dayshield/installer-finalize.sh"

printf '  -> Installing NIC offload disable helper\n'
cp "${CONFIG_DIR}/dayshield/disable-offloads.sh" \
    "${ROOTFS_DIR}/usr/local/lib/dayshield/disable-offloads.sh"
chmod 755 "${ROOTFS_DIR}/usr/local/lib/dayshield/disable-offloads.sh"

# Post-login menu hook for installed system (root local console logins only)
printf '  -> Installing console login profile hook\n'
mkdir -p "${ROOTFS_DIR}/etc/profile.d"
cp "${CONFIG_DIR}/dayshield/console-login-profile.sh" \
    "${ROOTFS_DIR}/etc/profile.d/dayshield-console.sh"
chmod 644 "${ROOTFS_DIR}/etc/profile.d/dayshield-console.sh"
