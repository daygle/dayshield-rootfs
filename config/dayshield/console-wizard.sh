#!/usr/bin/env bash
# dayshield-console - DayShield interactive console management wizard.
#
# Modelled after the OPNsense/pfSense console menu.  Runs on tty1 in both the
# live installer session and the installed system.  Live mode is detected
# automatically from /proc/cmdline.

set -euo pipefail

DAYSHIELD_VERSION="$(cat /etc/dayshield/version 2>/dev/null | tr -d '[:space:]')"
DAYSHIELD_VERSION="${DAYSHIELD_VERSION:-unknown}"
DAYSHIELD_SITE="https://github.com/daygle/dayshield"

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------
LIVE_MODE=false
grep -qw 'installer' /proc/cmdline 2>/dev/null && LIVE_MODE=true

# Invocation mode:
#   boot  - started by systemd service during installer/live boot
#   login - started from /etc/profile.d after root login
CONSOLE_MODE="${DAYSHIELD_CONSOLE_MODE:-}"
if [[ -z "${CONSOLE_MODE}" ]]; then
    if $LIVE_MODE; then
        CONSOLE_MODE="boot"
    else
        CONSOLE_MODE="login"
    fi
fi

# ---------------------------------------------------------------------------
# Persistent state
# ---------------------------------------------------------------------------
WAN_IFACE=""
WAN_TYPE="dhcp"      # dhcp | pppoe
WAN_PPPOE_USER=""
WAN_PPPOE_PASS=""
LAN_IFACE=""
LAN_IP=""
LAN_PREFIX=""
LAN_DHCP_ENABLE=""
LAN_DHCP_START=""
LAN_DHCP_END=""
LAN_DHCP_LEASE="12h"
FIRST_SETUP_DONE=""
ORIG_CONSOLE_LOGLEVEL=""

# Associative arrays populated from core config JSON (/etc/dayshield/config/config.json)
declare -A _CORE_IFACE_ROLE=()
declare -A _CORE_IFACE_DESC=()
_CORE_CONFIG_LOADED=0
DAYSHIELD_CORE_CONFIG="/etc/dayshield/config/config.json"

_is_valid_iface_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

_is_safe_text() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

_console_quiet_enter() {
    # Keep kernel printk output from disrupting interactive prompts on tty1.
    if [[ -z "${ORIG_CONSOLE_LOGLEVEL}" ]] && [[ -r /proc/sys/kernel/printk ]] && [[ -w /proc/sys/kernel/printk ]]; then
        ORIG_CONSOLE_LOGLEVEL="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null || true)"
        # Show only emergency-level kernel messages on the console.
        printf '1\n' > /proc/sys/kernel/printk 2>/dev/null || true
    fi
}

_console_quiet_exit() {
    if [[ -n "${ORIG_CONSOLE_LOGLEVEL}" ]] && [[ -w /proc/sys/kernel/printk ]]; then
        printf '%s\n' "${ORIG_CONSOLE_LOGLEVEL}" > /proc/sys/kernel/printk 2>/dev/null || true
    fi
}

_load_state() {
    local state_file="/etc/dayshield/console-state"
    local owner perms key value_b64 value
    if [[ ! -f "${state_file}" ]]; then
        return
    fi
    [[ -L "${state_file}" ]] && return
    owner="$(stat -c '%u' "${state_file}" 2>/dev/null || true)"
    perms="$(stat -c '%A' "${state_file}" 2>/dev/null || true)"
    if [[ "${owner}" != "0" ]]; then
        printf '  [WARN] ignoring unsafe state file owner: %s\n' "${state_file}" >&2
        return
    fi
    if [[ "${#perms}" -ge 10 ]] && { [[ "${perms:5:1}" == "w" ]] || [[ "${perms:8:1}" == "w" ]]; }; then
        printf '  [WARN] ignoring group/other writable state file: %s\n' "${state_file}" >&2
        return
    fi
    while IFS='=' read -r key value_b64; do
        [[ -n "${key}" ]] || continue
        value="$(printf '%s' "${value_b64}" | base64 -d 2>/dev/null || true)"
        if ! _is_safe_text "${value}"; then
            continue
        fi
        case "${key}" in
            WAN_IFACE)
                if [[ -z "${value}" ]] || _is_valid_iface_name "${value}"; then
                    WAN_IFACE="${value}"
                fi
                ;;
            WAN_TYPE)
                if [[ "${value}" == "dhcp" || "${value}" == "pppoe" || -z "${value}" ]]; then
                    WAN_TYPE="${value}"
                fi
                ;;
            WAN_PPPOE_USER) WAN_PPPOE_USER="${value}" ;;
            WAN_PPPOE_PASS) WAN_PPPOE_PASS="${value}" ;;
            LAN_IFACE)
                if [[ -z "${value}" ]] || _is_valid_iface_name "${value}"; then
                    LAN_IFACE="${value}"
                fi
                ;;
            LAN_IP)
                if [[ -z "${value}" ]] || _is_valid_ipv4 "${value}"; then
                    LAN_IP="${value}"
                fi
                ;;
            LAN_PREFIX)
                if [[ -z "${value}" ]] || ([[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 32 ))); then
                    LAN_PREFIX="${value}"
                fi
                ;;
            LAN_DHCP_ENABLE)
                if [[ "${value}" == "yes" || "${value}" == "no" || -z "${value}" ]]; then
                    LAN_DHCP_ENABLE="${value}"
                fi
                ;;
            LAN_DHCP_START)
                if [[ -z "${value}" ]] || _is_valid_ipv4 "${value}"; then
                    LAN_DHCP_START="${value}"
                fi
                ;;
            LAN_DHCP_END)
                if [[ -z "${value}" ]] || _is_valid_ipv4 "${value}"; then
                    LAN_DHCP_END="${value}"
                fi
                ;;
            LAN_DHCP_LEASE)
                if [[ -z "${value}" ]] || [[ "${value}" =~ ^[0-9]+[smhd]$ ]]; then
                    LAN_DHCP_LEASE="${value}"
                fi
                ;;
            FIRST_SETUP_DONE)
                if [[ "${value}" == "yes" || -z "${value}" ]]; then
                    FIRST_SETUP_DONE="${value}"
                fi
                ;;
        esac
    done < "${state_file}"
}

_save_state() {
    local state_file tmp_file old_umask
    state_file="/etc/dayshield/console-state"
    mkdir -p /etc/dayshield
    old_umask="$(umask)"
    umask 077
    tmp_file="$(mktemp -p /etc/dayshield console-state.XXXXXX)"
    {
        printf 'WAN_IFACE=%s\n' "$(printf '%s' "${WAN_IFACE}" | base64 | tr -d '\n')"
        printf 'WAN_TYPE=%s\n' "$(printf '%s' "${WAN_TYPE}" | base64 | tr -d '\n')"
        printf 'WAN_PPPOE_USER=%s\n' "$(printf '%s' "${WAN_PPPOE_USER}" | base64 | tr -d '\n')"
        printf 'WAN_PPPOE_PASS=%s\n' "$(printf '%s' "${WAN_PPPOE_PASS}" | base64 | tr -d '\n')"
        printf 'LAN_IFACE=%s\n' "$(printf '%s' "${LAN_IFACE}" | base64 | tr -d '\n')"
        printf 'LAN_IP=%s\n' "$(printf '%s' "${LAN_IP}" | base64 | tr -d '\n')"
        printf 'LAN_PREFIX=%s\n' "$(printf '%s' "${LAN_PREFIX}" | base64 | tr -d '\n')"
        printf 'LAN_DHCP_ENABLE=%s\n' "$(printf '%s' "${LAN_DHCP_ENABLE}" | base64 | tr -d '\n')"
        printf 'LAN_DHCP_START=%s\n' "$(printf '%s' "${LAN_DHCP_START}" | base64 | tr -d '\n')"
        printf 'LAN_DHCP_END=%s\n' "$(printf '%s' "${LAN_DHCP_END}" | base64 | tr -d '\n')"
        printf 'LAN_DHCP_LEASE=%s\n' "$(printf '%s' "${LAN_DHCP_LEASE}" | base64 | tr -d '\n')"
        printf 'FIRST_SETUP_DONE=%s\n' "$(printf '%s' "${FIRST_SETUP_DONE}" | base64 | tr -d '\n')"
    } > "${tmp_file}"
    chmod 600 "${tmp_file}"
    mv -f "${tmp_file}" "${state_file}"
    umask "${old_umask}"
}

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
_list_ifaces() {
    ip -o link show \
        | awk -F': ' '{print $2}' \
        | grep -v '^lo$' \
        | sed 's/@.*//'
}

_iface_state() {
    ip -o link show "${1}" 2>/dev/null \
        | grep -qo '\bUP\b' && echo "UP" || echo "DOWN"
}

_iface_ip4() {
    # Returns CIDR (e.g. 192.168.1.1/24) or empty string
    ip -4 addr show "${1}" 2>/dev/null \
        | awk '/inet / {print $2}' | head -n1
}

_iface_ip6() {
    # Returns global IPv6 CIDRs as a comma-separated list, or empty string.
    ip -6 addr show "${1}" scope global 2>/dev/null \
        | awk '/inet6 / {print $2}' | paste -sd ', ' -
}

