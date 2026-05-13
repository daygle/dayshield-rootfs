#!/usr/bin/env bash
# Shared post-install finalization for DayShield installers.
# Applies installed-system credentials/network config to a mounted target rootfs.

set -euo pipefail

_fin_info() { printf '  ...   %s\n' "$*"; }
_fin_warn() { printf '  [WRN] %s\n' "$*"; }
_fin_err()  { printf '  [ERR] %s\n' "$*" >&2; }
_fin_validate_iface_name() {
    local iface="$1"
    [[ "${iface}" =~ ^[a-zA-Z0-9_.-]+$ ]]
}
_fin_validate_hostname() {
    local host="$1"
    [[ "${#host}" -ge 1 && "${#host}" -le 253 ]] || return 1
    [[ "${host}" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    [[ "${host}" != .* && "${host}" != *..* && "${host}" != *- && "${host}" != -* && "${host}" != *. ]] || return 1
}
_fin_validate_ipv4() {
    local ip="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${ip}" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
ipaddress.IPv4Address(sys.argv[1])
PY
        return "$?"
    fi
    awk -F. 'NF==4{for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; exit 0} {exit 1}' <<< "${ip}"
}

if [[ "$#" -ne 12 ]]; then
    _fin_err "usage: $0 <target> <hostname> <password> <wan_iface> <wan_type> <wan_pppoe_user> <wan_pppoe_pass> <lan_iface> <lan_ip> <lan_prefix> <dhcp_start> <dhcp_end>"
    exit 2
fi

target="$1"
hostname="$2"
password="$3"
wan_iface="$4"
wan_type="$5"
wan_pppoe_user="$6"
wan_pppoe_pass="$7"
lan_iface="$8"
lan_ip="$9"
lan_prefix="${10}"
dhcp_start="${11}"
dhcp_end="${12}"

if [[ ! -d "${target}" ]]; then
    _fin_err "target rootfs not found: ${target}"
    exit 1
fi

if ! _fin_validate_hostname "${hostname}"; then
    _fin_err "invalid hostname: ${hostname}"
    exit 1
fi

if ! _fin_validate_iface_name "${lan_iface}"; then
    _fin_err "invalid LAN interface name: ${lan_iface}"
    exit 1
fi

if [[ -n "${wan_iface}" ]] && ! _fin_validate_iface_name "${wan_iface}"; then
    _fin_err "invalid WAN interface name: ${wan_iface}"
    exit 1
fi

if [[ "${wan_type}" != "dhcp" && "${wan_type}" != "pppoe" ]]; then
    _fin_err "invalid WAN type: ${wan_type}"
    exit 1
fi

if [[ "${wan_type}" == "pppoe" && ( -z "${wan_iface}" || -z "${wan_pppoe_user}" || -z "${wan_pppoe_pass}" ) ]]; then
    _fin_err "PPPoE mode requires WAN interface and credentials"
    exit 1
fi

if [[ -z "${lan_iface}" || -z "${lan_ip}" || -z "${lan_prefix}" ]]; then
    _fin_err "LAN interface/address/prefix are required"
    exit 1
fi

if ! _fin_validate_ipv4 "${lan_ip}"; then
    _fin_err "invalid LAN IPv4 address: ${lan_ip}"
    exit 1
fi

if ! [[ "${lan_prefix}" =~ ^[0-9]+$ ]] || [[ "${lan_prefix}" -lt 1 ]] || [[ "${lan_prefix}" -gt 32 ]]; then
    _fin_err "invalid LAN prefix: ${lan_prefix}"
    exit 1
fi

if ! _fin_validate_ipv4 "${dhcp_start}" || ! _fin_validate_ipv4 "${dhcp_end}"; then
    _fin_err "invalid DHCP pool addresses: ${dhcp_start} - ${dhcp_end}"
    exit 1
fi

if [[ ! -f "${target}/etc/shadow" ]]; then
    _fin_err "missing ${target}/etc/shadow"
    exit 1
fi

old_root_field="$(awk -F: '$1=="root"{print $2; exit}' "${target}/etc/shadow" 2>/dev/null || true)"
if [[ -z "${old_root_field}" ]]; then
    _fin_err "could not read existing root password field from ${target}/etc/shadow"
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    lan_net="$(
        python3 - "${lan_ip}" "${lan_prefix}" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
print(network.network_address)
PY
    )"
else
    if [[ "${lan_prefix}" != "24" ]]; then
        _fin_err "python3 is required for calculating non-/24 LAN prefix (currently ${lan_prefix}); install python3 or use /24 prefix"
        exit 1
    fi
    lan_net="${lan_ip%.*}.0"
fi
subnet_cidr="${lan_net}/${lan_prefix}"

# Hostname
printf '%s\n' "${hostname}" > "${target}/etc/hostname"
cat > "${target}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${hostname}
EOF

# Remove the live-ISO default root password from the installed system.
if ! chroot "${target}" passwd -l root >/dev/null 2>&1; then
    _fin_warn "could not lock root password before update"
fi

# Password update
use_chpasswd=0
# chpasswd uses "user:password" records; if the password contains ':' it cannot
# be represented safely in that format, so fall back to direct shadow update.
if ! printf '%s' "${password}" | grep -q ':'; then
    if chroot "${target}" command -v chpasswd >/dev/null 2>&1; then
        if printf '%s\n' "root:${password}" | chroot "${target}" chpasswd >/dev/null 2>&1; then
            use_chpasswd=1
        fi
    fi
fi

if [[ "${use_chpasswd}" -eq 0 ]]; then
    hash=""
    if command -v openssl >/dev/null 2>&1; then
        hash="$(openssl passwd -6 -- "${password}" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        hash="$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "${password}" 2>/dev/null || true)"
    fi

    if [[ -z "${hash}" ]]; then
        _fin_err "password hashing failed"
        exit 1
    fi

    escaped="$(printf '%s' "${hash}" | sed 's|[&/\\]|\\&|g')"
    sed -i "s|^root:[^:]*:|root:${escaped}:|" "${target}/etc/shadow"
