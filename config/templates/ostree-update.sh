#!/bin/sh
# ostree-update.sh — DayShield system image update helper
#
# Fetches rootfs OSTree repo artifacts from GitHub Releases and applies them
# via 'ostree pull-local', avoiding the need for a hosted OSTree HTTP server.
#
# Actions: status | check | stage | apply | rollback
#
# Environment (all optional):
#   DAYSHIELD_GITHUB_REPO   GitHub repo for rootfs releases  (default: daygle/dayshield-rootfs)
#   DAYSHIELD_OSTREE_OS     OSTree OS name                   (default: dayshield)
#   DAYSHIELD_OSTREE_REF    OSTree ref to pull               (default: dayshield/<arch>)

set -eu

GITHUB_REPO="${DAYSHIELD_GITHUB_REPO:-daygle/dayshield-rootfs}"
OSTREE_OS="${DAYSHIELD_OSTREE_OS:-dayshield}"
BUILD_MANIFEST="/usr/local/share/dayshield-updates/ostree-build-manifest.json"

# Derive architecture for the default OSTree ref
_arch="$(uname -m)"
case "${_arch}" in
    x86_64)  _arch="amd64" ;;
    aarch64) _arch="arm64" ;;
    armv7l)  _arch="armhf" ;;
esac
OSTREE_REF="${DAYSHIELD_OSTREE_REF:-dayshield/${_arch}}"

action="${1:-status}"

# ── Helpers ──────────────────────────────────────────────────────────────────

_curl_github_api() {
    curl -sf \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$1"
}

# Extract a simple string field from JSON ("field": "value")
_json_str() {
    printf '%s' "$1" \
        | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# Version recorded in the build manifest embedded in this rootfs image
_installed_version() {
    if [ -f "${BUILD_MANIFEST}" ]; then
        _json_str "$(cat "${BUILD_MANIFEST}")" "version"
    fi
}

# True if at least one OSTree deployment exists
_has_deployments() {
    case "$(ostree admin status 2>/dev/null)" in
        "No deployments."*|"") return 1 ;;
        *) return 0 ;;
    esac
}

# Cleanup temp dir on exit
_WORK_DIR=""
_cleanup() { [ -z "${_WORK_DIR}" ] || rm -rf "${_WORK_DIR}"; }
trap _cleanup EXIT INT TERM

# ── Actions ──────────────────────────────────────────────────────────────────

case "${action}" in

    status)
        exec ostree admin status
        ;;

    check)
        installed="$(_installed_version)"
        printf 'Installed version : %s\n' "${installed:-unknown}"

        release_json="$(_curl_github_api \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")"
        latest_tag="$(_json_str "${release_json}" "tag_name")"

        if [ -z "${latest_tag}" ]; then
            printf 'ERROR: could not resolve latest release from %s\n' "${GITHUB_REPO}" >&2
            exit 1
        fi

        printf 'Latest available  : %s\n' "${latest_tag}"

        if [ -n "${installed}" ] && [ "${installed}" = "${latest_tag}" ]; then
            printf 'System image is up to date.\n'
        else
            printf 'System image update available: %s -> %s\n' \
                "${installed:-unknown}" "${latest_tag}"
        fi
        ;;

    stage|apply)
        # Resolve latest release
        release_json="$(_curl_github_api \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")"
        latest_tag="$(_json_str "${release_json}" "tag_name")"

        if [ -z "${latest_tag}" ]; then
            printf 'ERROR: could not resolve latest release from %s\n' "${GITHUB_REPO}" >&2
            exit 1
        fi

        artifact="rootfs-${latest_tag}-ostree-repo.tar.zst"
        base_url="https://github.com/${GITHUB_REPO}/releases/download/${latest_tag}"

        # Work directory (persistent storage preferred over tmpfs for 300+ MB download)
        mkdir -p /var/lib/dayshield-updates 2>/dev/null || true
        _WORK_DIR="$(mktemp -d /var/lib/dayshield-updates/ostree-update.XXXXXX \
                        2>/dev/null \
                    || mktemp -d)"
        artifact_path="${_WORK_DIR}/${artifact}"
        extract_dir="${_WORK_DIR}/src"

        printf 'Downloading %s ...\n' "${artifact}"
        curl -fL -o "${artifact_path}" "${base_url}/${artifact}"
        printf 'Download complete.\n'

        # Verify SHA256 (best-effort; skip if checksum asset is absent)
        if curl -fL -o "${artifact_path}.sha256" \
                "${base_url}/${artifact}.sha256" 2>/dev/null; then
            expected="$(awk '{print $1}' "${artifact_path}.sha256")"
            actual="$(sha256sum "${artifact_path}" | awk '{print $1}')"
            if [ "${expected}" != "${actual}" ]; then
                printf 'ERROR: SHA256 mismatch for %s\n' "${artifact}" >&2
                printf '  expected : %s\n' "${expected}" >&2
                printf '  actual   : %s\n' "${actual}" >&2
                exit 1
            fi
            printf 'SHA256 verified: %s\n' "${expected}"
        else
            printf 'WARNING: checksum file unavailable; skipping verification.\n'
        fi

        # Extract the archive-z2 OSTree repo
        printf 'Extracting OSTree repo ...\n'
        mkdir -p "${extract_dir}"
        tar -I 'zstd -d' -xf "${artifact_path}" -C "${extract_dir}"
        printf 'Extraction complete.\n'

        # Pull the ref into the local /ostree/repo (bare)
        printf 'Pulling %s into /ostree/repo ...\n' "${OSTREE_REF}"
        ostree pull-local --repo=/ostree/repo "${extract_dir}" "${OSTREE_REF}"
        printf 'Pull complete.\n'

        # Stage the deployment (initial deploy or upgrade)
        if _has_deployments; then
            printf 'Staging upgrade for %s ...\n' "${OSTREE_OS}"
            ostree admin deploy \
                --os="${OSTREE_OS}" \
                --retain-rollback \
                "${OSTREE_REF}"
        else
            printf 'Creating initial deployment for %s ...\n' "${OSTREE_OS}"
            ostree admin deploy \
                --os="${OSTREE_OS}" \
                --karg-proc \
                "${OSTREE_REF}"
        fi
        printf 'Deployment staged. Reboot to activate the new image.\n'
        ;;

    rollback)
        exec ostree admin rollback --os="${OSTREE_OS}"
        ;;

    *)
        printf 'Usage: %s [status|check|stage|apply|rollback]\n' "$0" >&2
        exit 1
        ;;
