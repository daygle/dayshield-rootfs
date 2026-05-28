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
printf '  -> Writing /etc/hosts (IPv4 + IPv6 localhost)\n'
cat > "${ROOTFS_DIR}/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   dayshield
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# ── /etc/fstab ────────────────────────────────────────────────────────────────
# A minimal fstab must exist so systemd-remount-fs.service and local-fs.target
# can operate correctly on the installed system. The installer is expected to
# replace the LABEL values with real partition UUIDs after partitioning.
printf '  -> Writing placeholder /etc/fstab\n'
cat > "${ROOTFS_DIR}/etc/fstab" <<'EOF'
# /etc/fstab: static file system information.
# NOTE: The installer replaces these entries with UUID= lines for both
#       DAYSHIELD_ROOT (the deployment root filesystem mounted at /) and
#       DAYSHIELD_STATE (/var persistent state)
#       to support OSTree-style immutable rootfs + mutable runtime data separation.
#
# <file system>         <mount point>  <type>  <options>          <dump>  <pass>
LABEL=DAYSHIELD_ROOT    /              ext4    defaults,noatime   0       1
LABEL=DAYSHIELD_STATE   /var           ext4    defaults,noatime   0       2
LABEL=DAYSHIELD_BOOT    /boot          ext4    defaults,noatime   0       2
LABEL=DS_EFI            /boot/efi      vfat    umask=0077         0       2
EOF

# ── Journald persistence ─────────────────────────────────────────────────────
# Force persistent journald storage so historical/system logs are available
# after clean install without requiring runtime recovery commands.
printf '  -> Configuring persistent journald storage\n'
mkdir -p "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/journald.conf.d/10-storage.conf" <<'EOF'
[Journal]
Storage=persistent
EOF
mkdir -p "${ROOTFS_DIR}/var/log/journal"

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

# Debian's optional unbound-resolvconf helper expects /sbin/resolvconf.
# DayShield does not ship resolvconf, so mask the helper to avoid noisy
# skipped-condition logs at boot.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/unbound-resolvconf.service"

# Disable the optional systemd SSH VSOCK generator on images that do not
# expose an AF_VSOCK channel. This prevents systemd-ssh-generator from
# failing at boot. Generators are suppressed via /etc/systemd/system-generators/
# (not /etc/systemd/system/ where service units live).
mkdir -p "${ROOTFS_DIR}/etc/systemd/system-generators"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system-generators/systemd-ssh-generator"

# Kea DHCP should only start when the packaged config path it actually reads
# exists. DayShield keeps /etc/dayshield/*.conf as canonical, but the distro
# Kea units still load /etc/kea/*.conf and will fail hard if the compatibility
# file is missing.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/kea-dhcp4-server.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/kea-dhcp4-server.service.d/dayshield-guard.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!installer
ConditionPathExists=/etc/kea/kea-dhcp4.conf

[Service]
ConfigurationDirectoryMode=755
EOF

mkdir -p "${ROOTFS_DIR}/etc/systemd/system/kea-dhcp6-server.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/kea-dhcp6-server.service.d/dayshield-guard.conf" <<'EOF'
[Unit]
ConditionKernelCommandLine=!installer
ConditionPathExists=/etc/kea/kea-dhcp6.conf

[Service]
ConfigurationDirectoryMode=755
EOF

mkdir -p "${ROOTFS_DIR}/etc/dayshield" "${ROOTFS_DIR}/etc/kea" "${ROOTFS_DIR}/var/log/kea" "${ROOTFS_DIR}/var/log/dayshield" "${ROOTFS_DIR}/var/lib/kea"
chmod 755 "${ROOTFS_DIR}/etc/kea"
cat > "${ROOTFS_DIR}/etc/dayshield/kea-dhcp4.conf" <<'EOF'
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": []
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [
          { "output": "/var/log/kea/kea-dhcp4.log" }
        ],
        "severity": "INFO"
      }
    ]
  }
}
EOF
chmod 644 "${ROOTFS_DIR}/etc/dayshield/kea-dhcp4.conf"
cp "${ROOTFS_DIR}/etc/dayshield/kea-dhcp4.conf" "${ROOTFS_DIR}/etc/kea/kea-dhcp4.conf"
chmod 644 "${ROOTFS_DIR}/etc/kea/kea-dhcp4.conf"

