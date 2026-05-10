#!/bin/sh
# apply-live-update.sh - Apply managed DayShield rootfs updates on an installed appliance.
# Preserves existing runtime settings by default and stages config deltas as *.dayshield-new.
# Supports rollback to the most recent snapshot and emits a machine-readable report.
# POSIX shell compatible.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_DIR}/config"

STATE_DIR="/var/lib/dayshield/rootfs-live-update"
BACKUPS_DIR="${STATE_DIR}/backups"
REPORT_FILE="${STATE_DIR}/last-run.json"
SCHEMA_VERSION_FILE="${STATE_DIR}/schema-version"
MIGRATIONS_DIR="${SCRIPT_DIR}/live-update-migrations.d"

MODE="apply"

while [ $# -gt 0 ]; do
    case "$1" in
        --rollback-latest) MODE="rollback" ;;
        --non-interactive) ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
    shift
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUPS_DIR}/${STAMP}"
CHANGED_UNITS_FILE="${STATE_DIR}/changed-units.${STAMP}.txt"
STAGED_FILES_FILE="${STATE_DIR}/staged-files.${STAMP}.txt"
STAGED_CHANGES=0
MIGRATION_FROM=0
MIGRATION_TO=0

mkdir -p "${STATE_DIR}" "${BACKUPS_DIR}"

log() {
    printf 'rootfs-live-update: %s\n' "$*"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf 'ERROR: rootfs live update must run as root\n' >&2
        exit 1
    fi
}

ensure_parent() {
    _dst="$1"
    mkdir -p "$(dirname "${_dst}")"
}

backup_existing() {
    _dst="$1"
    if [ -f "${_dst}" ]; then
        _backup_path="${BACKUP_DIR}${_dst}"
        mkdir -p "$(dirname "${_backup_path}")"
        cp -a "${_dst}" "${_backup_path}"
    fi
}

record_staged_file() {
    _path="$1"
    grep -qx "${_path}" "${STAGED_FILES_FILE}" 2>/dev/null || printf '%s\n' "${_path}" >> "${STAGED_FILES_FILE}"
}

install_managed_file() {
    _src="$1"
    _dst="$2"
    _mode="$3"

    [ -f "${_src}" ] || return 0
    ensure_parent "${_dst}"

    if [ -f "${_dst}" ] && cmp -s "${_src}" "${_dst}"; then
        return 0
    fi

    backup_existing "${_dst}"
    cp -f "${_src}" "${_dst}"
    chmod "${_mode}" "${_dst}"
    log "updated ${_dst}"
}

stage_preserving_file() {
    _src="$1"
    _dst="$2"
    _mode="$3"

    [ -f "${_src}" ] || return 0
    ensure_parent "${_dst}"

    if [ ! -f "${_dst}" ]; then
        cp -f "${_src}" "${_dst}"
        chmod "${_mode}" "${_dst}"
        log "installed missing ${_dst}"
        return 0
    fi

    if cmp -s "${_src}" "${_dst}"; then
        return 0
    fi

    _staged="${_dst}.dayshield-new"
    cp -f "${_src}" "${_staged}"
    chmod "${_mode}" "${_staged}"
    STAGED_CHANGES=$((STAGED_CHANGES + 1))
    record_staged_file "${_staged}"
    log "preserved ${_dst}; staged update at ${_staged}"
}

record_changed_unit() {
    _unit="$1"
    grep -qx "${_unit}" "${CHANGED_UNITS_FILE}" 2>/dev/null || printf '%s\n' "${_unit}" >> "${CHANGED_UNITS_FILE}"
}

reload_systemd_units() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl unavailable; skipped service reload"
        return 0
    fi

    systemctl daemon-reload || true

    while IFS= read -r unit; do
        [ -n "${unit}" ] || continue

        if systemctl is-enabled "${unit}" >/dev/null 2>&1 || systemctl is-active --quiet "${unit}"; then
            systemctl try-reload-or-restart "${unit}" >/dev/null 2>&1 || true
            log "reloaded/restarted ${unit}"
        fi
    done < "${CHANGED_UNITS_FILE}"
}

current_schema_version() {
    if [ -f "${SCHEMA_VERSION_FILE}" ]; then
        cat "${SCHEMA_VERSION_FILE}"
    else
        printf '0\n'
    fi
}

run_migrations() {
    MIGRATION_FROM="$(current_schema_version)"
    MIGRATION_TO="${MIGRATION_FROM}"

    [ -d "${MIGRATIONS_DIR}" ] || return 0

    for migration in $(find "${MIGRATIONS_DIR}" -maxdepth 1 -type f -name '*.sh' | sort); do
        name="$(basename "${migration}")"
        next="$(printf '%s' "${name}" | sed 's/^\([0-9][0-9]*\).*/\1/')"
        case "${next}" in
            ''|*[!0-9]*) continue ;;
        esac

        if [ "${next}" -le "${MIGRATION_TO}" ]; then
            continue
        fi

        log "running migration ${name}"
        ROOTFS_LIVE_UPDATE_STATE_DIR="${STATE_DIR}" sh "${migration}"
        MIGRATION_TO="${next}"
    done

    printf '%s\n' "${MIGRATION_TO}" > "${SCHEMA_VERSION_FILE}"
}