fi

new_root_field="$(awk -F: '$1=="root"{print $2; exit}' "${target}/etc/shadow" 2>/dev/null || true)"
if [[ -z "${new_root_field}" || "${new_root_field}" == "${old_root_field}" ]]; then
    _fin_err "root password field did not change in ${target}/etc/shadow"
    exit 1
fi

# DayShield admin.json (management UI credentials)
# dayshield-core uses its own Argon2id auth store — separate from Linux root.
# Use the binary in the target rootfs to hash and write the credentials so the
# same code/parameters are used at install time and at runtime.
if chroot "${target}" /usr/local/sbin/dayshield-core init-admin "${password}" >/dev/null 2>&1; then
    chmod 600 "${target}/etc/dayshield/admin.json" 2>/dev/null || true
    _fin_info "DayShield admin credentials initialised"
else
    _fin_err "dayshield-core init-admin failed; management UI will not be accessible"
    exit 1
fi

# nftables interface mapping
# For PPPoE, traffic exits via ppp0, not the physical WAN interface.
_effective_wan_if="${wan_iface:-lo}"
[[ "${wan_type}" == "pppoe" ]] && _effective_wan_if="ppp0"
mkdir -p "${target}/etc/dayshield/config"
printf 'define WAN_IF = %s\ndefine LAN_IF = %s\n' \
    "${_effective_wan_if}" "${lan_iface}" \
    > "${target}/etc/dayshield/config/nft-ifaces.conf"

