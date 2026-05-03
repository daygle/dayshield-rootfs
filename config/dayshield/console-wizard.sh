#!/usr/bin/env bash
# dayshield-console — DayShield interactive console management wizard.
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

    # LAN — static IP (if configured)
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
            # LAN assigned but no IP yet — bring it up without an address
            cat > "${net_dir}/20-lan.network" <<EOF
[Match]
Name=${LAN_IFACE}

[Network]
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF
        fi
    fi

    networkctl reload 2>/dev/null || true
    sleep 1

    _apply_nftables_config
    _apply_lan_dhcp_config
}

# Write /etc/ppp/peers/wan and restart pppd for PPPoE WAN.
_apply_pppoe_config() {
    mkdir -p /etc/ppp
    # Write peer config — rp-pppoe plugin runs over the physical WAN interface
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
_print_header() {
    local hostname
    hostname="$(hostname -f 2>/dev/null || hostname)"
    local lan_ip4
    lan_ip4=""

    local mode_line=""
    $LIVE_MODE && mode_line=" — LIVE INSTALLER SESSION"

    printf "  DayShield %s (amd64)%s\n" "${DAYSHIELD_VERSION}" "${mode_line}"
    printf "  %s\n" "${DAYSHIELD_SITE}"
    printf "  Hostname: %s\n" "${hostname}"
    echo ""

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
        printf " WAN (%-8s) [%s] -> v4: %s\n" "${WAN_IFACE}" "${wan_type_label}" "${wan_cidr:-no address}"
    fi
    if [[ -n "${LAN_IFACE}" ]]; then
        local lan_cidr
        lan_cidr="$(_iface_ip4 "${LAN_IFACE}")"
        if [[ -z "${lan_cidr}" ]] && [[ -n "${LAN_IP}" ]]; then
            lan_cidr="${LAN_IP}/${LAN_PREFIX}"
        fi
        lan_ip4="${lan_cidr%%/*}"
        printf " LAN (%-8s) -> v4: %s\n" "${LAN_IFACE}" "${lan_cidr:-no address}"
    fi
    if [[ -z "${WAN_IFACE}" && -z "${LAN_IFACE}" ]]; then
        echo " (no interfaces assigned)"
    fi
    echo ""

    if $LIVE_MODE; then
        if [[ -n "${lan_ip4}" ]] && [[ "${lan_ip4}" != "no address" ]]; then
            printf " Management URL: http://%s:8080/\n" "${lan_ip4}"
        else
            echo " Management URL: assign LAN IP (option 2) to get URL"
        fi
        echo ""
    elif [[ -n "${lan_ip4}" ]] && [[ "${lan_ip4}" != "no address" ]]; then
        printf " LAN Management IP: %s\n\n" "${lan_ip4}"
    fi

    _ssh_fingerprints
    echo ""
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------
_assign_interfaces() {
    clear
    echo "=== 1) Assign Interfaces ==="
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

    echo "Available interfaces:"
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
    if [[ "${wan_n}" =~ ^[0-9]+$ ]] && \
       [[ "${wan_n}" -ge 1 ]] && [[ "${wan_n}" -le "${#ifaces[@]}" ]]; then
        WAN_IFACE="${ifaces[$(( wan_n - 1 ))]}"

        # WAN connection type
        echo ""
        echo "WAN connection type:"
        echo "  1) DHCP  (automatic address from ISP)"
        echo "  2) PPPoE (username/password — DSL/fibre)"
        read -rp "Select type [1]: " wan_type_n
        case "${wan_type_n}" in
            2)
                WAN_TYPE="pppoe"
                read -rp "PPPoE username: " WAN_PPPOE_USER
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
    if [[ "${lan_n}" =~ ^[0-9]+$ ]] && \
       [[ "${lan_n}" -ge 1 ]] && [[ "${lan_n}" -le "${#ifaces[@]}" ]]; then
        LAN_IFACE="${ifaces[$(( lan_n - 1 ))]}"
    fi

    _apply_network_config
    _save_state

    echo ""
    echo "  WAN : ${WAN_IFACE:-not assigned}"
    echo "  LAN : ${LAN_IFACE:-not assigned}"
    echo ""
    read -rp "Press Enter to continue …"
}

_set_lan_ip() {
    clear
    echo "=== 2) Set LAN IP Address ==="
    echo ""

    if [[ -z "${LAN_IFACE}" ]]; then
        echo "No LAN interface assigned.  Use option 1 first."
        read -rp "Press Enter to continue …"
        return
    fi

    local default_ip="${LAN_IP:-192.168.1.1}"
    local default_prefix="${LAN_PREFIX:-24}"

    read -rp "LAN IP address [${default_ip}]: " new_ip
    new_ip="${new_ip:-${default_ip}}"

    read -rp "Subnet prefix length [${default_prefix}]: " new_prefix
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
    echo "=== 3) Configure LAN DHCP Server ==="
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
    new_start="${new_start:-${start_default}}"
    read -rp "DHCP range end   [${end_default}]: " new_end
    new_end="${new_end:-${end_default}}"
    read -rp "Lease time [${lease_default}] (e.g. 12h): " new_lease
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
    echo "=== 3) Change Root Password ==="
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
    echo "=== DayShield Initial Setup Wizard ==="
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
    echo "=== 4) Change Root Password ==="
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
# Main loop
# ---------------------------------------------------------------------------
_load_state

if [[ "${CONSOLE_MODE}" == "boot" && "${FIRST_SETUP_DONE}" != "yes" ]]; then
    _run_guided_setup
fi

while true; do
    clear
    _print_header

    if [[ "${CONSOLE_MODE}" == "boot" ]]; then
        echo "  0) Open shell"
    else
        echo "  0) Logout"
    fi
    echo "  1) Assign interfaces"
    echo "  2) Set LAN IP address"
    echo "  3) Configure LAN DHCP server"
    echo "  4) Change root password"
    echo "  5) Reboot system"
    echo "  6) Power off system"
    echo "  7) Run guided setup wizard"
    echo ""

    read -rp "Enter an option: " opt
    case "${opt}" in
        0)
            if [[ "${CONSOLE_MODE}" == "boot" ]]; then
                echo "Opening shell … (type 'exit' to return to menu)"
                DAYSHIELD_CONSOLE_SUPPRESS=1 /bin/bash --login
            else
                echo "Logout requested."
                exit 0
            fi
            ;;
        1) _assign_interfaces ;;
        2) _set_lan_ip ;;
        3) _set_lan_dhcp ;;
        4) _change_password ;;
        5) _reboot ;;
        6) _shutdown ;;
        7) _run_guided_setup ;;
        *) ;;
    esac
done
