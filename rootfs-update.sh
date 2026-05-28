#!/bin/sh
# rootfs-update.sh - rootfs image update hook for DayShield.
# POSIX shell compatible.

set -eu

STATE_DIR="/var/lib/dayshield/rootfs-update"
STAGING_DIR="${STATE_DIR}/staging"
IMAGE_STORE="/boot/dayshield/images"
BOOT_DAYSHIELD="/boot/dayshield"

usage() {
    cat <<'EOF'
Usage: rootfs-update.sh <action>

Actions:
  stage    Ensure the staging directory exists ready for a new rootfs artifact.
  apply    Move the staged image to the boot image store and activate it for next boot.
  rollback Point the boot candidate at the previous known-good image for next boot.
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
        artifact_path="$(json_value "artifactPath" "${PENDING}")"
        if [ -z "${artifact_path}" ]; then
            printf 'ERROR: Could not read artifactPath from %s\n' "${PENDING}" >&2
            exit 1
        fi
        if [ ! -f "${artifact_path}" ]; then
            printf 'ERROR: Staged artifact not found: %s\n' "${artifact_path}" >&2
            exit 1
        fi
        mkdir -p "${IMAGE_STORE}"
        dest_image="${IMAGE_STORE}/rootfs-${version}.squashfs"
        mv -f "${artifact_path}" "${dest_image}"
        chmod 644 "${dest_image}"
        ln -sfn "images/rootfs-${version}.squashfs" "${BOOT_DAYSHIELD}/next"
        printf 'Rootfs version %s moved to image store and activated for next boot.\n' "${version}"
        ;;
    rollback)
        PREVIOUS="${STATE_DIR}/previous.json"
        if [ ! -f "${PREVIOUS}" ]; then
            printf 'ERROR: No previous rootfs version available for rollback (%s).\n' "${PREVIOUS}" >&2
            exit 1
        fi
        version="$(json_value "version" "${PREVIOUS}")"
        if [ -z "${version}" ]; then
            printf 'ERROR: Could not read version from %s\n' "${PREVIOUS}" >&2
            exit 1
        fi
        prev_image="${IMAGE_STORE}/rootfs-${version}.squashfs"
        if [ ! -f "${prev_image}" ]; then
            printf 'ERROR: Previous rootfs image not found in image store: %s\n' "${prev_image}" >&2
            exit 1
        fi
        ln -sfn "images/rootfs-${version}.squashfs" "${BOOT_DAYSHIELD}/next"
        printf 'Rollback to version %s activated for next boot.\n' "${version}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
