# dayshield console menu launcher for interactive root console logins.
# Sourced from /etc/profile.d by login shells.

# Only interactive shells should trigger the menu.
case "$-" in
    *i*) ;;
    *) return ;;
esac

# Suppression flag is used when the boot-time wizard intentionally opens a shell.
if [ "${DAYSHIELD_CONSOLE_SUPPRESS:-0}" = "1" ]; then
    return
fi

# Only root gets the post-login menu.
if [ "$(id -u)" -ne 0 ]; then
    return
fi

# Avoid recursive invocation.
if [ -n "${DAYSHIELD_CONSOLE_RUNNING:-}" ]; then
    return
fi

# Installer/live session already has boot-time wizard service.
if grep -qw installer /proc/cmdline 2>/dev/null; then
    return
fi

# For SSH sessions, skip the menu when a command was passed directly
# (e.g. scp, rsync, git) — only show for interactive login shells.
if [ -n "${SSH_CONNECTION:-}" ] && [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    return
fi

# Allow remote interactive SSH sessions even when tty(1) output is unavailable.
if [ -n "${SSH_CONNECTION:-}" ]; then
    if [ -n "${SSH_TTY:-}" ]; then
        TTY_PATH="${SSH_TTY}"
    else
        TTY_PATH="$(tty 2>/dev/null || true)"
    fi
else
    # Local login/session: require a real console/pts tty.
    TTY_PATH="$(tty 2>/dev/null || true)"
    case "${TTY_PATH}" in
        /dev/tty[0-9]*|/dev/ttyS*|/dev/console|/dev/pts/*) ;;
        *) return ;;
    esac
fi

if [ -z "${SSH_CONNECTION:-}" ]; then
    # Local console sessions should not stay authenticated indefinitely.
    # DAYSHIELD_CONSOLE_IDLE_TIMEOUT=0 disables the menu/shell idle logout.
    DAYSHIELD_CONSOLE_IDLE_TIMEOUT="${DAYSHIELD_CONSOLE_IDLE_TIMEOUT:-600}"
    case "${DAYSHIELD_CONSOLE_IDLE_TIMEOUT}" in
        ''|*[!0-9]*|0)
            unset DAYSHIELD_CONSOLE_IDLE_TIMEOUT
            ;;
        *)
            export DAYSHIELD_CONSOLE_IDLE_TIMEOUT
            TMOUT="${DAYSHIELD_CONSOLE_IDLE_TIMEOUT}"
            export TMOUT
            ;;
    esac
fi

MENU_CMD=""
if [ -x /usr/local/bin/dayshield-console ]; then
    MENU_CMD="/usr/local/bin/dayshield-console"
elif [ -x /usr/local/lib/dayshield/console-wizard.sh ]; then
    MENU_CMD="/usr/local/lib/dayshield/console-wizard.sh"
else
    return
fi

export DAYSHIELD_CONSOLE_RUNNING=1
export DAYSHIELD_CONSOLE_MODE=login
trap 'unset DAYSHIELD_CONSOLE_RUNNING DAYSHIELD_CONSOLE_MODE' EXIT INT TERM HUP
"${MENU_CMD}"; _DAYSHIELD_RC=$?
trap - EXIT INT TERM HUP
unset DAYSHIELD_CONSOLE_RUNNING DAYSHIELD_CONSOLE_MODE
# Exit code 2 = user chose "Logout" from the menu → close the login session.
if [ "${_DAYSHIELD_RC:-0}" -eq 2 ] 2>/dev/null; then
    unset _DAYSHIELD_RC
    exit
fi
unset _DAYSHIELD_RC
