#!/bin/sh
# verify.sh - Verify the integrity and correctness of a DayShield rootfs.
# Can be run against an extracted rootfs directory (ROOTFS_DIR) or against a
# mounted/chroot target.
# POSIX shell compatible.

set -eu

ROOTFS_DIR="${ROOTFS_DIR:-/}"
PASS=0
FAIL=0

ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

banner() { printf '\n==> %s\n' "$*"; }

# ── Boot files ────────────────────────────────────────────────────────────────
banner "Boot files"
if ls "${ROOTFS_DIR}"/boot/vmlinuz-* >/dev/null 2>&1; then
    ok "kernel image found in /boot (vmlinuz-*)"
else
    fail "no kernel image in /boot - check that linux-image-amd64 was installed"
fi
if ls "${ROOTFS_DIR}"/boot/initrd.img-* >/dev/null 2>&1; then
    ok "initramfs found in /boot (initrd.img-*)"
else
    fail "no initramfs in /boot - run update-initramfs inside the chroot"
fi

# ── /etc/fstab ────────────────────────────────────────────────────────────────
banner "/etc/fstab"
if [ -f "${ROOTFS_DIR}/etc/fstab" ]; then
    ok "/etc/fstab exists"
    if grep -qE '^[^#].*[[:space:]]+/[[:space:]]' "${ROOTFS_DIR}/etc/fstab"; then
        ok "/etc/fstab has a root (/) mount entry"
    else
        fail "/etc/fstab is missing a root (/) mount entry - systemd will hang at local-fs.target"
    fi
else
    fail "missing /etc/fstab - systemd-remount-fs.service will fail and hang boot"
fi

# ── journald persistence ─────────────────────────────────────────────────────
banner "journald persistence"
JOURNALD_STORAGE_DROPIN="${ROOTFS_DIR}/etc/systemd/journald.conf.d/10-storage.conf"
if [ -f "${JOURNALD_STORAGE_DROPIN}" ] && \
   grep -Eq '^[[:space:]]*Storage[[:space:]]*=[[:space:]]*persistent[[:space:]]*$' "${JOURNALD_STORAGE_DROPIN}"; then
    ok "journald persistent storage drop-in exists"
else
    fail "missing journald persistent storage drop-in: /etc/systemd/journald.conf.d/10-storage.conf"
fi

if [ -d "${ROOTFS_DIR}/var/log/journal" ]; then
    ok "journal directory exists: /var/log/journal"
else
    fail "missing journal directory: /var/log/journal"
fi

# ── live-boot absent ──────────────────────────────────────────────────────────
# live-boot and live-config must NOT be installed in the rootfs that is
# written to disk.  Their initramfs hooks stall the installed system while
# searching for a live squashfs medium.  They are injected by dayshield-iso
# as a separate squashfs overlay for live-boot operation only.
banner "live-boot absent from installed rootfs"
if [ -f "${ROOTFS_DIR}/var/lib/dpkg/info/live-boot.list" ]; then
    fail "live-boot is installed - it will embed live hooks in the initramfs and stall boot"
else
    ok "live-boot not installed"
fi
if [ -f "${ROOTFS_DIR}/var/lib/dpkg/info/live-config.list" ]; then
    fail "live-config is installed - its systemd units interfere with installed-system startup"
else
    ok "live-config not installed"
fi

# ── Required directories ──────────────────────────────────────────────────────
banner "Required directories"
for dir in \
    /etc/dayshield/config \
    /etc/dayshield/certs \
    /etc/dayshield/logs \
    /var/lib/dayshield/aliases \
    /var/lib/dayshield/crowdsec \
    /var/lib/dayshield/acme \
    /etc/cloudflared \
    /var/lib/cloudflared \
    /etc/unbound \
    /etc/nftables \
    /etc/kea \
    /var/lib/kea \
    /var/log/kea \
    /var/log/dayshield \
    /etc/suricata \
    /etc/chrony \
    /etc/crowdsec \
    /etc/systemd/system
do
    if [ -d "${ROOTFS_DIR}${dir}" ]; then
        ok "directory exists: ${dir}"
    else
        fail "missing directory: ${dir}"
    fi
done

# ── Required service unit files ───────────────────────────────────────────────
banner "Required base service units"
for svc in \
    dayshield.service \
    nftables.service \
    unbound.service \
    dayshield-disable-offloads.service \
    suricata.service \
    console-wizard.service
do
    found=0
    for dir in \
        "${ROOTFS_DIR}/etc/systemd/system" \
        "${ROOTFS_DIR}/lib/systemd/system" \
        "${ROOTFS_DIR}/usr/lib/systemd/system"
    do
        if [ -f "${dir}/${svc}" ]; then
            ok "service unit exists: ${svc}"
            found=1
            break
        fi
    done
    if [ "${found}" -eq 0 ]; then
        fail "missing service unit: ${svc}"
    fi
