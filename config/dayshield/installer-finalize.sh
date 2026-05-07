#!/usr/bin/env bash
# Shared post-install finalization for DayShield installers.
# Applies installed-system credentials/network config to a mounted target rootfs.

set -euo pipefail

_fin_info() { printf '  ...   %s\n' "$*"; }
_fin_err()  { printf '  [ERR] %s\n' "$*" >&2; }

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

if [[ -z "${lan_iface}" || -z "${lan_ip}" || -z "${lan_prefix}" ]]; then
    _fin_err "LAN interface/address/prefix are required"
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

lan_net="${lan_ip%.*}.0"
subnet_cidr="${lan_net}/${lan_prefix}"

# Hostname
printf '%s\n' "${hostname}" > "${target}/etc/hostname"
cat > "${target}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${hostname}
::1         localhost ip6-localhost ip6-loopback
EOF

# Remove the live-ISO default root password from the installed system.
if ! chroot "${target}" passwd -l root >/dev/null 2>&1; then
    _fin_err "WARNING: could not lock root password before update"
fi

# Password update
use_chpasswd=0
if ! printf '%s' "${password}" | grep -q ':' && chroot "${target}" command -v chpasswd >/dev/null 2>&1; then
    if printf '%s\n' "root:${password}" | chroot "${target}" chpasswd >/dev/null 2>&1; then
        use_chpasswd=1
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
        sl="\"${wan_pppoe_user}\" * \"${wan_pppoe_pass}\" *"
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
chroot "${target}" /usr/sbin/unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
chroot "${target}" chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true
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

# Install-time validation criteria
_fin_info "Validating install-time criteria ..."

if grep -qw installer /proc/cmdline 2>/dev/null; then
    if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8443' 2>/dev/null | grep -q .; then
        _fin_err "live installer has an active TCP listener on port 8443"
        exit 1
    fi
fi

svc_condition_file="${target}/etc/systemd/system/dayshield.service.d/dayshield-installer.conf"
if [[ ! -f "${svc_condition_file}" ]] || ! grep -q '^ConditionKernelCommandLine=!installer$' "${svc_condition_file}"; then
    _fin_err "missing installer guard for dayshield.service: ${svc_condition_file}"
    exit 1
fi

_fin_info "Install-time validation checks passed."