cat > "${ROOTFS_DIR}/etc/dayshield/kea-dhcp6.conf" <<'EOF'
{
  "Dhcp6": {
    "interfaces-config": {
      "interfaces": []
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases6.csv"
    },
    "subnet6": [],
    "loggers": [
      {
        "name": "kea-dhcp6",
        "output_options": [
          { "output": "/var/log/kea/kea-dhcp6.log" }
        ],
        "severity": "INFO"
      }
    ]
  }
}
EOF
chmod 644 "${ROOTFS_DIR}/etc/dayshield/kea-dhcp6.conf"
cp "${ROOTFS_DIR}/etc/dayshield/kea-dhcp6.conf" "${ROOTFS_DIR}/etc/kea/kea-dhcp6.conf"
chmod 644 "${ROOTFS_DIR}/etc/kea/kea-dhcp6.conf"

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

printf '  -> Creating DHCP client state directories\n'
mkdir -p \
    "${ROOTFS_DIR}/etc/dhcp" \
    "${ROOTFS_DIR}/var/lib/dhcp" \
    "${ROOTFS_DIR}/var/lib/dhclient"

printf '  -> Creating /var/lib/dayshield directory tree\n'
mkdir -p \
    "${ROOTFS_DIR}/var/lib/dayshield/aliases" \
    "${ROOTFS_DIR}/var/lib/dayshield/config" \
    "${ROOTFS_DIR}/var/lib/dayshield/crowdsec" \
    "${ROOTFS_DIR}/var/lib/dayshield/acme"
# nft-ifaces.conf lives in /var (OSTree-immune) so rootfs updates never clobber
# user interface assignments. The /etc symlink below makes nftables find it at
# the path it has always included.
cat > "${ROOTFS_DIR}/var/lib/dayshield/config/nft-ifaces.conf" <<'EOF'
# /var/lib/dayshield/config/nft-ifaces.conf — interface definitions for nftables.
# Written by the installer / console wizard when interfaces are assigned.
# Uses loopback as a safe placeholder until the wizard runs.
define WAN_IF = lo
define LAN_IF = lo
EOF

printf '  -> Creating OSTree sysroot and writable state layout\n'
# /sysroot/ostree/repo is the canonical OSTree sysroot location.
# /ostree/repo is kept for compatibility with tooling expecting that path.
# Both receive a minimal valid repo skeleton so `ostree admin status` does not
# fail with "opendir(objects): No such file or directory" on fresh installs.
for _repo_dir in \
    "${ROOTFS_DIR}/sysroot/ostree/repo" \
    "${ROOTFS_DIR}/ostree/repo"
do
    mkdir -p \
        "${_repo_dir}/objects" \
        "${_repo_dir}/tmp" \
        "${_repo_dir}/refs/heads" \
        "${_repo_dir}/refs/remotes" \
        "${_repo_dir}/state" \
        "${_repo_dir}/extensions"
    cat > "${_repo_dir}/config" <<'OSTREE_CONFIG'
[core]
repo_version=1
mode=bare
OSTREE_CONFIG
done
mkdir -p \
    "${ROOTFS_DIR}/ostree/deploy" \
    "${ROOTFS_DIR}/var/ostree" \
    "${ROOTFS_DIR}/var/lib/dayshield/ostree" \
    "${ROOTFS_DIR}/etc/ostree/remotes.d" \
    "${ROOTFS_DIR}/usr/local/share/dayshield-updates"
cat > "${ROOTFS_DIR}/etc/ostree/remotes.d/dayshield.conf" <<'EOF'
[remote "dayshield"]
# Installer/finalizer should replace this placeholder with the production update endpoint
# (for example: sed -i 's|@DAYSHIELD_OSTREE_REMOTE_URL@|https://updates.example.com/ostree/repo|').
url=@DAYSHIELD_OSTREE_REMOTE_URL@
gpg-verify=true
EOF
cat > "${ROOTFS_DIR}/usr/local/share/dayshield-updates/README.txt" <<'EOF'
This directory stores OSTree update metadata generated during rootfs builds.
It is consumed by DayShield core/UI update workflows.
EOF

printf '  -> Creating cloudflared runtime directories\n'
mkdir -p \
    "${ROOTFS_DIR}/etc/cloudflared" \
    "${ROOTFS_DIR}/var/lib/cloudflared"

printf '  -> Installing cloudflared binary from configured source\n'
mkdir -p "${ROOTFS_DIR}/usr/bin"
CLOUDFLARED_TARGET="${ROOTFS_DIR}/usr/bin/cloudflared"
_CLOUDFLARED_DEFAULT_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
_CLOUDFLARED_DEFAULT_CHECKSUM_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.sha256"
if [ -n "${CLOUDFLARED_PATH:-}" ] && [ -f "${CLOUDFLARED_PATH}" ]; then
    cp "${CLOUDFLARED_PATH}" "${CLOUDFLARED_TARGET}"
    chmod 755 "${CLOUDFLARED_TARGET}"
    printf '    Installed cloudflared from CLOUDFLARED_PATH=%s\n' "${CLOUDFLARED_PATH}"