done

# ── Installer/finalization contract ───────────────────────────────────────────
banner "Installer/finalization contract"
if [ -x "${ROOTFS_DIR}/usr/local/lib/dayshield/installer-finalize.sh" ]; then
    ok "shared installer finalization script exists"
else
    fail "missing shared installer finalization script: /usr/local/lib/dayshield/installer-finalize.sh"
fi

if [ -x "${ROOTFS_DIR}/usr/local/lib/dayshield/disable-offloads.sh" ]; then
    ok "NIC offload disable helper exists"
else
    fail "missing NIC offload disable helper: /usr/local/lib/dayshield/disable-offloads.sh"
fi

DS_INSTALLER_GUARD="${ROOTFS_DIR}/etc/systemd/system/dayshield.service.d/dayshield-installer.conf"
if [ -f "${DS_INSTALLER_GUARD}" ] && \
   grep -Eq '^[[:space:]]*ConditionKernelCommandLine[[:space:]]*=[[:space:]]*!installer[[:space:]]*$' "${DS_INSTALLER_GUARD}"; then
    ok "dayshield.service is guarded from installer-live boot"
else
    fail "dayshield.service missing installer-live guard ConditionKernelCommandLine=!installer"
fi

DS_ENGINE_PATHS="${ROOTFS_DIR}/etc/systemd/system/dayshield.service.d/dayshield-engine-paths.conf"
if [ -f "${DS_ENGINE_PATHS}" ] && \
   grep -Eq '^[[:space:]]*ReadWritePaths[[:space:]]*=[[:space:]]*/etc/kea[[:space:]]*$' "${DS_ENGINE_PATHS}"; then
    ok "dayshield.service can write the packaged Kea compatibility config path"
else
    fail "dayshield.service sandbox missing ReadWritePaths=/etc/kea"
fi

if [ -f "${DS_ENGINE_PATHS}" ] && \
   grep -Eq '^[[:space:]]*ReadWritePaths[[:space:]]*=[[:space:]]*/etc/ssh[[:space:]]*$' "${DS_ENGINE_PATHS}"; then
    ok "dayshield.service can write SSH runtime config"
else
    fail "dayshield.service sandbox missing ReadWritePaths=/etc/ssh"
fi

if [ -f "${DS_ENGINE_PATHS}" ] && \
   grep -Eq '^[[:space:]]*ReadWritePaths[[:space:]]*=[[:space:]]*/var/lib/kea[[:space:]]*$' "${DS_ENGINE_PATHS}"; then
    ok "dayshield.service can write Kea lease database path (/var/lib/kea)"
else
    fail "dayshield.service sandbox missing ReadWritePaths=/var/lib/kea"
fi

if [ -f "${DS_ENGINE_PATHS}" ] && \
   grep -Eq '^[[:space:]]*ReadWritePaths[[:space:]]*=[[:space:]]*/var/log/dayshield[[:space:]]*$' "${DS_ENGINE_PATHS}"; then
    ok "dayshield.service can write DayShield durable log path (/var/log/dayshield)"
else
    fail "dayshield.service sandbox missing ReadWritePaths=/var/log/dayshield"
fi

if [ -f "${ROOTFS_DIR}/etc/systemd/system/console-wizard.service" ] && \
   grep -Eq '^[[:space:]]*ConditionPathExists[[:space:]]*=[[:space:]]*!/installer-ui/index.html[[:space:]]*$' "${ROOTFS_DIR}/etc/systemd/system/console-wizard.service"; then
    ok "console/web installer mutual exclusion is configured"
else
    fail "console-wizard.service missing ConditionPathExists=!/installer-ui/index.html"
fi

KEA4_GUARD="${ROOTFS_DIR}/etc/systemd/system/kea-dhcp4-server.service.d/dayshield-guard.conf"
if [ -f "${KEA4_GUARD}" ] && \
   grep -Eq '^[[:space:]]*ConditionPathExists[[:space:]]*=[[:space:]]*/etc/kea/kea-dhcp4\.conf[[:space:]]*$' "${KEA4_GUARD}"; then
    ok "kea-dhcp4-server is guarded on the packaged compatibility config path"
else
    fail "kea-dhcp4-server missing guard for /etc/kea/kea-dhcp4.conf"
fi

KEA6_GUARD="${ROOTFS_DIR}/etc/systemd/system/kea-dhcp6-server.service.d/dayshield-guard.conf"
if [ -f "${KEA6_GUARD}" ] && \
   grep -Eq '^[[:space:]]*ConditionPathExists[[:space:]]*=[[:space:]]*/etc/kea/kea-dhcp6\.conf[[:space:]]*$' "${KEA6_GUARD}"; then
    ok "kea-dhcp6-server is guarded on the packaged compatibility config path"