# ---------------------------------------------------------------------------
# Core config helpers - read interface role/description from config.json
# ---------------------------------------------------------------------------
_load_core_ifaces() {
    [[ "${_CORE_CONFIG_LOADED}" -eq 1 ]] && return
    _CORE_CONFIG_LOADED=1
    [[ -f "${DAYSHIELD_CORE_CONFIG}" ]] || return
    command -v python3 >/dev/null 2>&1 || return
    local out
    out="$(python3 -c "
import json, sys
try:
    with open('${DAYSHIELD_CORE_CONFIG}') as f:
        data = json.load(f)
    for iface in data.get('interfaces', []):
        name = iface.get('name', '').strip()
        if not name:
            continue
        role = 'WAN' if iface.get('wan_mode') else 'LAN'
        desc = (iface.get('description') or '').strip()
        print(name + chr(9) + role + chr(9) + desc)
except Exception:
    pass
" 2>/dev/null)"
    while IFS=$'\t' read -r name role desc; do
        [[ -n "${name}" ]] || continue
        _CORE_IFACE_ROLE["${name}"]="${role}"
        _CORE_IFACE_DESC["${name}"]="${desc}"
    done <<< "${out}"
}

# Merge core config values into state variables (only fills blanks left by console-state).
_load_core_state() {
    [[ -f "${DAYSHIELD_CORE_CONFIG}" ]] || return
    command -v python3 >/dev/null 2>&1 || return
    local out
    out="$(python3 -c "
import json, sys
try:
    with open('${DAYSHIELD_CORE_CONFIG}') as f:
        data = json.load(f)
    ifaces = data.get('interfaces', [])
    wan = next((i for i in ifaces if i.get('wan_mode')), None)
    lan = next((i for i in ifaces if not i.get('wan_mode') and i.get('enabled', True)), None)
    if wan:
        print('WAN_IFACE=' + wan.get('name', ''))
        mode = wan.get('wan_mode') or ''
        print('WAN_TYPE=' + ('pppoe' if str(mode).lower() in ('pppoe', 'ppp_oe') else 'dhcp'))
    if lan:
        print('LAN_IFACE=' + lan.get('name', ''))
        addrs = lan.get('addresses', [])
        if addrs:
            parts = str(addrs[0]).split('/')
            print('LAN_IP=' + parts[0])
            if len(parts) > 1:
                print('LAN_PREFIX=' + parts[1])
except Exception:
    pass
" 2>/dev/null)"
    while IFS='=' read -r key value; do
        [[ -n "${key}" ]] || continue
        case "${key}" in
            WAN_IFACE)  [[ -z "${WAN_IFACE}" ]]  && WAN_IFACE="${value}" ;;
            WAN_TYPE)   [[ "${WAN_TYPE}" == "dhcp" ]] && WAN_TYPE="${value}" ;;
            LAN_IFACE)  [[ -z "${LAN_IFACE}" ]]  && LAN_IFACE="${value}" ;;
            LAN_IP)     [[ -z "${LAN_IP}" ]]     && LAN_IP="${value}" ;;
            LAN_PREFIX) [[ -z "${LAN_PREFIX}" ]] && LAN_PREFIX="${value}" ;;
        esac
    done <<< "${out}"
}

_iface_role() {
    local iface="$1"
    _load_core_ifaces
    # Core config is authoritative
    if [[ -v _CORE_IFACE_ROLE["${iface}"] ]]; then
        printf '%s' "${_CORE_IFACE_ROLE[${iface}]}"
        return
    fi
    # Fall back to console-state
    if [[ -n "${WAN_IFACE}" && "${iface}" == "${WAN_IFACE}" ]]; then
        printf 'WAN'
    elif [[ "${WAN_TYPE}" == "pppoe" && "${iface}" == "ppp0" ]]; then
        printf 'WAN'
    elif [[ -n "${LAN_IFACE}" && "${iface}" == "${LAN_IFACE}" ]]; then
        printf 'LAN'
    else
        printf '-'
    fi
}

_iface_desc() {
    local iface="$1"
    _load_core_ifaces
    printf '%s' "${_CORE_IFACE_DESC[${iface}]:-}"
}

_live_web_ifaces_with_ip() {
    # Lists iface<TAB>ip for all global IPv4 addresses currently assigned.
    ip -o -4 addr show scope global 2>/dev/null \
        | while read -r _ iface _ cidr _; do
            iface="${iface%%@*}"
            local ip
            ip="${cidr%%/*}"
            [[ -n "${ip}" && "${ip}" != 127.* ]] || continue
            printf '%s\t%s\n' "${iface}" "${ip}"
        done
}

_default_dhcp_pool() {
    local ip="$1"
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
    printf '%s.%s.%s.100 %s.%s.%s.199\n' "${o1}" "${o2}" "${o3}" "${o1}" "${o2}" "${o3}"
}

_is_valid_ipv4() {
    local ip="$1"
    local o1 o2 o3 o4
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
    for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
        [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

_ipv4_to_int() {
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$1"
    printf '%u' "$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))"
}

_apply_lan_dhcp_config() {
    local kea_conf="/etc/dayshield/kea-dhcp4.conf"
    local kea_compat_conf="/etc/kea/kea-dhcp4.conf"

    if [[ "${LAN_DHCP_ENABLE}" == "yes" ]] && [[ -n "${LAN_IFACE}" ]] && [[ -n "${LAN_IP}" ]] && [[ -n "${LAN_DHCP_START}" ]] && [[ -n "${LAN_DHCP_END}" ]]; then
        mkdir -p /etc/dayshield /etc/kea /var/log/kea /var/lib/kea
        chmod 755 /etc/kea

        # Compute network address for Kea subnet (e.g. 192.168.1.0/24)
        local prefix="${LAN_PREFIX:-24}"
        local o1 o2 o3 o4
        IFS='.' read -r o1 o2 o3 o4 <<< "${LAN_IP}"
        # Calculate subnet mask from CIDR prefix (e.g. /24 -> 255.255.255.0 mask bits).
        local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
        local ip_int=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
        local net_int=$(( ip_int & mask ))
        local subnet_addr
        subnet_addr="$(printf '%d.%d.%d.%d' \
            "$(( (net_int >> 24) & 255 ))" \
            "$(( (net_int >> 16) & 255 ))" \
            "$(( (net_int >> 8)  & 255 ))" \
            "$(( net_int & 255 ))")"
        local subnet="${subnet_addr}/${prefix}"

        # Convert lease time (e.g. 12h) to seconds for Kea
        local lease_str="${LAN_DHCP_LEASE:-12h}"
        local lease_val="${lease_str%[smhd]}"
        local lease_unit="${lease_str: -1}"
        local lease_secs
        case "${lease_unit}" in
            h) lease_secs=$(( lease_val * 3600 )) ;;
            m) lease_secs=$(( lease_val * 60 ))   ;;
            d) lease_secs=$(( lease_val * 86400 )) ;;
            s) lease_secs="${lease_val}"           ;;
            *) lease_secs=43200                    ;;
        esac

        cat > "${kea_conf}" <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["${LAN_IFACE}"]
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "${subnet}",
        "pools": [
          { "pool": "${LAN_DHCP_START} - ${LAN_DHCP_END}" }
        ],
        "valid-lifetime": ${lease_secs},
        "option-data": [
          { "name": "routers",             "data": "${LAN_IP}" },
          { "name": "domain-name-servers", "data": "${LAN_IP}" }
        ]
      }
    ],
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
    chmod 644 "${kea_conf}"
    cp "${kea_conf}" "${kea_compat_conf}"
    chmod 644 "${kea_compat_conf}"

    cat > "/etc/dayshield/kea-dhcp6.conf" <<'EOF'
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
    cp "/etc/dayshield/kea-dhcp6.conf" "/etc/kea/kea-dhcp6.conf"
    chmod 644 "/etc/kea/kea-dhcp6.conf"

    systemctl enable kea-dhcp4-server >/dev/null 2>&1 || true
    systemctl restart kea-dhcp4-server >/dev/null 2>&1 || true
    systemctl disable kea-dhcp6-server >/dev/null 2>&1 || true
    systemctl stop kea-dhcp6-server >/dev/null 2>&1 || true
    else
        systemctl stop kea-dhcp4-server >/dev/null 2>&1 || true
        systemctl disable kea-dhcp6-server >/dev/null 2>&1 || true
    fi
}

_apply_nftables_config() {
    local nft_ifaces="/etc/dayshield/config/nft-ifaces.conf"
    mkdir -p /etc/dayshield/config
    # PPPoE traffic exits via ppp0, not the physical WAN interface.
    local effective_wan="${WAN_IFACE:-lo}"
    [[ "${WAN_TYPE}" == "pppoe" ]] && effective_wan="ppp0"
    printf 'define WAN_IF = %s\ndefine LAN_IF = %s\n' \
        "${effective_wan}" "${LAN_IFACE:-lo}" > "${nft_ifaces}"
    if ! nft -f /etc/nftables.conf >/dev/null 2>&1; then
        printf '  [WARN] failed to apply /etc/nftables.conf; verify interface assignments and nftables syntax\n' >&2
    fi
}