# Suricata — update the IDS capture interface to the WAN interface.
# The base rootfs ships with a 'lo' placeholder; replace it with the real
# WAN interface so Suricata actually inspects inbound traffic.
# Prefer WAN; fall back to LAN if no WAN interface was configured.
_suricata_iface="${wan_iface:-${lan_iface}}"
if [[ -f "${target}/etc/suricata/suricata.yaml" ]] && [[ -n "${_suricata_iface}" ]]; then
    # Validate interface name contains only safe characters before use in sed.
    if [[ "${_suricata_iface}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        # Only replace lines with exactly two leading spaces (af-packet / pcap
        # capture entries).  A broader pattern would corrupt app-layer protocol
        # blocks that also contain an 'interface:' key at deeper indentation.
        sed -i "s/^  - interface: .*$/  - interface: ${_suricata_iface}/" \
            "${target}/etc/suricata/suricata.yaml"
        _fin_info "Suricata capture interface set to ${_suricata_iface}"
    else
        _fin_warn "Suricata interface name '${_suricata_iface}' contains unexpected characters; skipping suricata.yaml update"
    fi
fi

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
netdir="${target}/etc/systemd/network"
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
        mkdir -p "${target}/etc/ppp/peers"
        cat > "${target}/etc/ppp/peers/wan" <<EOF
plugin rp-pppoe.so ${wan_iface}
user "${wan_pppoe_user}"
linkname wan
pidfile /run/ppp-wan.pid
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
        ppp_auth_line="\"${wan_pppoe_user}\" * \"${wan_pppoe_pass}\" *"
        printf '%s\n' "${ppp_auth_line}" > "${target}/etc/ppp/chap-secrets"
        printf '%s\n' "${ppp_auth_line}" > "${target}/etc/ppp/pap-secrets"
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
if ! chroot "${target}" /usr/sbin/unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1; then
    _fin_warn "unbound-anchor failed; DNSSEC trust anchor may be missing until first successful refresh"
fi
if ! chroot "${target}" chown -R unbound:unbound /var/lib/unbound 2>/dev/null; then
    _fin_warn "failed to set unbound ownership for /var/lib/unbound"
fi
cat > "${target}/etc/unbound/unbound.conf" <<EOF
server:
  interface: 0.0.0.0
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
EOF

# DayShield core config.json
# Generate a stable UUID for the seeded LAN accept rule.
_lan_rule_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')"

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
  "firewall_rules": [
    {
      "id": "${_lan_rule_uuid}",
      "description": "Default: allow all from LAN",
      "priority": 10,
      "source": null,
      "destination": null,
      "protocol": null,
      "source_port": null,
      "destination_port": null,
      "action": "accept",
      "interface": "${lan_iface}",
      "log": false
    }
  ],
  "nat": null,
  "dns": null,
  "dhcp": {
    "enabled": true,
    "interface": "${lan_iface}",
    "scopes": [ { "start": "${dhcp_start}", "end": "${dhcp_end}", "lease_time": 43200 } ]
  }
}
EOF

# Install-time validation criteria
_fin_info "Validating install-time criteria ..."

if grep -qE '(^|[[:space:]])installer([[:space:]]|$)' /proc/cmdline 2>/dev/null; then
    if command -v ss >/dev/null 2>&1; then
        # Prevent installer-live/service conflicts on the management redirect port.
        if ss -H -ltn 'sport = :8443' 2>/dev/null | grep -q '[0-9]'; then
            _fin_err "live installer has an active TCP listener on port 8443"
            exit 1
        fi
    fi
fi

svc_condition_file="${target}/etc/systemd/system/dayshield.service.d/dayshield-installer.conf"
if [[ ! -f "${svc_condition_file}" ]] || ! grep -Eq '^[[:space:]]*ConditionKernelCommandLine[[:space:]]*=[[:space:]]*!installer[[:space:]]*$' "${svc_condition_file}"; then
    _fin_err "dayshield.service missing installer guard ConditionKernelCommandLine=!installer in ${svc_condition_file}"
    exit 1
fi

_fin_info "Install-time validation checks passed."