esac

# Extract a simple string field from JSON ("field": "value")
_json_str() {
    printf '%s' "$1" \
        | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

# Version recorded in the build manifest embedded in this rootfs image
_installed_version() {
    if [ -f "${BUILD_MANIFEST}" ]; then
        _json_str "$(cat "${BUILD_MANIFEST}")" "version"
    fi
}

# True if at least one OSTree deployment exists
_has_deployments() {
    case "$(ostree admin status 2>/dev/null)" in
        "No deployments."*|"") return 1 ;;
        *) return 0 ;;
    esac
}

# Cleanup temp dir on exit
_WORK_DIR=""
_cleanup() { [ -z "${_WORK_DIR}" ] || rm -rf "${_WORK_DIR}"; }
trap _cleanup EXIT INT TERM

# ── Actions ──────────────────────────────────────────────────────────────────

case "${action}" in

    status)
        exec ostree admin status
        ;;

    check)
        installed="$(_installed_version)"
        printf 'Installed version : %s\n' "${installed:-unknown}"

        release_json="$(_curl_github_api \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")"
        latest_tag="$(_json_str "${release_json}" "tag_name")"

        if [ -z "${latest_tag}" ]; then
            printf 'ERROR: could not resolve latest release from %s\n' "${GITHUB_REPO}" >&2
            exit 1
        fi

        printf 'Latest available  : %s\n' "${latest_tag}"

        if [ -n "${installed}" ] && [ "${installed}" = "${latest_tag}" ]; then
            printf 'System image is up to date.\n'
        else
            printf 'System image update available: %s -> %s\n' \
                "${installed:-unknown}" "${latest_tag}"
        fi
        ;;

    stage|apply)
        # Resolve latest release
        release_json="$(_curl_github_api \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")"
        latest_tag="$(_json_str "${release_json}" "tag_name")"

        if [ -z "${latest_tag}" ]; then
            printf 'ERROR: could not resolve latest release from %s\n' "${GITHUB_REPO}" >&2
            exit 1
        fi

        artifact="rootfs-${latest_tag}-ostree-repo.tar.zst"
        base_url="https://github.com/${GITHUB_REPO}/releases/download/${latest_tag}"

        # Work directory (persistent storage preferred over tmpfs)
        mkdir -p /var/lib/dayshield-updates 2>/dev/null || true
        _WORK_DIR="$(mktemp -d /var/lib/dayshield-updates/ostree-update.XXXXXX \
                        2>/dev/null \
                    || mktemp -d)"
        artifact_path="${_WORK_DIR}/${artifact}"
        extract_dir="${_WORK_DIR}/src"

        printf 'Downloading %s ...\n' "${artifact}"
        _curl_download "${base_url}/${artifact}" "${artifact_path}"
        printf 'Download complete.\n'

        # Verify SHA256 (best-effort; skip if checksum asset is absent)
        if _curl_download "${base_url}/${artifact}.sha256" \
                          "${artifact_path}.sha256" 2>/dev/null; then
            expected="$(awk '{print $1}' "${artifact_path}.sha256")"
            actual="$(sha256sum "${artifact_path}" | awk '{print $1}')"
            if [ "${expected}" != "${actual}" ]; then
                printf 'ERROR: SHA256 mismatch for %s\n' "${artifact}" >&2
                printf '  expected : %s\n' "${expected}" >&2
                printf '  actual   : %s\n' "${actual}" >&2
                exit 1
            fi
            printf 'SHA256 verified: %s\n' "${expected}"
        else
            printf 'WARNING: checksum file unavailable; skipping verification.\n'
        fi

        # Extract the archive-z2 OSTree repo
        printf 'Extracting OSTree repo ...\n'
        mkdir -p "${extract_dir}"
        tar -I 'zstd -d' -xf "${artifact_path}" -C "${extract_dir}"
        printf 'Extraction complete.\n'

        # Pull the ref into the local /ostree/repo (bare)
        printf 'Pulling %s into /ostree/repo ...\n' "${OSTREE_REF}"
        ostree pull-local --repo=/ostree/repo "${extract_dir}" "${OSTREE_REF}"
        printf 'Pull complete.\n'

        # Stage the deployment (initial deploy or upgrade)
        if _has_deployments; then
            printf 'Staging upgrade for %s ...\n' "${OSTREE_OS}"
            ostree admin deploy \
                --os="${OSTREE_OS}" \
                --retain-rollback \
                "${OSTREE_REF}"
        else
            printf 'Creating initial deployment for %s ...\n' "${OSTREE_OS}"
            ostree admin deploy \
                --os="${OSTREE_OS}" \
                --karg-proc \
                "${OSTREE_REF}"
        fi
        printf 'Deployment staged. Reboot to activate the new image.\n'
        ;;

    rollback)
        exec ostree admin rollback --os="${OSTREE_OS}"
        ;;

    *)
        printf 'Usage: %s [status|check|stage|apply|rollback]\n' "$0" >&2
        exit 1
        ;;
esac