_apply_network_config() {
    local net_dir="/etc/systemd/network"
    local old_console_loglevel=""
    mkdir -p "${net_dir}"

    # Remove the generic placeholder written by chroot-setup
    rm -f "${net_dir}/10-dayshield-eth.network"

    # WAN
    if [[ -n "${WAN_IFACE}" ]]; then
        if [[ "${WAN_TYPE}" == "pppoe" ]]; then
            # Physical WAN interface: up with no address, PPPoE runs on top
            cat > "${net_dir}/10-wan.network" <<EOF
[Match]
Name=${WAN_IFACE}

[Network]
DHCP=no
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
            _apply_pppoe_config
        else
            cat > "${net_dir}/10-wan.network" <<EOF
[Match]
Name=${WAN_IFACE}

[Network]
DHCP=ipv4
IPv6AcceptRA=yes
LinkLocalAddressing=ipv6

[DHCPv4]
UseHostname=false
SendHostname=false
EOF
        fi
    fi

    # LAN - static IP (if configured)
    if [[ -n "${LAN_IFACE}" ]]; then
        if [[ -n "${LAN_IP}" && -n "${LAN_PREFIX}" ]]; then
            cat > "${net_dir}/20-lan.network" <<EOF
[Match]
Name=${LAN_IFACE}

[Network]
Address=${LAN_IP}/${LAN_PREFIX}
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
        else
            # LAN assigned but no IP yet - bring it up without an address
            cat > "${net_dir}/20-lan.network" <<EOF
[Match]
Name=${LAN_IFACE}

[Network]
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
        fi
    fi

    # Keep kernel log spam off the interactive wizard console while we reload.
    # Some drivers/services emit printk lines during interface reconfiguration.
    if [[ -r /proc/sys/kernel/printk ]] && [[ -w /proc/sys/kernel/printk ]]; then
        old_console_loglevel="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null || true)"
        printf '1\n' > /proc/sys/kernel/printk 2>/dev/null || true
    fi

    if ! networkctl reload >/dev/null 2>&1; then
        printf '  [WARN] networkctl reload failed; network changes may be incomplete\n' >&2
    fi
    sleep 1

    if [[ -n "${old_console_loglevel}" ]] && [[ -w /proc/sys/kernel/printk ]]; then
        printf '%s\n' "${old_console_loglevel}" > /proc/sys/kernel/printk 2>/dev/null || true
    fi

    _apply_nftables_config
    _apply_lan_dhcp_config
}

# Write /etc/ppp/peers/wan and restart pppd for PPPoE WAN.
_apply_pppoe_config() {
    mkdir -p /etc/ppp
    local ppp_user="${WAN_PPPOE_USER//\\/\\\\}"
    ppp_user="${ppp_user//\"/\\\"}"
    local ppp_pass="${WAN_PPPOE_PASS//\\/\\\\}"
    ppp_pass="${ppp_pass//\"/\\\"}"

    # Write peer config - rp-pppoe plugin runs over the physical WAN interface
    cat > /etc/ppp/peers/wan <<EOF
plugin rp-pppoe.so ${WAN_IFACE}
user "${ppp_user}"
linkname wan
pidfile /run/ppp-wan.pid
noipdefault
noauth
defaultroute
replacedefaultroute
hide-password
persist
maxfail 0
holdoff 5
mtu 1492
mru 1492
noipv6
EOF
    chmod 600 /etc/ppp/peers/wan

    # Write credentials to chap-secrets and pap-secrets
    local secrets_line="\"${ppp_user}\" * \"${ppp_pass}\" *"
    printf '%s\n' "${secrets_line}" > /etc/ppp/chap-secrets
    printf '%s\n' "${secrets_line}" > /etc/ppp/pap-secrets
    chmod 600 /etc/ppp/chap-secrets /etc/ppp/pap-secrets

    # Stop existing PPPoE session for this link name (if any)
    local pidfile old_pid pid_perms
    for pidfile in /run/ppp-wan.pid /var/run/ppp-wan.pid; do
        [[ -f "${pidfile}" ]] || continue
        if [[ "$(stat -c '%u' "${pidfile}" 2>/dev/null || true)" != "0" ]]; then
            continue
        fi
        pid_perms="$(stat -c '%A' "${pidfile}" 2>/dev/null || true)"
        if [[ "${#pid_perms}" -ge 10 ]] && { [[ "${pid_perms:5:1}" == "w" ]] || [[ "${pid_perms:8:1}" == "w" ]]; }; then
            continue
        fi
        old_pid="$(cat "${pidfile}" 2>/dev/null || true)"
        if [[ "${old_pid}" =~ ^[0-9]+$ ]] && kill -0 "${old_pid}" 2>/dev/null; then
            if [[ -r "/proc/${old_pid}/comm" ]] && [[ "$(cat "/proc/${old_pid}/comm" 2>/dev/null || true)" == "pppd" ]]; then
                kill "${old_pid}" 2>/dev/null || true
            fi
        fi
    done
    sleep 1

    # Start pppd in background
    pppd call wan &
    printf '  PPPoE connection started (ppp0 will appear when ISP authenticates)\n'
}

# ---------------------------------------------------------------------------
# SSH fingerprint display
# ---------------------------------------------------------------------------
_ssh_fingerprints() {
    local key_dir="/etc/ssh"
    local printed=0
    for keyfile in \
        "${key_dir}/ssh_host_ecdsa_key.pub" \
        "${key_dir}/ssh_host_ed25519_key.pub" \
        "${key_dir}/ssh_host_rsa_key.pub"
    do
        [[ -f "${keyfile}" ]] || continue
        local info hash type
        info="$(ssh-keygen -lf "${keyfile}" 2>/dev/null)"
        hash="$(echo "${info}" | awk '{print $2}')"
        type="$(echo "${info}" | awk '{print $4}' | tr -d '()')"
        [[ -n "${hash}" ]] || continue
        printf " SSH:   %-7s %s\n" "${type}" "${hash}"
        printed=$(( printed + 1 ))
    done
    [[ ${printed} -eq 0 ]] && printf " SSH:   (no host keys generated yet)\n"
}

# ---------------------------------------------------------------------------
# Color / style constants  (empty when stdout is not a tty)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _CR=$'\e[0m'      # reset
    _CB=$'\e[1m'      # bold
    _CD=$'\e[2m'      # dim
    _CG=$'\e[32m'     # green
    _CRED=$'\e[31m'   # red
    _CY=$'\e[33m'     # yellow
    _CC=$'\e[36m'     # cyan
    _CW=$'\e[97m'     # bright white
else
    _CR='' _CB='' _CD='' _CG='' _CRED='' _CY='' _CC='' _CW=''
fi

# ---------------------------------------------------------------------------
# Header / status display
# ---------------------------------------------------------------------------
_hr() {
    local b; printf -v b '─%.0s' {1..74}; printf "${_CD}  %s${_CR}\n" "${b}"
}

_wide_hr() {
    local b; printf -v b '═%.0s' {1..74}; printf "${_CB}  %s${_CR}\n" "${b}"
}

_kv() {
    printf "  ${_CB}%-20s${_CR} %s\n" "$1" "$2"
}

