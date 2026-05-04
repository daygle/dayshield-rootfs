#!/usr/bin/env bash
# dayshield-console - DayShield interactive console management wizard.
#
# Modelled after the OPNsense/pfSense console menu.  Runs on tty1 in both the
# live installer session and the installed system.  Live mode is detected
# automatically from /proc/cmdline.

set -uo pipefail

DAYSHIELD_VERSION="1.0"
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
    # shellcheck source=/dev/null
    [[ -f "${state_file}" ]] && . "${state_file}"
}

_save_state() {
    mkdir -p /etc/dayshield
    printf 'WAN_IFACE=%q\nWAN_TYPE=%q\nWAN_PPPOE_USER=%q\nWAN_PPPOE_PASS=%q\nLAN_IFACE=%q\nLAN_IP=%q\nLAN_PREFIX=%q\nLAN_DHCP_ENABLE=%q\nLAN_DHCP_START=%q\nLAN_DHCP_END=%q\nLAN_DHCP_LEASE=%q\nFIRST_SETUP_DONE=%q\n' \
        "${WAN_IFACE}" "${WAN_TYPE}" "${WAN_PPPOE_USER}" "${WAN_PPPOE_PASS}" \
        "${LAN_IFACE}" "${LAN_IP}" "${LAN_PREFIX}" \
        "${LAN_DHCP_ENABLE}" "${LAN_DHCP_START}" "${LAN_DHCP_END}" "${LAN_DHCP_LEASE}" \
        "${FIRST_SETUP_DONE}" \
        > /etc/dayshield/console-state
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

_apply_lan_dhcp_config() {
    local kea_conf="/etc/kea/kea-dhcp4.conf"

    if [[ "${LAN_DHCP_ENABLE}" == "yes" ]] && [[ -n "${LAN_IFACE}" ]] && [[ -n "${LAN_IP}" ]] && [[ -n "${LAN_DHCP_START}" ]] && [[ -n "${LAN_DHCP_END}" ]]; then
        mkdir -p /etc/kea /var/log/kea /var/lib/kea

        # Compute network address for Kea subnet (e.g. 192.168.1.0/24)
        local prefix="${LAN_PREFIX:-24}"
        local o1 o2 o3 o4
        IFS='.' read -r o1 o2 o3 o4 <<< "${LAN_IP}"
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

        systemctl enable kea-dhcp4-server >/dev/null 2>&1 || true
        systemctl restart kea-dhcp4-server >/dev/null 2>&1 || true
    else
        systemctl stop kea-dhcp4-server >/dev/null 2>&1 || true
    fi
}

_apply_nftables_config() {
    local nft_ifaces="/etc/dayshield/config/nft-ifaces.conf"
    mkdir -p /etc/dayshield/config
    printf 'define WAN_IF = %s\ndefine LAN_IF = %s\n' \
        "${WAN_IFACE:-lo}" "${LAN_IFACE:-lo}" > "${nft_ifaces}"
    nft -f /etc/nftables.conf 2>/dev/null || true
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
IPv6AcceptRA=no
LinkLocalAddressing=no
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

    networkctl reload 2>/dev/null || true
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
    # Write peer config - rp-pppoe plugin runs over the physical WAN interface
    cat > /etc/ppp/peers/wan <<EOF
plugin rp-pppoe.so ${WAN_IFACE}
user "${WAN_PPPOE_USER}"
noauth
defaultroute
replacedefaultroute
hide-password
persist
maxfail 0
holdoff 5
noipv6
EOF
    chmod 600 /etc/ppp/peers/wan

    # Write credentials to chap-secrets and pap-secrets
    local secrets_line="\"${WAN_PPPOE_USER}\" * \"${WAN_PPPOE_PASS}\" *"
    printf '%s\n' "${secrets_line}" > /etc/ppp/chap-secrets
    printf '%s\n' "${secrets_line}" > /etc/ppp/pap-secrets
    chmod 600 /etc/ppp/chap-secrets /etc/ppp/pap-secrets

    # Stop any existing pppd on this WAN
    pkill -f "pppd call wan" 2>/dev/null || true
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
# Header / status display
# ---------------------------------------------------------------------------
_hr() {
    printf '  ------------------------------------------------------------\n'
}

_kv() {
    printf '  %-20s %s\n' "$1" "$2"
}

_print_header() {
    local hostname
    hostname="$(hostname -f 2>/dev/null || hostname)"
    local lan_ip4
    lan_ip4=""

    local mode_line=""
    $LIVE_MODE && mode_line=" - LIVE INSTALLER SESSION"

    _hr
    printf "  DayShield Console  v%s%s\n" "${DAYSHIELD_VERSION}" "${mode_line}"
    _kv "Site" "${DAYSHIELD_SITE}"
    _kv "Hostname" "${hostname}"
    _hr
    printf "  Network Summary\n"

    # Interface status
    if [[ -n "${WAN_IFACE}" ]]; then
        local wan_cidr wan_type_label
        if [[ "${WAN_TYPE}" == "pppoe" ]]; then
            # For PPPoE, show ppp0 address if up
            wan_cidr="$(_iface_ip4 ppp0 2>/dev/null || true)"
            wan_type_label="PPPoE"
        else
            wan_cidr="$(_iface_ip4 "${WAN_IFACE}")"
            wan_type_label="DHCP"
        fi
        _kv "WAN ${WAN_IFACE} (${wan_type_label})" "${wan_cidr:-no address}"
    fi
    if [[ -n "${LAN_IFACE}" ]]; then
        local lan_cidr
        lan_cidr="$(_iface_ip4 "${LAN_IFACE}")"
        if [[ -z "${lan_cidr}" ]] && [[ -n "${LAN_IP}" ]]; then
            lan_cidr="${LAN_IP}/${LAN_PREFIX}"
        fi
        lan_ip4="${lan_cidr%%/*}"
        _kv "LAN ${LAN_IFACE}" "${lan_cidr:-no address}"
    fi
    if [[ -z "${WAN_IFACE}" && -z "${LAN_IFACE}" ]]; then
        _kv "Interfaces" "not assigned"
    fi
    echo ""

    if $LIVE_MODE; then
        local web_rows=()
        while IFS=$'\t' read -r iface ip; do
            web_rows+=("http://${ip}:8080/ (${iface})")
        done < <(_live_web_ifaces_with_ip)

        if [[ ${#web_rows[@]} -gt 0 ]]; then
            _kv "Web Installer" "${web_rows[0]}"
            local idx
            for idx in "${!web_rows[@]}"; do
                [[ "${idx}" -eq 0 ]] && continue
                _kv "" "${web_rows[${idx}]}"
            done
        else
            _kv "Web Installer" "no IPv4 address detected yet"
            _kv "Hint" "use option 9 to configure LAN for Web Installer"
        fi
        echo ""
    elif [[ -n "${lan_ip4}" ]] && [[ "${lan_ip4}" != "no address" ]]; then
        _kv "LAN Management IP" "${lan_ip4}"
        echo ""
    fi

    printf "  SSH Host Key Fingerprints\n"
    _ssh_fingerprints
    _hr
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
    if ! [[ "${new_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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

    if ! [[ "${new_start}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
       ! [[ "${new_end}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Invalid DHCP range."
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
    [[ "${confirm,,}" == "y" ]] && systemctl reboot
}

_shutdown() {
    echo ""
    read -rp "Shut down now? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] && systemctl poweroff
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
    _print_header
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

    _inst_info "Creating GPT layout (512 MiB EFI + rest root) ..."
    if command -v sgdisk >/dev/null 2>&1; then
        sgdisk --zap-all \
            --new=1:0:+512M  --typecode=1:EF00 --change-name=1:"EFI System" \
            --new=2:0:0       --typecode=2:8300 --change-name=2:"Linux Root" \
            "/dev/${dev}" >/dev/null 2>&1 || { _inst_err "sgdisk failed."; return 1; }
    elif command -v parted >/dev/null 2>&1; then
        parted -s "/dev/${dev}" \
            mklabel gpt \
            mkpart primary fat32 1MiB 513MiB \
            set 1 esp on \
            mkpart primary ext4 513MiB 100% >/dev/null 2>&1 || { _inst_err "parted failed."; return 1; }
    else
        _inst_err "Neither sgdisk nor parted found."
        return 1
    fi

    _inst_info "Waiting for partition nodes ..."
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
    local pfx
    case "$dev" in nvme*|mmcblk*) pfx="${dev}p" ;; *) pfx="${dev}" ;; esac
    local waited=0
    while ! [[ -b "/dev/${pfx}1" ]] || ! [[ -b "/dev/${pfx}2" ]]; do
        sleep 1; waited=$(( waited + 1 ))
        [[ ${waited} -ge 10 ]] && { _inst_err "Partition nodes did not appear."; return 1; }
    done
    return 0
}

_inst_format() {
    local dev="$1" pfx
    case "$dev" in nvme*|mmcblk*) pfx="${dev}p" ;; *) pfx="${dev}" ;; esac
    local efi="/dev/${pfx}1" root="/dev/${pfx}2"

    _inst_info "Formatting ${efi} as FAT32 (EFI) ..."
    mkfs.fat -F32 -n "EFI" "${efi}" >/dev/null 2>&1 || { _inst_err "mkfs.fat failed."; return 1; }

    _inst_info "Formatting ${root} as ext4 (root) ..."
    mkfs.ext4 -F -L "dayshield-root" -O "^64bit,metadata_csum" -m 1 \
        "${root}" >/dev/null 2>&1 || { _inst_err "mkfs.ext4 failed."; return 1; }
    return 0
}

_inst_find_rootfs() {
    for candidate in \
        "/run/installer/rootfs.tar.zst" \
        "/lib/live/mount/medium/installer/rootfs.tar.zst" \
        "/run/live/medium/installer/rootfs.tar.zst" \
        "/media/cdrom/installer/rootfs.tar.zst" \
        "/media/live/installer/rootfs.tar.zst"
    do
        [[ -f "${candidate}" ]] && printf '%s' "${candidate}" && return 0
    done
    # Last resort: scan for DAYSHIELD-labelled block device
    local bdev mp
    bdev=$(blkid -t LABEL=DAYSHIELD -o device 2>/dev/null | head -n1)
    if [[ -n "${bdev}" ]]; then
        mp=$(mktemp -d)
        if mount -o ro "${bdev}" "${mp}" 2>/dev/null; then
            if [[ -f "${mp}/installer/rootfs.tar.zst" ]]; then
                printf '%s' "${mp}/installer/rootfs.tar.zst"
                return 0   # leave mounted; caller must umount $mp
            fi
            umount "${mp}" 2>/dev/null || true
        fi
        rmdir "${mp}" 2>/dev/null || true
    fi
    return 1
}

_inst_install_rootfs() {
    local dev="$1" rootfs="$2" pfx target="/mnt/target"
    case "$dev" in nvme*|mmcblk*) pfx="${dev}p" ;; *) pfx="${dev}" ;; esac
    local efi="/dev/${pfx}1" root="/dev/${pfx}2"

    _inst_info "Mounting root partition ..."
    mkdir -p "${target}"
    mount "${root}" "${target}" || { _inst_err "Failed to mount ${root}."; return 1; }

    _inst_info "Mounting EFI partition ..."
    mkdir -p "${target}/boot/efi"
    mount "${efi}" "${target}/boot/efi" || {
        umount "${target}" 2>/dev/null || true
        _inst_err "Failed to mount EFI partition."; return 1
    }

    _inst_info "Extracting rootfs (this may take several minutes) ..."
    if command -v zstd >/dev/null 2>&1; then
        zstd -d --stdout "${rootfs}" | tar -xp -C "${target}" || {
            umount "${target}/boot/efi" 2>/dev/null || true
            umount "${target}" 2>/dev/null || true
            _inst_err "Extraction failed."; return 1
        }
    elif tar --version 2>&1 | grep -q "GNU tar"; then
        tar -xp --zstd -f "${rootfs}" -C "${target}" || {
            umount "${target}/boot/efi" 2>/dev/null || true
            umount "${target}" 2>/dev/null || true
            _inst_err "Extraction failed (GNU tar)."; return 1
        }
    else
        _inst_err "Neither zstd nor GNU tar available."; return 1
    fi
    return 0
}

_inst_install_bootloader() {
    local dev="$1" target="/mnt/target"

    _inst_info "Binding pseudo-filesystems ..."
    for fs in proc sys dev dev/pts; do
        mkdir -p "${target}/${fs}"
        mount --bind "/${fs}" "${target}/${fs}" >/dev/null 2>&1 || true
    done

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
    local lan_net subnet_cidr
    lan_net="${lan_ip%.*}.0"
    subnet_cidr="${lan_net}/${lan_prefix}"

    # Hostname
    printf '%s\n' "${hostname}" > "${target}/etc/hostname"
    cat > "${target}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${hostname}
::1         localhost ip6-localhost ip6-loopback
EOF

    # Password hash
    local hash=""
    if command -v openssl >/dev/null 2>&1; then
        hash=$(openssl passwd -6 -- "${password}" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        hash=$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "${password}" 2>/dev/null)
    fi
    if [[ -z "${hash}" ]]; then
        _inst_err "Password hashing failed — default password retained"
    elif [[ -f "${target}/etc/shadow" ]]; then
        local escaped
        escaped=$(printf '%s' "${hash}" | sed 's|[&/\\]|\\&|g')
        sed -i "s|^root:[^:]*:|root:${escaped}:|" "${target}/etc/shadow"
    fi

    # nftables interface mapping
    mkdir -p "${target}/etc/dayshield/config"
    printf 'define WAN_IF = %s\ndefine LAN_IF = %s\n' \
        "${wan_iface:-lo}" "${lan_iface}" \
        > "${target}/etc/dayshield/config/nft-ifaces.conf"

    # DayShield network.conf
    mkdir -p "${target}/etc/dayshield"
    cat > "${target}/etc/dayshield/network.conf" <<EOF
LAN_IFACE=${lan_iface}
LAN_IP=${lan_ip}
LAN_PREFIX=${lan_prefix}
LAN_DHCP_ENABLE=yes
LAN_DHCP_START=${dhcp_start}
LAN_DHCP_END=${dhcp_end}
EOF

    # systemd-networkd
    local netdir="${target}/etc/systemd/network"
    mkdir -p "${netdir}"
    rm -f "${netdir}/10-dayshield-eth.network"
    if [[ -n "${wan_iface}" ]]; then
        if [[ "${wan_type}" == "pppoe" ]]; then
            cat > "${netdir}/10-wan.network" <<EOF
[Match]
Name=${wan_iface}

[Network]
DHCP=no
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
            mkdir -p "${target}/etc/ppp"
            cat > "${target}/etc/ppp/peers/wan" <<EOF
plugin rp-pppoe.so ${wan_iface}
user "${wan_pppoe_user}"
noauth
defaultroute
replacedefaultroute
hide-password
persist
maxfail 0
holdoff 5
noipv6
EOF
            chmod 600 "${target}/etc/ppp/peers/wan"
            local sl="\"${wan_pppoe_user}\" * \"${wan_pppoe_pass}\" *"
            printf '%s\n' "${sl}" > "${target}/etc/ppp/chap-secrets"
            printf '%s\n' "${sl}" > "${target}/etc/ppp/pap-secrets"
            chmod 600 "${target}/etc/ppp/chap-secrets" "${target}/etc/ppp/pap-secrets"
        else
            cat > "${netdir}/10-wan.network" <<EOF
[Match]
Name=${wan_iface}

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
        fi
    fi
    cat > "${netdir}/20-lan.network" <<EOF
[Match]
Name=${lan_iface}

[Network]
Address=${lan_ip}/${lan_prefix}
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF

    # Kea DHCPv4
    mkdir -p "${target}/etc/kea" "${target}/var/lib/kea" "${target}/var/log/kea"
    cat > "${target}/etc/kea/kea-dhcp4.conf" <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["${lan_iface}"],
      "dhcp-socket-type": "raw"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv"
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "${subnet_cidr}",
        "pools": [ { "pool": "${dhcp_start} - ${dhcp_end}" } ],
        "valid-lifetime": 43200,
        "option-data": [
          { "name": "routers",             "data": "${lan_ip}" },
          { "name": "domain-name-servers", "data": "${lan_ip}" }
        ]
      }
    ],
    "loggers": [
      { "name": "kea-dhcp4", "output_options": [ { "output": "/var/log/kea/kea-dhcp4.log" } ], "severity": "INFO" }
    ]
  }
}
EOF

    # Unbound DNS
    mkdir -p "${target}/etc/unbound" "${target}/var/lib/unbound"
    cat > "${target}/etc/unbound/unbound.conf" <<EOF
server:
  interface: 127.0.0.1
  interface: ${lan_ip}
  port: 53
  do-ip4: yes
  do-ip6: no
  do-udp: yes
  do-tcp: yes
  access-control: 127.0.0.0/8 allow
  access-control: ${subnet_cidr} allow
  access-control: 0.0.0.0/0 refuse
  auto-trust-anchor-file: "/var/lib/unbound/root.key"
  root-hints: "/usr/share/dns/root.hints"
  harden-glue: yes
  harden-dnssec-stripped: yes
  use-caps-for-id: yes
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes
  cache-min-ttl: 300
  cache-max-ttl: 86400
  prefetch: yes
  num-threads: 2
  rrset-cache-size: 256m
  msg-cache-size: 128m
  private-address: 10.0.0.0/8
  private-address: 172.16.0.0/12
  private-address: 192.168.0.0/16
  private-address: 100.64.0.0/10
  minimal-responses: yes
  directory: "/etc/unbound"
  chroot: ""
  pidfile: "/run/unbound/unbound.pid"
EOF

    # DayShield core config.json
    cat > "${target}/etc/dayshield/config/config.json" <<EOF
{
  "hostname": "${hostname}",
  "domain": null,
  "interfaces": [
    {
      "name": "${lan_iface}",
      "description": "LAN",
      "addresses": ["${lan_ip}/${lan_prefix}"],
      "mtu": 1500,
      "enabled": true,
      "dhcp4": false,
      "dhcp6": false,
      "vlan": null,
      "wan_mode": null,
      "pppoe_username": null,
      "pppoe_password": null,
      "gateway": null
    }
  ],
  "firewall_rules": [],
  "nat": null,
  "dns": null,
  "dhcp": {
    "enabled": true,
    "interface": "${lan_iface}",
    "scopes": [ { "start": "${dhcp_start}", "end": "${dhcp_end}", "lease_time": 43200 } ]
  }
}
EOF
}

_inst_finalize() {
    local target="/mnt/target"
    _inst_info "Syncing writes ..."
    sync
    for fs in dev/pts dev sys proc; do
        umount "${target}/${fs}" 2>/dev/null || true
    done
    _inst_info "Unmounting EFI partition ..."
    umount "${target}/boot/efi" 2>/dev/null || _inst_err "EFI umount warning"
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

    # ── Step 5: Partition and format ───────────────────────────────
    clear; _inst_step 5 "${total_steps}" "Partitioning and Formatting"; printf '\n'
    _inst_partition "${disk}" || { read -rp "  Partitioning failed. Press Enter ..."; return; }
    _inst_ok "Partitions created."
    _inst_format "${disk}"    || { read -rp "  Formatting failed. Press Enter ...";   return; }
    _inst_ok "Partitions formatted."

    # ── Step 6: Install rootfs ─────────────────────────────────────
    clear; _inst_step 6 "${total_steps}" "Installing Root Filesystem"; printf '\n'
    _inst_info "Locating rootfs archive ..."
    rootfs="$(_inst_find_rootfs || true)"
    if [[ -z "${rootfs}" ]]; then
        _inst_err "rootfs archive not found. Ensure ISO contains /installer/rootfs.tar.zst"
        read -rp "  Press Enter ..."; return
    fi
    _inst_ok "Found: ${rootfs}"
    _inst_install_rootfs "${disk}" "${rootfs}" || { read -rp "  rootfs install failed. Press Enter ..."; return; }
    _inst_ok "Root filesystem extracted."
    _inst_info "Writing system configuration ..."
    _inst_write_config \
        "${hostname}" "${password}" \
        "${wan_iface}" "${wan_type}" "${wan_pppoe_user}" "${wan_pppoe_pass}" \
        "${lan_iface}" "${lan_ip}" "${lan_prefix}" \
        "${dhcp_start}" "${dhcp_end}"
    _inst_ok "Configuration written."

    # ── Step 7: Bootloader ─────────────────────────────────────────
    clear; _inst_step 7 "${total_steps}" "Installing Bootloader"; printf '\n'
    _inst_install_bootloader "${disk}" || { read -rp "  Bootloader install failed. Press Enter ..."; return; }
    _inst_ok "GRUB installed."

    # ── Finalize ───────────────────────────────────────────────────
    _inst_finalize
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
_console_quiet_enter
trap _console_quiet_exit EXIT INT TERM

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

    echo "  Main Menu"
    echo ""
    if [[ "${CONSOLE_MODE}" == "boot" ]]; then
        echo "  [0] Open shell                 - local rescue shell"
    else
        echo "  [0] Logout                     - return to login prompt"
    fi
    if $LIVE_MODE; then
        echo "  [8] Install DayShield          - run disk installation wizard"
        echo "  [9] Setup Web Installer LAN    - assign interface and LAN IP"
    else
        echo "  [1] Assign interfaces          - choose WAN and LAN adapters"
        echo "  [2] Set LAN IP address         - configure LAN gateway address"
        echo "  [3] Configure LAN DHCP server  - client address pool"
        echo "  [4] Change root password       - local console/root password"
        echo "  [5] Reboot system"
        echo "  [6] Power off system"
        echo "  [7] Run management setup wizard"
    fi
    echo ""

    read -rp "Select option: " opt
    case "${opt}" in
        0)
            if [[ "${CONSOLE_MODE}" == "boot" ]]; then
                echo "Opening shell … (type 'exit' to return to menu)"
                _console_quiet_exit
                DAYSHIELD_CONSOLE_SUPPRESS=1 /bin/bash --login
                _console_quiet_enter
            else
                echo "Logout requested."
                exit 0
            fi
            ;;
        1) ! $LIVE_MODE && _assign_interfaces ;;
        2) ! $LIVE_MODE && _set_lan_ip ;;
        3) ! $LIVE_MODE && _set_lan_dhcp ;;
        4) ! $LIVE_MODE && _change_password ;;
        5) ! $LIVE_MODE && _reboot ;;
        6) ! $LIVE_MODE && _shutdown ;;
        7) ! $LIVE_MODE && _run_guided_setup ;;
        8) $LIVE_MODE && _run_install_wizard ;;
        9) $LIVE_MODE && _assign_interfaces && _set_lan_ip ;;
        *) ;;
    esac
done