elif [ -f "${CONFIG_DIR}/cloudflared/cloudflared" ]; then
    cp "${CONFIG_DIR}/cloudflared/cloudflared" "${CLOUDFLARED_TARGET}"
    chmod 755 "${CLOUDFLARED_TARGET}"
    printf '    Installed cloudflared from config/cloudflared/cloudflared\n'
else
    _url="${CLOUDFLARED_URL:-${_CLOUDFLARED_DEFAULT_URL}}"
    # When using the default URL, auto-derive the checksum URL from the same release.
    # Set CLOUDFLARED_CHECKSUM_URL='' to explicitly skip verification.
    # Default cloudflared releases do not always publish a .sha256 asset.
    _cksum_url="${CLOUDFLARED_CHECKSUM_URL:-}"
    if [ -z "${_cksum_url}" ] && [ -z "${CLOUDFLARED_URL:-}" ]; then
        _cksum_url="${_CLOUDFLARED_DEFAULT_CHECKSUM_URL}"
    fi
    printf '    Downloading cloudflared from %s\n' "${_url}"
    _cf_tmp="$(mktemp)"
    if ! wget -qO "${_cf_tmp}" "${_url}"; then
        printf 'ERROR: failed to download cloudflared from %s\n' "${_url}" >&2
        rm -f "${_cf_tmp}"
        exit 1
    fi
    if [ -n "${_cksum_url}" ]; then
        _cksum_tmp="$(mktemp)"
        if wget -qO "${_cksum_tmp}" "${_cksum_url}"; then
            # .sha256 files contain "hash  filename" or just "hash"
            _cf_expected="$(awk '{print $1}' "${_cksum_tmp}")"
            if [ -n "${_cf_expected}" ]; then
                _cf_actual="$(sha256sum "${_cf_tmp}" | awk '{print $1}')"
                if [ "${_cf_actual}" != "${_cf_expected}" ]; then
                    printf 'ERROR: cloudflared SHA256 mismatch\n  expected: %s\n  actual:   %s\n' "${_cf_expected}" "${_cf_actual}" >&2
                    rm -f "${_cf_tmp}" "${_cksum_tmp}"
                    exit 1
                fi
                printf '    SHA256 verified: %s\n' "${_cf_actual}"
            else
                printf 'WARNING: cloudflared-linux-amd64 not found in checksums.txt; skipping verification\n' >&2
            fi
        else
            if [ -n "${CLOUDFLARED_CHECKSUM_URL:-}" ]; then
                printf 'WARNING: could not fetch cloudflared checksums from %s; skipping verification\n' "${_cksum_url}" >&2
            else
                printf '    cloudflared checksum asset not available for this release; skipping verification\n'
            fi
        fi
        rm -f "${_cksum_tmp}"
    fi
    cp "${_cf_tmp}" "${CLOUDFLARED_TARGET}"
    rm -f "${_cf_tmp}"
    chmod 755 "${CLOUDFLARED_TARGET}"
    printf '    Installed cloudflared from %s\n' "${_url}"
fi

# ── Install base configs ──────────────────────────────────────────────────────
printf '  -> Installing sysctl.conf\n'
cp "${CONFIG_DIR}/sysctl.conf" "${ROOTFS_DIR}/etc/sysctl.d/99-dayshield.conf"

printf '  -> Installing nftables.conf\n'
mkdir -p "${ROOTFS_DIR}/etc/nftables" "${ROOTFS_DIR}/etc/nftables.d"
cp "${CONFIG_DIR}/nftables.conf" "${ROOTFS_DIR}/etc/nftables.conf"

printf '  -> Installing unbound.conf\n'
mkdir -p "${ROOTFS_DIR}/etc/unbound"
cp "${CONFIG_DIR}/unbound.conf" "${ROOTFS_DIR}/etc/unbound/unbound.conf"
# Base unbound.conf includes this DayShield-managed file. Keep it present so
# config validation and first boot do not fail before the DNS engine rewrites it.
: > "${ROOTFS_DIR}/etc/dayshield/unbound.conf"

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
# nft-ifaces.conf is stored in /var (OSTree-immune); expose it under /etc via
# a symlink so /etc/nftables.conf can include it at its canonical path.
ln -sf /var/lib/dayshield/config/nft-ifaces.conf \
    "${ROOTFS_DIR}/etc/dayshield/config/nft-ifaces.conf"

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
# IPv6 is disabled by sysctl/config by default so DayShield can enable it at runtime.
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
    else
        printf 'WARNING: service unit not found, skipping: %s\n' "${src}" >&2
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
