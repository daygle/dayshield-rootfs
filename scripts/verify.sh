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
    /etc/unbound \
    /etc/nftables \
    /etc/suricata \
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
banner "Required service units"
for svc in \
    dayshield.service \
    nftables.service \
    unbound.service \
    suricata.service \
    crowdsec.service \
    wireguard.service \
    acme.service
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

# ── IPv6 disabled ─────────────────────────────────────────────────────────────
banner "IPv6 disabled"

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
    if grep -q 'blacklist ipv6' "${MODPROBE_CONF}"; then
        ok "IPv6 kernel module blacklisted"
    else
        fail "IPv6 kernel module blacklist entry missing"
    fi
else
    fail "missing modprobe IPv6 disable file"
fi

if [ -f "${ROOTFS_DIR}/etc/hosts" ]; then
    if grep -qE '^\s*::' "${ROOTFS_DIR}/etc/hosts" || \
       grep -q 'ip6-' "${ROOTFS_DIR}/etc/hosts"; then
        fail "/etc/hosts still contains IPv6 entries"
    else
        ok "/etc/hosts has no IPv6 entries"
    fi
fi

# ── nftables config ───────────────────────────────────────────────────────────
banner "nftables config"
NFTABLES_CONF="${ROOTFS_DIR}/etc/nftables.conf"
if [ -f "${NFTABLES_CONF}" ]; then
    ok "nftables.conf exists"
    if grep -qiE '^[[:space:]]*(table[[:space:]]+ip6|table[[:space:]]+inet6)' "${NFTABLES_CONF}"; then
        fail "nftables.conf contains ip6/inet6 table (IPv6 not fully disabled)"
    else
        ok "nftables.conf contains no ip6/inet6 tables"
    fi
    # Validate syntax if nft is available and we have sufficient privilege
    if command -v nft >/dev/null 2>&1; then
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
else
    fail "missing nftables.conf"
fi

# ── unbound config ────────────────────────────────────────────────────────────
banner "unbound config"
UNBOUND_CONF="${ROOTFS_DIR}/etc/unbound/unbound.conf"
if [ -f "${UNBOUND_CONF}" ]; then
    ok "unbound.conf exists"
    if grep -q 'do-ip6: no' "${UNBOUND_CONF}"; then
        ok "unbound IPv6 disabled (do-ip6: no)"
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