else
    fail "kea-dhcp6-server missing guard for /etc/kea/kea-dhcp6.conf"
fi

INSTALLER_FINALIZE="${ROOTFS_DIR}/usr/local/lib/dayshield/installer-finalize.sh"
if [ -f "${INSTALLER_FINALIZE}" ] && \
   grep -Eq 'cp[[:space:]]+.*etc/dayshield/kea-dhcp4\.conf.*etc/kea/kea-dhcp4\.conf' "${INSTALLER_FINALIZE}"; then
    ok "installer finalization mirrors Kea DHCPv4 config to packaged path"
else
    fail "installer finalization does not mirror /etc/dayshield/kea-dhcp4.conf to /etc/kea/kea-dhcp4.conf"
fi

CONSOLE_WIZARD="${ROOTFS_DIR}/usr/local/lib/dayshield/console-wizard.sh"
if [ -f "${CONSOLE_WIZARD}" ] && \
   grep -q '/etc/dayshield/kea-dhcp4.conf' "${CONSOLE_WIZARD}" && \
   grep -q '/etc/kea/kea-dhcp4.conf' "${CONSOLE_WIZARD}" && \
   grep -Eq 'cp[[:space:]]+.*kea_conf.*kea_compat_conf' "${CONSOLE_WIZARD}"; then
    ok "console wizard mirrors Kea DHCPv4 config to packaged path"
else
    fail "console wizard does not mirror /etc/dayshield/kea-dhcp4.conf to /etc/kea/kea-dhcp4.conf"
fi

# ── dayshield-core binary ─────────────────────────────────────────────────────
banner "dayshield-core binary"
BINARY="${ROOTFS_DIR}/usr/local/sbin/dayshield-core"
if [ -f "${BINARY}" ]; then
    ok "binary exists: /usr/local/sbin/dayshield-core"
    if [ -x "${BINARY}" ]; then
        ok "binary is executable"
    else
        fail "binary is not executable: /usr/local/sbin/dayshield-core"
    fi
    # Detect placeholder installed when the real binary was absent at build time
    if grep -q 'not yet installed' "${BINARY}" 2>/dev/null; then
        fail "dayshield-core is a placeholder - real binary was not provided at build time; dayshield.service will fail on boot"
    else
        ok "dayshield-core is not a placeholder"
    fi
else
    fail "missing binary: /usr/local/sbin/dayshield-core"
fi

# ── Management UI assets (optional) ──────────────────────────────────────────
banner "Management UI assets"
UI_INDEX="${ROOTFS_DIR}/usr/local/share/dayshield-ui/index.html"
if [ -f "${UI_INDEX}" ]; then
    ok "management UI assets installed"
else
    printf '  [WARN] Management UI assets not installed: /usr/local/share/dayshield-ui/index.html missing\n'
    printf '         The installed system will not serve the management interface until\n'
    printf '         the rootfs is rebuilt with UI_DIR pointing at dayshield-ui/dist.\n'
fi

# ── Updater repository prerequisites ─────────────────────────────────────────
banner "Updater repository prerequisites"
if [ -x "${ROOTFS_DIR}/usr/bin/git" ]; then
    ok "git binary installed in rootfs"
else
    fail "git binary missing (/usr/bin/git) - GitHub updater cannot run"
fi

for repo in /opt/dayshield-core /opt/dayshield-ui /opt/dayshield-rootfs; do
    if [ -d "${ROOTFS_DIR}${repo}/.git" ]; then
        ok "seeded git repo exists: ${repo}"
    else
        fail "missing seeded git repo: ${repo}"
    fi
done

# ── IPv6 default-off but runtime-toggleable ──────────────────────────────────
banner "IPv6 default off"

SYSCTL_CONF="${ROOTFS_DIR}/etc/sysctl.d/99-disable-ipv6.conf"
if [ -f "${SYSCTL_CONF}" ]; then
    ok "sysctl IPv6 disable file exists"
    if grep -q 'net.ipv6.conf.all.disable_ipv6[[:space:]]*=[[:space:]]*1' "${SYSCTL_CONF}"; then
        ok "net.ipv6.conf.all.disable_ipv6 = 1"
    else
        fail "net.ipv6.conf.all.disable_ipv6 not set to 1"
    fi
else
    fail "missing sysctl IPv6 disable file: ${SYSCTL_CONF#${ROOTFS_DIR}}"
fi

MODPROBE_CONF="${ROOTFS_DIR}/etc/modprobe.d/disable-ipv6.conf"
if [ -f "${MODPROBE_CONF}" ]; then
    fail "IPv6 kernel module blacklist present; runtime IPv6 toggle would not work"
