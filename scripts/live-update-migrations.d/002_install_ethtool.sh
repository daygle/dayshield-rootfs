#!/bin/sh
# Ensure ethtool exists on already-installed appliances so offload toggles can run.
# Non-fatal: skips quietly when package management is unavailable.

set -eu

if command -v dpkg >/dev/null 2>&1 && dpkg -s ethtool >/dev/null 2>&1; then
    exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null 2>&1 || exit 0
apt-get install -y --no-install-recommends ethtool >/dev/null 2>&1 || exit 0

exit 0