_print_header() {
    local hostname
    hostname="$(hostname -f 2>/dev/null || hostname)"
    local lan_ip4=""

    local mode_line=""
    $LIVE_MODE && mode_line=" — LIVE INSTALLER"

    # Title bar: "DayShield  vX.Y.Z" left, "Host: <name>" right
    local title_plain="DayShield  v${DAYSHIELD_VERSION}${mode_line}"
    local host_str="Host: ${hostname}"
    local pad=$(( 74 - ${#title_plain} - ${#host_str} ))
    [[ ${pad} -lt 2 ]] && pad=2

    _wide_hr
    printf "  ${_CB}${_CW}DayShield${_CR}  ${_CC}v%s%s${_CR}%*s${_CD}Host:${_CR} ${_CB}%s${_CR}\n" \
        "${DAYSHIELD_VERSION}" "${mode_line}" "${pad}" "" "${hostname}"
    _wide_hr
    echo ""

    # Interfaces table
    printf "  ${_CB}Interfaces${_CR}\n"
    printf "${_CD}  %-12s %-6s %-7s %-18s %-20s${_CR}\n" "Name" "Role" "State" "IPv4" "IPv6"
    _hr

    local printed_iface=0
    while IFS= read -r iface; do
        local ip4 ip6 role state
        ip4="$(_iface_ip4 "${iface}")"
        ip6="$(_iface_ip6 "${iface}")"
        role="$(_iface_role "${iface}")"
        state="$(_iface_state "${iface}")"
        printf "  %-12s " "${iface}"
        case "${role}" in
            WAN) printf "${_CY}%-6s${_CR} " "${role}" ;;
            LAN) printf "${_CC}%-6s${_CR} " "${role}" ;;
            *)   printf "%-6s " "${role}" ;;
        esac
        if [[ "${state}" == "UP" ]]; then
            printf "${_CG}%-7s${_CR}" "${state}"
        else
            printf "${_CRED}%-7s${_CR}" "${state}"
        fi
        printf "%-18s %-20s\n" "${ip4:--}" "${ip6:--}"
        printed_iface=1
    done < <(_list_ifaces)
    if [[ "${WAN_TYPE}" == "pppoe" ]] && ip link show ppp0 >/dev/null 2>&1; then
        local ppp4 ppp6 ppp_state
        ppp4="$(_iface_ip4 ppp0)"
        ppp6="$(_iface_ip6 ppp0)"
        ppp_state="$(_iface_state ppp0)"
        printf "  %-12s ${_CY}%-6s${_CR} " "ppp0" "WAN"
        if [[ "${ppp_state}" == "UP" ]]; then
            printf "${_CG}%-7s${_CR}" "${ppp_state}"
        else
            printf "${_CRED}%-7s${_CR}" "${ppp_state}"
        fi
        printf "%-18s %-20s\n" "${ppp4:--}" "${ppp6:--}"
        printed_iface=1
    fi
    [[ "${printed_iface}" -eq 0 ]] && printf "  ${_CD}No network interfaces detected.${_CR}\n"
    _hr

    # Resolve LAN IP for management URL
    if [[ -n "${LAN_IFACE}" ]]; then
        local lan_cidr
        lan_cidr="$(_iface_ip4 "${LAN_IFACE}")"
        if [[ -z "${lan_cidr}" ]] && [[ -n "${LAN_IP}" ]]; then
            lan_cidr="${LAN_IP}/${LAN_PREFIX}"
        fi
        lan_ip4="${lan_cidr%%/*}"
    fi

    echo ""
    if $LIVE_MODE; then
        local web_rows=()
        while IFS=$'\t' read -r iface ip; do
            web_rows+=("http://${ip}:8443/ (${iface})")
        done < <(_live_web_ifaces_with_ip)

        if [[ ${#web_rows[@]} -gt 0 ]]; then
            printf "  ${_CB}Web Installer${_CR}   ${_CB}${_CC}%s${_CR}\n" "${web_rows[0]}"
            local idx
            for idx in "${!web_rows[@]}"; do
                [[ "${idx}" -eq 0 ]] && continue
                printf "  %-17s${_CB}${_CC}%s${_CR}\n" "" "${web_rows[${idx}]}"
            done
        else
            printf "  ${_CB}Web Installer${_CR}   ${_CD}no IPv4 address detected yet${_CR}\n"
            printf "  ${_CD}Hint: use option 9 to configure LAN for Web Installer${_CR}\n"
        fi
    elif [[ -n "${lan_ip4}" ]] && [[ "${lan_ip4}" != "no address" ]]; then
        printf "  ${_CB}Management${_CR}      ${_CB}${_CC}https://%s:8443/${_CR}\n" "${lan_ip4}"
    fi
    echo ""
    _wide_hr
    echo ""
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------
_assign_interfaces() {
    clear
    echo "DayShield Console - Assign Interfaces"
    echo "--------------------------------------"
    echo "Type 'q' at any prompt to cancel and return to the main menu."
    echo ""

    local ifaces=()
    while IFS= read -r iface; do
        ifaces+=("${iface}")
    done < <(_list_ifaces)

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        echo "No network interfaces detected."
        read -rp "Press Enter to continue …"
        return
    fi

    echo "Detected interfaces:"
    local i=1
    for iface in "${ifaces[@]}"; do
        local ip4
        ip4="$(_iface_ip4 "${iface}")"
        printf "  %d) %-12s [%-4s] %s\n" \
            "${i}" "${iface}" "$(_iface_state "${iface}")" "${ip4}"
        (( i++ )) || true
    done
    echo ""

    local wan_n lan_n
    read -rp "Select WAN interface number (Enter to skip): " wan_n
    if [[ "${wan_n}" == "q" || "${wan_n}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    if [[ "${wan_n}" =~ ^[0-9]+$ ]] && \
       [[ "${wan_n}" -ge 1 ]] && [[ "${wan_n}" -le "${#ifaces[@]}" ]]; then
        WAN_IFACE="${ifaces[$(( wan_n - 1 ))]}"

        # WAN connection type
        echo ""
        echo "WAN connection type:"
        echo "  1) DHCP   - automatic address from ISP"
        echo "  2) PPPoE  - username/password"
        read -rp "Select type [1] (or q to cancel): " wan_type_n
        if [[ "${wan_type_n}" == "q" || "${wan_type_n}" == "Q" ]]; then
            echo ""
            echo "Cancelled. Returning to main menu."
            read -rp "Press Enter to continue ..."
            return
        fi
        case "${wan_type_n}" in
            2)
                WAN_TYPE="pppoe"
                read -rp "PPPoE username (or q to cancel): " WAN_PPPOE_USER
                if [[ "${WAN_PPPOE_USER}" == "q" || "${WAN_PPPOE_USER}" == "Q" ]]; then
                    echo ""
                    echo "Cancelled. Returning to main menu."
                    read -rp "Press Enter to continue ..."
                    return
                fi
                read -rsp "PPPoE password: " WAN_PPPOE_PASS
                echo ""
                ;;
            *)
                WAN_TYPE="dhcp"
                WAN_PPPOE_USER=""
                WAN_PPPOE_PASS=""
                ;;
        esac
    fi

    read -rp "Select LAN interface number (Enter to skip): " lan_n
    if [[ "${lan_n}" == "q" || "${lan_n}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    if [[ "${lan_n}" =~ ^[0-9]+$ ]] && \
       [[ "${lan_n}" -ge 1 ]] && [[ "${lan_n}" -le "${#ifaces[@]}" ]]; then
        LAN_IFACE="${ifaces[$(( lan_n - 1 ))]}"
    fi

    if [[ -n "${WAN_IFACE}" && -n "${LAN_IFACE}" && "${WAN_IFACE}" == "${LAN_IFACE}" ]]; then
        echo ""
        echo "Invalid selection: WAN and LAN interfaces must be different."
        read -rp "Press Enter to continue ..."
        return
    fi

    _apply_network_config
    _save_state

    echo ""
    echo "Updated assignments:"
    echo "  WAN: ${WAN_IFACE:-not assigned}"
    echo "  LAN: ${LAN_IFACE:-not assigned}"
    echo ""
    read -rp "Press Enter to continue …"
}

_set_lan_ip() {
    clear
    echo "DayShield Console - Set LAN IP Address"
    echo "---------------------------------------"
    echo "Type 'q' at any prompt to cancel and return to the main menu."
    echo ""

    if [[ -z "${LAN_IFACE}" ]]; then
        echo "No LAN interface assigned.  Use option 1 first."
        read -rp "Press Enter to continue …"
        return
    fi

    local default_ip="${LAN_IP:-192.168.1.1}"
    local default_prefix="${LAN_PREFIX:-24}"

    read -rp "LAN IP address [${default_ip}]: " new_ip
    if [[ "${new_ip}" == "q" || "${new_ip}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    new_ip="${new_ip:-${default_ip}}"

    read -rp "Subnet prefix length [${default_prefix}]: " new_prefix
    if [[ "${new_prefix}" == "q" || "${new_prefix}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    new_prefix="${new_prefix:-${default_prefix}}"

    # Basic validation
    if ! _is_valid_ipv4 "${new_ip}"; then
        echo "Invalid IP address: ${new_ip}"
        read -rp "Press Enter to continue …"
        return
    fi
    if ! [[ "${new_prefix}" =~ ^[0-9]+$ ]] || \
       [[ "${new_prefix}" -lt 1 ]] || [[ "${new_prefix}" -gt 32 ]]; then
        echo "Invalid prefix length (must be 1–32): ${new_prefix}"
        read -rp "Press Enter to continue …"
        return
    fi

    LAN_IP="${new_ip}"
    LAN_PREFIX="${new_prefix}"

    _apply_network_config
    _save_state

    echo ""
    echo "  LAN IP set to ${LAN_IP}/${LAN_PREFIX} on ${LAN_IFACE}"
    echo ""
    read -rp "Press Enter to continue …"
}

_set_lan_dhcp() {
    clear
    echo "DayShield Console - Configure LAN DHCP"
    echo "---------------------------------------"
    echo "Type 'q' at any prompt to cancel and return to the main menu."
    echo ""

    if [[ -z "${LAN_IFACE}" || -z "${LAN_IP}" ]]; then
        echo "LAN interface/IP not configured. Use options 1 and 2 first."
        read -rp "Press Enter to continue …"
        return
    fi

    local pool_defaults start_default end_default
    pool_defaults="$(_default_dhcp_pool "${LAN_IP}")"
    start_default="${LAN_DHCP_START:-${pool_defaults%% *}}"
    end_default="${LAN_DHCP_END:-${pool_defaults##* }}"
    local lease_default="${LAN_DHCP_LEASE:-12h}"

    read -rp "Enable LAN DHCP server? [Y/n]: " enable_dhcp
    if [[ "${enable_dhcp}" == "q" || "${enable_dhcp}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    if [[ -n "${enable_dhcp}" && "${enable_dhcp,,}" != "y" ]]; then
        LAN_DHCP_ENABLE="no"
        LAN_DHCP_START=""
        LAN_DHCP_END=""
        _apply_lan_dhcp_config
        _save_state
        echo ""
        echo "LAN DHCP server disabled."
        echo ""
        read -rp "Press Enter to continue …"
        return
    fi

    read -rp "DHCP range start [${start_default}]: " new_start
    if [[ "${new_start}" == "q" || "${new_start}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    new_start="${new_start:-${start_default}}"
    read -rp "DHCP range end   [${end_default}]: " new_end
    if [[ "${new_end}" == "q" || "${new_end}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    new_end="${new_end:-${end_default}}"
    read -rp "Lease time [${lease_default}] (e.g. 12h): " new_lease
    if [[ "${new_lease}" == "q" || "${new_lease}" == "Q" ]]; then
        echo ""
        echo "Cancelled. Returning to main menu."
        read -rp "Press Enter to continue ..."
        return
    fi
    new_lease="${new_lease:-${lease_default}}"

    if ! _is_valid_ipv4 "${new_start}" || ! _is_valid_ipv4 "${new_end}" || ! _is_valid_ipv4 "${LAN_IP}"; then
        echo "Invalid DHCP range."
        read -rp "Press Enter to continue …"
        return
    fi
    if ! [[ "${new_lease}" =~ ^[0-9]+[smhd]$ ]]; then
        echo "Invalid lease time format (expected number + one of s/m/h/d)."
        read -rp "Press Enter to continue …"
        return
    fi
    local prefix="${LAN_PREFIX:-24}"
    local mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    local lan_int start_int end_int
    lan_int="$(_ipv4_to_int "${LAN_IP}")"
    start_int="$(_ipv4_to_int "${new_start}")"
    end_int="$(_ipv4_to_int "${new_end}")"
    if (( start_int > end_int )); then
        echo "Invalid DHCP range: start must be <= end."
        read -rp "Press Enter to continue …"
        return
    fi
    if (( (lan_int & mask) != (start_int & mask) || (lan_int & mask) != (end_int & mask) )); then
        echo "Invalid DHCP range: values must be in the LAN subnet."
        read -rp "Press Enter to continue …"
        return
    fi
    if (( lan_int >= start_int && lan_int <= end_int )); then
        echo "Invalid DHCP range: it must not include the LAN gateway IP (${LAN_IP})."
        read -rp "Press Enter to continue …"
        return
    fi

    LAN_DHCP_ENABLE="yes"
    LAN_DHCP_START="${new_start}"
    LAN_DHCP_END="${new_end}"
    LAN_DHCP_LEASE="${new_lease}"

    _apply_lan_dhcp_config
    _save_state

    echo ""
    echo "LAN DHCP enabled on ${LAN_IFACE}: ${LAN_DHCP_START} - ${LAN_DHCP_END} (${LAN_DHCP_LEASE})"
    echo ""
    read -rp "Press Enter to continue …"
}

_change_password() {
    clear
    echo "DayShield Console - Change Root Password"
    echo "-----------------------------------------"
    echo ""
    passwd root
    echo ""
    read -rp "Press Enter to continue …"
}

_reboot() {
    echo ""
    read -rp "Reboot now? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --no-block reboot >/dev/null 2>&1 || true
        fi
        if command -v reboot >/dev/null 2>&1; then
            reboot >/dev/null 2>&1 || true
        fi
        if command -v shutdown >/dev/null 2>&1; then
            shutdown -r now >/dev/null 2>&1 || true
        fi
        echo "Reboot command attempted. If the system did not reboot, check that systemd or reboot utilities are available."
        read -rp "Press Enter to continue ... " || true
    fi
}

_shutdown() {
    echo ""
    read -rp "Shut down now? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --no-block poweroff >/dev/null 2>&1 || true
        fi
        if command -v poweroff >/dev/null 2>&1; then
            poweroff >/dev/null 2>&1 || true
        fi
        if command -v shutdown >/dev/null 2>&1; then
            shutdown -h now >/dev/null 2>&1 || true
        fi
        echo "Poweroff command attempted. If the system did not power off, check system utilities and permissions."
        read -rp "Press Enter to continue ... " || true
    fi
}

_update_system() {
    clear
    echo "DayShield Console - System Update"
    echo "----------------------------------"
    echo ""

    if ! command -v dayshield-core >/dev/null 2>&1; then
        echo "dayshield-core is not installed or is not in PATH."
        echo ""
        read -rp "Press Enter to continue ..."
        return
    fi

    if ! dayshield-core update-status; then
        echo ""
        echo "Unable to read update status."
        read -rp "Press Enter to continue ..."
        return
    fi

    echo ""
    read -rp "Run update check now? [Y/n]: " do_check
    if [[ -z "${do_check}" || "${do_check,,}" == "y" ]]; then
        echo ""
        echo "Checking update registry ..."
        echo ""
        if ! dayshield-core update-check; then
            echo ""
            echo "Update check failed. Verify DNS, WAN connectivity, and update settings."
            read -rp "Press Enter to continue ..."
            return
        fi
    fi

    echo ""
    echo "Apply component:"
    echo "  1) Core + UI runtime updates"
    echo "  2) Core only"
    echo "  3) UI only"
    echo "  4) Root filesystem update"
    echo "  0) Cancel"
    echo ""
    read -rp "Select update target [0]: " target

    local component=""
    case "${target}" in
        1) component="both" ;;
        2) component="core" ;;
        3) component="ui" ;;
        4) component="rootfs" ;;
        *) return ;;
    esac

    echo ""
    if [[ "${component}" == "rootfs" ]]; then
        echo "Root filesystem updates stage a new OSTree deployment and require a reboot."
    else
        echo "Runtime updates may restart DayShield services while they are applied."
    fi
    read -rp "Apply ${component} update now? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || return

    echo ""
    echo "Applying update ..."
    echo ""
    if [[ "${component}" == "rootfs" ]]; then
        if /usr/local/lib/dayshield/ostree-update.sh apply; then
            echo ""
            echo "Update command completed."
        else
            echo ""
            echo "Update command failed. Review the output above and system logs."
        fi
    elif dayshield-core update-apply "${component}"; then
        echo ""
        echo "Update command completed."
    else
        echo ""
        echo "Update command failed. Review the output above and system logs."
    fi
    echo ""
    read -rp "Press Enter to continue ..."
}

_run_guided_setup() {
    clear
    echo "DayShield Initial Setup Wizard"
    echo "------------------------------"
    echo ""
    echo "This guided setup will walk through:"
    echo "  1) Interface assignment (WAN/LAN)"
    echo "  2) LAN IPv4 address"
    echo "  3) LAN DHCP server"
    echo "  4) Root password"
    echo ""
    read -rp "Start guided setup now? [Y/n]: " start_wiz
    if [[ -n "${start_wiz}" && "${start_wiz,,}" != "y" ]]; then
        return
    fi

    # Step 1: Interfaces
    while [[ -z "${LAN_IFACE}" ]]; do
        _assign_interfaces
        if [[ -z "${LAN_IFACE}" ]]; then
            echo ""
            echo "A LAN interface is required for installer access."
            read -rp "Assign interfaces again? [Y/n]: " retry_if
            if [[ -n "${retry_if}" && "${retry_if,,}" != "y" ]]; then
                break
            fi
        fi
    done

    # Step 2: LAN IP
    if [[ -n "${LAN_IFACE}" ]]; then
        while [[ -z "${LAN_IP}" || -z "${LAN_PREFIX}" ]]; do
            _set_lan_ip
            if [[ -z "${LAN_IP}" || -z "${LAN_PREFIX}" ]]; then
                echo ""
                read -rp "Set LAN IP now? [Y/n]: " retry_ip
                if [[ -n "${retry_ip}" && "${retry_ip,,}" != "y" ]]; then
                    break
                fi
            fi
        done
    fi

    # Step 3: LAN DHCP server
    if [[ -n "${LAN_IFACE}" && -n "${LAN_IP}" ]]; then
        _set_lan_dhcp
    fi

    # Step 4: Root password
    clear
    echo "Step 4 - Change Root Password"
    echo "-----------------------------"
    echo ""
    echo "Default password is 'dayshield'."
    read -rp "Change root password now? [Y/n]: " do_pw
    if [[ -z "${do_pw}" || "${do_pw,,}" == "y" ]]; then
        _change_password
    fi

    FIRST_SETUP_DONE="yes"
    _save_state

    clear
    # _print_header  # Banner disabled
    echo "Initial setup wizard completed."
    echo ""
    read -rp "Press Enter to continue to the main menu ..."
}

# ---------------------------------------------------------------------------
# Installation pipeline (live-installer mode only)
# ---------------------------------------------------------------------------

_inst_hr()   { printf '  ============================================================\n'; }
_inst_step() { printf '\n  [%d/%d] %s\n  ------------------------------------------------------------\n' "$1" "$2" "$3"; }
_inst_ok()   { printf '  [OK]  %s\n' "$*"; }
_inst_err()  { printf '  [ERR] %s\n' "$*"; }
_inst_info() { printf '  ...   %s\n' "$*"; }

_inst_list_disks() {
    while IFS= read -r dev; do
        [ -b "/dev/${dev}" ] || continue
        local size type
        size=$(lsblk -dno SIZE "/dev/${dev}" 2>/dev/null || printf '?')
        type=$(lsblk -dno TYPE "/dev/${dev}" 2>/dev/null || printf 'disk')
        printf '%s\t%s\t%s\n' "${dev}" "${size}" "${type}"
    done < <(lsblk -dno NAME 2>/dev/null | grep -v '^loop' | grep -v '^sr')
}

_inst_partition() {
    local dev="$1"
    _inst_info "Wiping existing signatures on /dev/${dev} ..."
    wipefs -a "/dev/${dev}" >/dev/null 2>&1 || true

    _inst_info "Creating GPT layout (BIOS + EFI + shared boot + OSTree sysroot + persistent state) ..."
    if command -v parted >/dev/null 2>&1; then
        parted -s "/dev/${dev}" \
            mklabel gpt \
            mkpart primary 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart primary fat32 2MiB 514MiB \
            set 2 esp on \
            mkpart primary ext4 514MiB 1538MiB \
            mkpart primary ext4 1538MiB 50% \
            mkpart primary ext4 50% 100% >/dev/null 2>&1 || { _inst_err "parted failed."; return 1; }
    else
        _inst_err "parted was not found."
        return 1
    fi

    _inst_info "Waiting for partition nodes ..."
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
    local pfx
    case "$dev" in nvme*|mmcblk*) pfx="${dev}p" ;; *) pfx="${dev}" ;; esac
    local waited=0
    while ! [[ -b "/dev/${pfx}2" ]] || ! [[ -b "/dev/${pfx}3" ]] || ! [[ -b "/dev/${pfx}4" ]] || ! [[ -b "/dev/${pfx}5" ]]; do
        sleep 1; waited=$(( waited + 1 ))
        [[ ${waited} -ge 10 ]] && { _inst_err "Partition nodes did not appear."; return 1; }
    done
    return 0
}

_inst_format() {
    local dev="$1" pfx
    case "$dev" in nvme*|mmcblk*) pfx="${dev}p" ;; *) pfx="${dev}" ;; esac
    local efi="/dev/${pfx}2" boot="/dev/${pfx}3" sysroot="/dev/${pfx}4" state="/dev/${pfx}5"

    _inst_info "Formatting ${efi} as FAT32 (EFI) ..."
    mkfs.fat -F32 -n "DS_EFI" "${efi}" >/dev/null 2>&1 || { _inst_err "mkfs.fat failed."; return 1; }

    _inst_info "Formatting ${boot} as ext4 (shared boot) ..."
    mkfs.ext4 -F -L "DAYSHIELD_BOOT" -O "^64bit,metadata_csum" -m 1 \
        "${boot}" >/dev/null 2>&1 || { _inst_err "mkfs.ext4 boot failed."; return 1; }

    _inst_info "Formatting ${sysroot} as ext4 (OSTree sysroot) ..."
    mkfs.ext4 -F -L "DAYSHIELD_ROOT" -O "^64bit,metadata_csum" -m 1 \
        "${sysroot}" >/dev/null 2>&1 || { _inst_err "mkfs.ext4 sysroot failed."; return 1; }

    _inst_info "Formatting ${state} as ext4 (persistent state /var) ..."
    mkfs.ext4 -F -L "DAYSHIELD_STATE" -O "^64bit,metadata_csum" -m 1 \
        "${state}" >/dev/null 2>&1 || { _inst_err "mkfs.ext4 state failed."; return 1; }
    return 0
}

# Global output variables for _inst_find_rootfs (avoids subshell mount leak).
_INST_ROOTFS_PATH=""
_INST_MEDIA_MOUNT_TMP=""

_inst_find_rootfs() {
    _INST_ROOTFS_PATH=""
    _INST_MEDIA_MOUNT_TMP=""

    local candidate
    for candidate in \
        "/run/installer/rootfs.tar.zst" \
        "/lib/live/mount/medium/installer/rootfs.tar.zst" \
        "/run/live/medium/installer/rootfs.tar.zst" \
        "/media/cdrom/installer/rootfs.tar.zst" \
        "/media/live/installer/rootfs.tar.zst"
    do
        if [[ -f "${candidate}" ]]; then
            _INST_ROOTFS_PATH="${candidate}"
            return 0
        fi
    done

    # Last resort: scan for DAYSHIELD-labelled block device
    local bdev mp
    bdev=$(blkid -t LABEL=DAYSHIELD -o device 2>/dev/null | head -n1)
    if [[ -n "${bdev}" ]]; then
        mp=$(mktemp -d)
        if mount -o ro "${bdev}" "${mp}" 2>/dev/null; then
            if [[ -f "${mp}/installer/rootfs.tar.zst" ]]; then
                _INST_ROOTFS_PATH="${mp}/installer/rootfs.tar.zst"
                _INST_MEDIA_MOUNT_TMP="${mp}"
                return 0
            fi
            umount "${mp}" 2>/dev/null || true
        fi
        rmdir "${mp}" 2>/dev/null || true
    fi
    return 1
}

_inst_require_ostree_tooling() {
    local target="$1" missing=0

    if [[ ! -x "${target}/usr/bin/ostree" ]]; then
        _inst_err "Installed target is missing /usr/bin/ostree."
        missing=1
    fi
    if [[ ! -x "${target}/usr/local/lib/dayshield/ostree-update.sh" ]]; then
        _inst_err "Installed target is missing /usr/local/lib/dayshield/ostree-update.sh."
        missing=1
    fi

    if (( missing )); then
        _inst_err "Input rootfs is missing required DayShield OSTree update tooling; rebuild dayshield-rootfs and recreate the ISO."
        return 1
    fi
}

_inst_install_rootfs() {
    local dev="$1" rootfs="$2" pfx target="/mnt/target"
    case "$dev" in nvme*|mmcblk*) pfx="${dev}p" ;; *) pfx="${dev}" ;; esac
    local efi="/dev/${pfx}2" boot="/dev/${pfx}3" root="/dev/${pfx}4" state="/dev/${pfx}5"

    _inst_info "Mounting OSTree sysroot partition ..."
    mkdir -p "${target}"
    mount "${root}" "${target}" || { _inst_err "Failed to mount ${root}."; return 1; }

    _inst_info "Mounting shared boot partition ..."
    mkdir -p "${target}/boot"
    mount "${boot}" "${target}/boot" || {
        umount "${target}" 2>/dev/null || true
        _inst_err "Failed to mount boot partition."; return 1
    }

    _inst_info "Mounting EFI partition ..."
    mkdir -p "${target}/boot/efi"
    mount "${efi}" "${target}/boot/efi" || {
        umount "${target}/boot" 2>/dev/null || true
        umount "${target}" 2>/dev/null || true
        _inst_err "Failed to mount EFI partition."; return 1
    }

    _inst_info "Mounting persistent state partition at /var ..."
    mkdir -p "${target}/var"
    mount "${state}" "${target}/var" || {
        umount "${target}/boot/efi" 2>/dev/null || true
        umount "${target}/boot" 2>/dev/null || true
        umount "${target}" 2>/dev/null || true
        _inst_err "Failed to mount state partition."; return 1
    }

    _inst_info "Extracting rootfs (this may take several minutes) ..."
    if command -v zstd >/dev/null 2>&1; then
        zstd -d --stdout "${rootfs}" | tar -xp -C "${target}" || {
            umount "${target}/var" 2>/dev/null || true
            umount "${target}/boot/efi" 2>/dev/null || true
            umount "${target}/boot" 2>/dev/null || true
            umount "${target}" 2>/dev/null || true
            _inst_err "Extraction failed."; return 1
        }
    elif tar --version 2>&1 | grep -q "GNU tar"; then
        tar -xp --zstd -f "${rootfs}" -C "${target}" || {
            umount "${target}/var" 2>/dev/null || true
            umount "${target}/boot/efi" 2>/dev/null || true
            umount "${target}/boot" 2>/dev/null || true
            umount "${target}" 2>/dev/null || true
            _inst_err "Extraction failed (GNU tar)."; return 1
        }
    else
        _inst_err "Neither zstd nor GNU tar available."; return 1
    fi
    _inst_require_ostree_tooling "${target}" || return 1
    local root_uuid boot_uuid efi_uuid state_uuid
    root_uuid="$(blkid -s UUID -o value "${root}")"
    boot_uuid="$(blkid -s UUID -o value "${boot}")"
    efi_uuid="$(blkid -s UUID -o value "${efi}")"
    state_uuid="$(blkid -s UUID -o value "${state}")"
    cat > "${target}/etc/fstab" <<EOF
# /etc/fstab - generated by DayShield installer
UUID=${root_uuid}  /          ext4  defaults,noatime  0  1
UUID=${state_uuid} /var       ext4  defaults,noatime  0  2
UUID=${boot_uuid}  /boot      ext4  defaults,noatime  0  2
UUID=${efi_uuid}   /boot/efi  vfat  umask=0077        0  2
tmpfs              /tmp       tmpfs defaults           0  0
EOF
    return 0
}

_inst_install_bootloader() {
    local dev="$1" target="/mnt/target"

    _inst_info "Binding pseudo-filesystems ..."
    for fs in proc sys dev dev/pts; do
        mkdir -p "${target}/${fs}"
        mount --bind "/${fs}" "${target}/${fs}" >/dev/null 2>&1 || true
    done

    # Ensure kernel and initramfs exist
    _inst_info "Checking for kernel and initramfs ..."
    if [[ ! -f "${target}/boot/vmlinuz" ]] && ! ls "${target}"/boot/vmlinuz-* >/dev/null 2>&1; then
        _inst_info "  Kernel/initramfs not found - generating ..."
        if chroot "${target}" update-initramfs -c -k all >/dev/null 2>&1; then
            _inst_info "  Initramfs generated successfully"
        else
            _inst_err "Initramfs generation may have failed"
        fi
    fi

    _inst_info "Installing GRUB BIOS (i386-pc) ..."
    if [[ -d "${target}/usr/lib/grub/i386-pc" ]] || [[ -d "/usr/lib/grub/i386-pc" ]]; then
        grub-install --target=i386-pc \
            --boot-directory="${target}/boot" \
            --recheck "/dev/${dev}" >/dev/null 2>&1 || \
            _inst_err "BIOS grub-install warning (may be non-fatal)"
    fi

    _inst_info "Installing GRUB UEFI (x86_64-efi) ..."
    if [[ -d "${target}/usr/lib/grub/x86_64-efi" ]] || [[ -d "/usr/lib/grub/x86_64-efi" ]]; then
        grub-install --target=x86_64-efi \
            --efi-directory="${target}/boot/efi" \
            --boot-directory="${target}/boot" \
            --removable --recheck >/dev/null 2>&1 || \
            _inst_err "UEFI grub-install warning (may be non-fatal)"
    fi

    _inst_info "Using standard GRUB boot entry generation for OSTree deployments ..."
    if [[ -f "${target}/etc/default/grub" ]]; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "${target}/etc/default/grub" 2>/dev/null || true
        grep -q '^GRUB_DEFAULT=' "${target}/etc/default/grub" || printf 'GRUB_DEFAULT=saved\n' >> "${target}/etc/default/grub"
        grep -q '^GRUB_SAVEDEFAULT=' "${target}/etc/default/grub" || printf 'GRUB_SAVEDEFAULT=false\n' >> "${target}/etc/default/grub"
    else
        printf 'GRUB_DEFAULT=saved\nGRUB_SAVEDEFAULT=false\nGRUB_TIMEOUT=5\n' > "${target}/etc/default/grub"
    fi

    _inst_info "Generating GRUB config ..."
    chroot "${target}" grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || \
        _inst_err "grub-mkconfig warning"

    for fs in dev/pts dev sys proc; do
        umount "${target}/${fs}" 2>/dev/null || true
    done
    return 0
}

_inst_write_config() {
    local target="/mnt/target"
    local hostname="$1" password="$2"
    local wan_iface="$3" wan_type="$4" wan_pppoe_user="$5" wan_pppoe_pass="$6"
    local lan_iface="$7" lan_ip="$8" lan_prefix="$9"
    local dhcp_start="${10}" dhcp_end="${11}"
    local finalize_script="/usr/local/lib/dayshield/installer-finalize.sh"
    if [[ ! -x "${finalize_script}" ]]; then
        _inst_err "Missing shared finalization script: ${finalize_script}"
        return 1
    fi
    "${finalize_script}" \
        "${target}" \
        "${hostname}" "${password}" \
        "${wan_iface}" "${wan_type}" "${wan_pppoe_user}" "${wan_pppoe_pass}" \
        "${lan_iface}" "${lan_ip}" "${lan_prefix}" \
        "${dhcp_start}" "${dhcp_end}"
}

_inst_finalize() {
    local target="/mnt/target"
    _inst_info "Syncing writes ..."
    sync
    for fs in dev/pts dev sys proc; do
        umount "${target}/${fs}" 2>/dev/null || true
    done
    _inst_info "Unmounting persistent state partition ..."
    umount "${target}/var" 2>/dev/null || _inst_err "State umount warning"
    _inst_info "Unmounting EFI partition ..."
    umount "${target}/boot/efi" 2>/dev/null || _inst_err "EFI umount warning"
    _inst_info "Unmounting boot partition ..."
    umount "${target}/boot" 2>/dev/null || _inst_err "Boot umount warning"
    _inst_info "Unmounting root partition ..."
    umount "${target}" 2>/dev/null || _inst_err "Root umount warning"
    sync
}

_run_install_wizard() {
    local disk="" rootfs="" hostname="dayshield" password="" password2=""
    local wan_iface="" wan_type="dhcp" wan_pppoe_user="" wan_pppoe_pass=""
    local lan_iface="" lan_ip="192.168.1.1" lan_prefix="24"
    local dhcp_start="" dhcp_end=""
    local confirm="" final_confirm="" do_reboot=""
    local total_steps=7

    clear
    _inst_hr
    printf '  DayShield Installer - Console Setup\n'
    _inst_hr
    printf '\n  This wizard will install DayShield to a local disk.\n'
    printf '  All data on the selected disk will be erased.\n\n'
    if ! read -rp "  Continue? [y/N]: " confirm; then
        printf '\n  Input is not available on this console right now.\n'
        printf '  Returning to main menu.\n'
        return
    fi
    [[ "${confirm,,}" == "y" ]] || return

    # ── Step 1: Disk selection ─────────────────────────────────────
    clear; _inst_step 1 "${total_steps}" "Select Installation Disk"; printf '\n'
    local disk_names=() disk_sizes=() disk_types=()
    while IFS=$'\t' read -r dname dsize dtype; do
        disk_names+=("${dname}"); disk_sizes+=("${dsize}"); disk_types+=("${dtype}")
    done < <(_inst_list_disks)

    if [[ ${#disk_names[@]} -eq 0 ]]; then
        printf '  No disks found.\n'; read -rp "  Press Enter ..."; return
    fi
    local i=1
    for idx in "${!disk_names[@]}"; do
        printf '  %d) /dev/%-14s  %s  (%s)\n' \
            "${i}" "${disk_names[${idx}]}" "${disk_sizes[${idx}]}" "${disk_types[${idx}]}"
        (( i++ )) || true
    done
    printf '\n'
    local disk_n
    read -rp "  Select disk [1]: " disk_n; disk_n="${disk_n:-1}"
    if ! [[ "${disk_n}" =~ ^[0-9]+$ ]] || \
       [[ "${disk_n}" -lt 1 ]] || [[ "${disk_n}" -gt "${#disk_names[@]}" ]]; then
        printf '  Invalid selection.\n'; read -rp "  Press Enter ..."; return
    fi
    disk="${disk_names[$(( disk_n - 1 ))]}"
    printf '\n  WARNING: /dev/%s will be completely erased.\n' "${disk}"
    if ! read -rp "  Type YES to confirm: " final_confirm; then
        printf '\n  Input is not available on this console right now.\n'
        printf '  Returning to main menu.\n'
        return
    fi
    [[ "${final_confirm}" == "YES" ]] || { printf '  Cancelled.\n'; sleep 1; return; }

    # ── Step 2: System configuration ──────────────────────────────
    clear; _inst_step 2 "${total_steps}" "System Configuration"; printf '\n'
    read -rp "  Hostname [dayshield]: " hostname; hostname="${hostname:-dayshield}"
    while true; do
        read -rsp "  Root password (min 8 chars): " password; echo
        if [[ ${#password} -lt 8 ]]; then printf '  Password must be at least 8 characters.\n'; continue; fi
        read -rsp "  Confirm password: " password2; echo
        [[ "${password}" == "${password2}" ]] && break
        printf '  Passwords do not match.\n'
    done

    # ── Step 3: Interface assignment ──────────────────────────────
    clear; _inst_step 3 "${total_steps}" "Network Interfaces"; printf '\n'
    local ifaces=()
    while IFS= read -r iface; do ifaces+=("${iface}"); done < <(_list_ifaces)
    if [[ ${#ifaces[@]} -eq 0 ]]; then
        printf '  No interfaces found. Cannot continue.\n'; read -rp "  Press Enter ..."; return
    fi
    local j=1
    for iface in "${ifaces[@]}"; do
        printf '  %d) %-14s [%s]  %s\n' \
            "${j}" "${iface}" "$(_iface_state "${iface}")" "$(_iface_ip4 "${iface}")"
        (( j++ )) || true
    done
    printf '\n'
    local wan_n lan_n
    read -rp "  Select WAN interface number (Enter to skip): " wan_n
    if [[ "${wan_n}" =~ ^[0-9]+$ ]] && \
       [[ "${wan_n}" -ge 1 ]] && [[ "${wan_n}" -le "${#ifaces[@]}" ]]; then
        wan_iface="${ifaces[$(( wan_n - 1 ))]}"
        printf '\n  WAN connection type:\n    1) DHCP\n    2) PPPoE\n'
        read -rp "  Select [1]: " wan_type_n
        case "${wan_type_n}" in
            2) wan_type="pppoe"
               read -rp "  PPPoE username: " wan_pppoe_user
               read -rsp "  PPPoE password: " wan_pppoe_pass; echo ;;
            *) wan_type="dhcp" ;;
        esac
    fi
    read -rp "  Select LAN interface number: " lan_n
    if [[ "${lan_n}" =~ ^[0-9]+$ ]] && \
       [[ "${lan_n}" -ge 1 ]] && [[ "${lan_n}" -le "${#ifaces[@]}" ]]; then
        lan_iface="${ifaces[$(( lan_n - 1 ))]}"
    fi
    if [[ -n "${wan_iface}" && -n "${lan_iface}" && "${wan_iface}" == "${lan_iface}" ]]; then
        printf '\n  WAN and LAN interfaces must be different.\n'
        read -rp "  Press Enter ..."
        return
    fi
    if [[ -z "${lan_iface}" ]]; then
        printf '\n  LAN interface is required.\n'; read -rp "  Press Enter ..."; return
    fi

    # ── Step 4: LAN addressing ─────────────────────────────────────
    clear; _inst_step 4 "${total_steps}" "LAN Address and DHCP"; printf '\n'
    read -rp "  LAN IP address [192.168.1.1]: " lan_ip;     lan_ip="${lan_ip:-192.168.1.1}"
    read -rp "  Subnet prefix  [24]: "          lan_prefix; lan_prefix="${lan_prefix:-24}"
    local octet="${lan_ip%.*}"
    dhcp_start="${octet}.100"; dhcp_end="${octet}.199"
    local ds_in de_in
    read -rp "  DHCP pool start [${dhcp_start}]: " ds_in; dhcp_start="${ds_in:-${dhcp_start}}"
    read -rp "  DHCP pool end   [${dhcp_end}]: "   de_in; dhcp_end="${de_in:-${dhcp_end}}"

    if ! _is_valid_ipv4 "${lan_ip}"; then
        printf '\n  Invalid LAN IP address: %s\n' "${lan_ip}"
        read -rp "  Press Enter ..."
        return
    fi
    if ! [[ "${lan_prefix}" =~ ^[0-9]+$ ]] || [[ "${lan_prefix}" -lt 1 ]] || [[ "${lan_prefix}" -gt 32 ]]; then
        printf '\n  Invalid subnet prefix (must be 1-32): %s\n' "${lan_prefix}"
        read -rp "  Press Enter ..."
        return
    fi
    if ! _is_valid_ipv4 "${dhcp_start}" || ! _is_valid_ipv4 "${dhcp_end}"; then
        printf '\n  Invalid DHCP pool: %s - %s\n' "${dhcp_start}" "${dhcp_end}"
        read -rp "  Press Enter ..."
        return
    fi
    local lan_int start_int end_int mask
    mask=$(( (0xFFFFFFFF << (32 - lan_prefix)) & 0xFFFFFFFF ))
    lan_int="$(_ipv4_to_int "${lan_ip}")"
    start_int="$(_ipv4_to_int "${dhcp_start}")"
    end_int="$(_ipv4_to_int "${dhcp_end}")"
    if (( start_int > end_int )); then
        printf '\n  Invalid DHCP pool: start must be less than or equal to end.\n'
        read -rp "  Press Enter ..."
        return
    fi
    if (( (lan_int & mask) != (start_int & mask) || (lan_int & mask) != (end_int & mask) )); then
        printf '\n  Invalid DHCP pool: addresses must be inside the LAN subnet.\n'
        read -rp "  Press Enter ..."
        return
    fi
    if (( lan_int >= start_int && lan_int <= end_int )); then
        printf '\n  Invalid DHCP pool: it must not include the LAN gateway IP (%s).\n' "${lan_ip}"
        read -rp "  Press Enter ..."
        return
    fi

    # ── Step 5: Partition and format ───────────────────────────────
    clear; _inst_step 5 "${total_steps}" "Partitioning and Formatting"; printf '\n'
    _inst_partition "${disk}" || { read -rp "  Partitioning failed. Press Enter ..."; return; }
    _inst_ok "Partitions created."
    _inst_format "${disk}"    || { read -rp "  Formatting failed. Press Enter ...";   return; }
    _inst_ok "Partitions formatted."

    # ── Step 6: Install rootfs ─────────────────────────────────────
    clear; _inst_step 6 "${total_steps}" "Installing Root Filesystem"; printf '\n'
    _inst_info "Locating rootfs archive ..."
    if ! _inst_find_rootfs; then
        _inst_err "rootfs archive not found. Ensure ISO contains /installer/rootfs.tar.zst"
        read -rp "  Press Enter ..."; return
    fi
    rootfs="${_INST_ROOTFS_PATH}"
    _inst_ok "Found: ${rootfs}"
    _inst_install_rootfs "${disk}" "${rootfs}" || {
        # Clean up any temporarily mounted installation media before returning.
        if [[ -n "${_INST_MEDIA_MOUNT_TMP}" ]]; then
            umount "${_INST_MEDIA_MOUNT_TMP}" 2>/dev/null || true
            rmdir "${_INST_MEDIA_MOUNT_TMP}" 2>/dev/null || true
            _INST_MEDIA_MOUNT_TMP=""
        fi
        read -rp "  rootfs install failed. Press Enter ..."
        return
    }
    _inst_ok "Root filesystem extracted."
    _inst_info "Writing system configuration ..."
    _inst_write_config \
        "${hostname}" "${password}" \
        "${wan_iface}" "${wan_type}" "${wan_pppoe_user}" "${wan_pppoe_pass}" \
        "${lan_iface}" "${lan_ip}" "${lan_prefix}" \
        "${dhcp_start}" "${dhcp_end}" || {
            read -rp "  Shared installer finalization (/usr/local/lib/dayshield/installer-finalize.sh) failed; review preceding [ERR] lines. Press Enter ..."
            return
        }
    _inst_ok "Configuration written."

    # ── Step 7: Bootloader ─────────────────────────────────────────
    clear; _inst_step 7 "${total_steps}" "Installing Bootloader"; printf '\n'
    _inst_install_bootloader "${disk}" || { read -rp "  Bootloader install failed. Press Enter ..."; return; }
    _inst_ok "GRUB installed."

    # ── Finalize ───────────────────────────────────────────────────
    _inst_finalize

    # Clean up any temporarily mounted installation media.
    if [[ -n "${_INST_MEDIA_MOUNT_TMP}" ]]; then
        umount "${_INST_MEDIA_MOUNT_TMP}" 2>/dev/null || true
        rmdir "${_INST_MEDIA_MOUNT_TMP}" 2>/dev/null || true
        _INST_MEDIA_MOUNT_TMP=""
    fi

    _inst_ok "All done."

    # ── Summary ────────────────────────────────────────────────────
    printf '\n'
    _inst_hr
    printf '  DayShield installation complete.\n'
    printf '  Remove the installation media and reboot.\n'
    _inst_hr
    printf '\n'
    printf '  Disk     : /dev/%s\n' "${disk}"
    printf '  Hostname : %s\n' "${hostname}"
    printf '  LAN      : %s  %s/%s\n' "${lan_iface}" "${lan_ip}" "${lan_prefix}"
    [[ -n "${wan_iface}" ]] && printf '  WAN      : %s  (%s)\n' "${wan_iface}" "${wan_type}"
    printf '  DHCP     : %s - %s\n' "${dhcp_start}" "${dhcp_end}"
    printf '\n'
    read -rp "  Reboot now? [Y/n]: " do_reboot || do_reboot=""
    if [[ -z "${do_reboot:-}" || "${do_reboot,,}" == "y" ]]; then
        systemctl reboot
    fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
_load_state
_load_core_state
_console_quiet_enter
trap '_console_quiet_exit' EXIT
trap '_console_quiet_exit; exit 0' INT TERM

if [[ "${CONSOLE_MODE}" == "boot" ]]; then
    if $LIVE_MODE; then
        # Live installer session: run installation wizard automatically.
        _run_install_wizard
    elif [[ "${FIRST_SETUP_DONE}" != "yes" ]]; then
        # Installed system first boot: run management guided setup.
        _run_guided_setup
    fi
fi

while true; do
    clear
    _print_header

    printf "  ${_CB}Actions${_CR}\n"
    _hr
    printf "   ${_CB}${_CY}[0]${_CR}  Open shell\n"
    if [[ "${CONSOLE_MODE}" == "login" ]]; then
        printf "   ${_CB}${_CY}[9]${_CR}  Logout\n"
    fi
    if $LIVE_MODE; then
        printf "   ${_CB}${_CY}[1]${_CR}  Install DayShield\n"
        printf "   ${_CB}${_CY}[2]${_CR}  Setup Web Installer LAN\n"
    else
        printf "   ${_CB}${_CY}[1]${_CR}  Assign interfaces\n"
        printf "   ${_CB}${_CY}[2]${_CR}  Set LAN IP address\n"
        printf "   ${_CB}${_CY}[3]${_CR}  Configure LAN DHCP server\n"
        printf "   ${_CB}${_CY}[4]${_CR}  Change root password\n"
        printf "   ${_CB}${_CY}[5]${_CR}  Reboot system\n"
        printf "   ${_CB}${_CY}[6]${_CR}  Power off system\n"
        printf "   ${_CB}${_CY}[7]${_CR}  Run management setup wizard\n"
        printf "   ${_CB}${_CY}[8]${_CR}  Update DayShield\n"
    fi
    _hr
    echo ""

    printf "${_CB}  Select option: ${_CR}"
    read -r opt
    case "${opt}" in
        0)
            if [[ "${CONSOLE_MODE}" == "boot" ]]; then
                echo "Opening shell … (type 'exit' to return to menu)"
                _console_quiet_exit
                DAYSHIELD_CONSOLE_SUPPRESS=1 /bin/bash --login
                _console_quiet_enter
            else
                echo "Opening shell."
                exit 0
            fi
            ;;
        1)
            if $LIVE_MODE; then
                _run_install_wizard
            else
                _assign_interfaces
            fi
            ;;
        2)
            if $LIVE_MODE; then
                _assign_interfaces && _set_lan_ip
            else
                _set_lan_ip
            fi
            ;;
        3) ! $LIVE_MODE && _set_lan_dhcp ;;
        4) ! $LIVE_MODE && _change_password ;;
        5) ! $LIVE_MODE && _reboot ;;
        6) ! $LIVE_MODE && _shutdown ;;
        7) ! $LIVE_MODE && _run_guided_setup ;;
        8) ! $LIVE_MODE && _update_system ;;
        9)
            if [[ "${CONSOLE_MODE}" == "login" ]]; then
                exit 2
            fi
            ;;
        *) ;;
    esac
done
