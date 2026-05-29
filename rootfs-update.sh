#!/bin/sh
# rootfs-update.sh - A/B rootfs update delegator for DayShield.
#
# The actual A/B slot logic — formatting the inactive partition, unsquashfs,
# copying the kernel+initrd into the slot's /boot/dayshield/slot-X/ directory,
# and flipping grubenv — all lives in dayshield-core (see src/rootfs_update.rs).
#
# This script exists so external automation or older callers can invoke a
# consistent CLI rather than having to call dayshield-core directly with the
# right subcommand.
#
# Actions:
#   apply     — apply the staged rootfs update to the inactive slot
#   rollback  — flip the active slot back to the standby

set -eu

usage() {
    cat <<'EOF'
Usage: rootfs-update.sh <apply|rollback>

  apply     Apply the staged rootfs squashfs to the inactive A/B slot and
            arm grubenv so the new slot is booted on the next reboot.
  rollback  Flip the boot pointer back to the standby slot.
EOF
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

case "$1" in
    apply)
        exec /usr/local/sbin/dayshield-core rootfs-apply
        ;;
    rollback)
        exec /usr/local/sbin/dayshield-core rootfs-rollback
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
