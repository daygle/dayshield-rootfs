#!/bin/sh
# rootfs-update.sh - rootfs image update hook for DayShield.
# POSIX shell compatible.

set -eu

STATE_DIR="/var/lib/dayshield/rootfs-update"
STAGING_DIR="${STATE_DIR}/staging"

usage() {
    cat <<'EOF'
Usage: rootfs-update.sh <action>

Actions:
  stage    Ensure the staging directory exists ready for a new rootfs artifact.
  apply    Mark the staged rootfs image for activation on next boot.
  rollback Schedule a revert to the previous known-good version on next boot.
EOF
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

# Extract a simple quoted JSON string value matching "key": "value"
json_value() {
    sed -n -E "s/^[[:space:]]*\"${1}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$2" | head -n1
}

case "$1" in
    stage)
        mkdir -p "${STAGING_DIR}"
        printf 'Staging directory ready: %s\n' "${STAGING_DIR}"
        ;;
    apply)
        PENDING="${STATE_DIR}/pending.json"
        if [ ! -f "${PENDING}" ]; then
            printf 'ERROR: No staged rootfs update found (%s). Stage an update first.\n' "${PENDING}" >&2
            exit 1
        fi
        version="$(json_value "version" "${PENDING}")"
        if [ -z "${version}" ]; then
            printf 'ERROR: Could not read version from %s\n' "${PENDING}" >&2
            exit 1
        fi
        printf '%s' "${version}" > "${STATE_DIR}/activate"
        printf 'Rootfs version %s marked for activation on next boot.\n' "${version}"
        ;;
    rollback)
        PREVIOUS="${STATE_DIR}/previous.json"
        if [ ! -f "${PREVIOUS}" ]; then
            printf 'ERROR: No previous rootfs version available for rollback (%s).\n' "${PREVIOUS}" >&2
            exit 1
        fi
        version="$(json_value "version" "${PREVIOUS}")"
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STATE_DIR}/rollback"
        printf 'Rollback to version %s scheduled for next boot.\n' "${version:-previous}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