write_report() {
    _mode="$1"
    _commit="${2:-}"
    _backup_dir="${3:-}"

    {
        printf '{\n'
        printf '  "timestamp": "%s",\n' "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
        printf '  "mode": "%s",\n' "$(json_escape "${_mode}")"
        printf '  "commit": "%s",\n' "$(json_escape "${_commit}")"
        printf '  "backupDir": "%s",\n' "$(json_escape "${_backup_dir}")"
        printf '  "migrationFromVersion": %s,\n' "${MIGRATION_FROM}"
        printf '  "migrationToVersion": %s,\n' "${MIGRATION_TO}"
        printf '  "rollbackAvailable": true,\n'

        printf '  "stagedFiles": ['
        first=1
        if [ -f "${STAGED_FILES_FILE}" ]; then
            while IFS= read -r item; do
                [ -n "${item}" ] || continue
                if [ "${first}" -eq 1 ]; then
                    first=0
                else
                    printf ', '
                fi
                printf '"%s"' "$(json_escape "${item}")"
            done < "${STAGED_FILES_FILE}"
        fi
        printf '],\n'

        printf '  "changedUnits": ['
        first=1
        if [ -f "${CHANGED_UNITS_FILE}" ]; then
            while IFS= read -r item; do
                [ -n "${item}" ] || continue
                if [ "${first}" -eq 1 ]; then
                    first=0
                else
                    printf ', '
                fi
                printf '"%s"' "$(json_escape "${item}")"
            done < "${CHANGED_UNITS_FILE}"
        fi
        printf ']\n'

        printf '}\n'
    } > "${REPORT_FILE}"
}

rollback_latest() {
    require_root
    latest_report="${REPORT_FILE}"
    if [ ! -f "${latest_report}" ]; then
        printf 'ERROR: no previous live update report found at %s\n' "${latest_report}" >&2
        exit 1
    fi

    backup_dir="$(grep -E '"backupDir"' "${latest_report}" | sed 's/.*"backupDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    if [ -z "${backup_dir}" ] || [ ! -d "${backup_dir}" ]; then
        printf 'ERROR: backup directory missing for rollback: %s\n' "${backup_dir}" >&2
        exit 1
    fi

    : > "${CHANGED_UNITS_FILE}"
    : > "${STAGED_FILES_FILE}"

    log "rolling back from ${backup_dir}"
    find "${backup_dir}" -type f | while IFS= read -r backup_file; do
        rel="${backup_file#${backup_dir}}"
        dest="${rel}"
        ensure_parent "${dest}"
        cp -a "${backup_file}" "${dest}"

        case "${dest}" in
            /etc/systemd/system/*.service|/etc/systemd/system/*.timer)
                record_changed_unit "$(basename "${dest}")"
                ;;
        esac
    done

    reload_systemd_units
    MIGRATION_FROM="$(current_schema_version)"
    MIGRATION_TO="${MIGRATION_FROM}"
    write_report "rollback" "$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || printf '')" "${backup_dir}"
    log "rollback completed"
}

apply_update() {
    require_root
    mkdir -p "${BACKUP_DIR}"
    : > "${CHANGED_UNITS_FILE}"
    : > "${STAGED_FILES_FILE}"

    log "starting apply from ${REPO_DIR}"

    mkdir -p \
        /etc/dayshield/config \
        /etc/dayshield/certs \
        /etc/dayshield/logs \
        /var/lib/dayshield/aliases \
        /var/lib/dayshield/crowdsec \
        /var/lib/dayshield/acme \
        /etc/cloudflared \
        /var/lib/cloudflared

    run_migrations

    for src in "${CONFIG_DIR}"/services/*.service "${CONFIG_DIR}"/services/*.timer; do
        [ -f "${src}" ] || continue
        unit="$(basename "${src}")"
        dst="/etc/systemd/system/${unit}"
        if [ -f "${dst}" ] && cmp -s "${src}" "${dst}"; then
            continue
        fi
        install_managed_file "${src}" "${dst}" 0644
        record_changed_unit "${unit}"
    done

    install_managed_file "${CONFIG_DIR}/dayshield/console-wizard.sh" "/usr/local/bin/dayshield-console" 0755
    install_managed_file "${CONFIG_DIR}/dayshield/installer-finalize.sh" "/usr/local/lib/dayshield/installer-finalize.sh" 0755
    install_managed_file "${CONFIG_DIR}/dayshield/console-login-profile.sh" "/etc/profile.d/dayshield-console.sh" 0644

    stage_preserving_file "${CONFIG_DIR}/nftables.conf" "/etc/nftables.conf" 0644
    stage_preserving_file "${CONFIG_DIR}/unbound.conf" "/etc/unbound/unbound.conf" 0644
    stage_preserving_file "${CONFIG_DIR}/suricata.yaml" "/etc/suricata/suricata.yaml" 0644
    stage_preserving_file "${CONFIG_DIR}/crowdsec.yaml" "/etc/crowdsec/config.yaml" 0644
    stage_preserving_file "${CONFIG_DIR}/sshd_config" "/etc/ssh/sshd_config" 0644
    stage_preserving_file "${CONFIG_DIR}/sysctl.conf" "/etc/sysctl.d/99-dayshield.conf" 0644

    reload_systemd_units

    if [ "${STAGED_CHANGES}" -gt 0 ]; then
        log "completed with ${STAGED_CHANGES} staged config update(s); merge *.dayshield-new files as needed"
    else
        log "completed with no staged config deltas"
    fi

    commit="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || printf '')"
    write_report "apply" "${commit}" "${BACKUP_DIR}"
    log "backup directory: ${BACKUP_DIR}"
}

main() {
    case "${MODE}" in
        rollback) rollback_latest ;;
        *) apply_update ;;
    esac
}

main "$@"
