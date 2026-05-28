#!/bin/sh
# rootfs-update.sh - generic rootfs image update hook for DayShield.
# POSIX shell compatible.

set -eu

usage() {
    cat <<'EOF'
Usage: rootfs-update.sh apply

Delegates rootfs update orchestration to dayshield-core using version/image
semantics. The actual image staging, verification, and reboot coordination are
handled by dayshield-core and the boot/update stack in other DayShield repos.
EOF
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

case "$1" in
    apply)
        exec /usr/local/sbin/dayshield-core update-apply rootfs
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
