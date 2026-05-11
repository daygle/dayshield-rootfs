#!/bin/sh
# disable-offloads.sh - Disable large packet offloads for better AF_PACKET capture fidelity.
# Safe to run repeatedly.

set -eu

if ! command -v ethtool >/dev/null 2>&1; then
    printf 'dayshield-disable-offloads: ethtool not found, skipping\n' >&2
    exit 0
fi

for iface_path in /sys/class/net/*; do
    [ -e "${iface_path}" ] || continue
    iface="$(basename "${iface_path}")"

    # Skip loopback.
    [ "${iface}" = "lo" ] && continue

    # Some virtual links can reject feature toggles; continue on per-feature failure.
    for feature in gro gso tso lro; do
        ethtool -K "${iface}" "${feature}" off >/dev/null 2>&1 || true
    done
done

exit 0