else
    ok "IPv6 kernel module is not blacklisted"
fi

KERNEL_CMDLINE="${ROOTFS_DIR}/etc/dayshield/kernel-cmdline"
if [ -f "${KERNEL_CMDLINE}" ]; then
    if grep -q 'ipv6.disable=1' "${KERNEL_CMDLINE}"; then
        fail "kernel cmdline hard-disables IPv6"
    else
        ok "kernel cmdline does not hard-disable IPv6"
    fi
fi

if [ -f "${ROOTFS_DIR}/etc/hosts" ]; then
    if grep -qE '^[[:space:]]*::1[[:space:]]' "${ROOTFS_DIR}/etc/hosts"; then
        ok "/etc/hosts has IPv6 localhost entries for runtime enablement"
    else
        fail "/etc/hosts is missing IPv6 localhost entries"
    fi
fi

# ── nftables config ───────────────────────────────────────────────────────────
banner "nftables config"
NFTABLES_CONF="${ROOTFS_DIR}/etc/nftables.conf"
if [ -f "${NFTABLES_CONF}" ]; then
    ok "nftables.conf exists"
    if grep -qiE '^[[:space:]]*(table[[:space:]]+ip6|table[[:space:]]+inet6)' "${NFTABLES_CONF}"; then
        fail "default nftables.conf contains static ip6/inet6 table"
    else
        ok "default nftables.conf contains no static ip6/inet6 tables"
    fi
    # Validate syntax if nft is available and we have sufficient privilege.
    # When verifying an extracted rootfs, use chroot so absolute include paths
    # inside nftables.conf resolve to the rootfs tree rather than the host.
    if command -v nft >/dev/null 2>&1; then
        if [ "${ROOTFS_DIR}" != "/" ] && command -v chroot >/dev/null 2>&1; then
            if chroot "${ROOTFS_DIR}" nft --check --file /etc/nftables.conf >/dev/null 2>&1; then
                ok "nftables ruleset syntax valid"
            else
                NFT_ERR="$(chroot "${ROOTFS_DIR}" nft --check --file /etc/nftables.conf 2>&1)" || true
                fail "nftables ruleset syntax error: ${NFT_ERR}"
            fi
        else
            NFT_RC=0
            NFT_ERR="$(nft --check --file "${NFTABLES_CONF}" 2>&1)" || NFT_RC=$?
            NFT_RC="${NFT_RC:-0}"
            if [ "${NFT_RC}" -eq 0 ]; then
                ok "nftables ruleset syntax valid"
            elif printf '%s' "${NFT_ERR}" | grep -q 'Operation not permitted'; then
                printf '  [SKIP] nftables syntax check requires elevated privileges\n'
            else
                fail "nftables ruleset syntax error: ${NFT_ERR}"
            fi
        fi
    fi
else
    fail "missing nftables.conf"
fi

# ── unbound config ────────────────────────────────────────────────────────────
banner "unbound config"
UNBOUND_CONF="${ROOTFS_DIR}/etc/unbound/unbound.conf"
if [ -f "${UNBOUND_CONF}" ]; then
    ok "unbound.conf exists"
    if grep -q 'do-ip6: no' "${UNBOUND_CONF}"; then
        ok "unbound IPv6 disabled by default (do-ip6: no)"
    else
        fail "unbound do-ip6 not set to no"
    fi
    # Validate config if unbound-checkconf is available
    if command -v unbound-checkconf >/dev/null 2>&1; then
        if unbound-checkconf "${UNBOUND_CONF}" >/dev/null 2>&1; then
            ok "unbound config validates"
        else
            fail "unbound config validation failed"
        fi
    fi
else
    fail "missing unbound.conf"
fi

# ── suricata config ───────────────────────────────────────────────────────────
banner "suricata config"
SURICATA_CONF="${ROOTFS_DIR}/etc/suricata/suricata.yaml"
if [ -f "${SURICATA_CONF}" ]; then
    ok "suricata.yaml exists"
    if command -v suricata >/dev/null 2>&1; then
        if suricata -T -c "${SURICATA_CONF}" >/dev/null 2>&1; then
            ok "suricata config validates"
        else
            fail "suricata config validation failed"
        fi
    fi
else
    fail "missing suricata.yaml"
fi

# ── crowdsec config ───────────────────────────────────────────────────────────
banner "crowdsec config"
CROWDSEC_CONF="${ROOTFS_DIR}/etc/crowdsec/config.yaml"
if [ -f "${CROWDSEC_CONF}" ]; then
    ok "crowdsec config.yaml exists"
else
    fail "missing crowdsec config.yaml"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n'
printf '==> Verification complete: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
