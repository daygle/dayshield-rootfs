#!/bin/sh
set -eu

action="${1:-status}"
remote="${DAYSHIELD_OSTREE_REMOTE:-dayshield}"

case "${action}" in
    status)
        exec ostree admin status
        ;;
    check)
        exec ostree remote refs "${remote}"
        ;;
    stage|apply)
        exec ostree admin upgrade --os=dayshield --stage
        ;;
    rollback)
        exec ostree admin rollback --os=dayshield
        ;;
    *)
        printf 'Usage: DAYSHIELD_OSTREE_REMOTE=<remote> %s [status|check|stage|apply|rollback]\n' "$0" >&2
        exit 1
        ;;
esac
