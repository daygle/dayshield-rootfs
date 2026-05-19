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

# Allow local console TTYs and remote SSH (pts) sessions.
# Exclude non-interactive contexts (e.g. scp, sftp, rsync).
TTY_PATH="$(tty 2>/dev/null || true)"
case "${TTY_PATH}" in
    /dev/tty[0-9]*|/dev/ttyS*|/dev/console|/dev/pts/*) ;;
    *) return ;;
esac

# For SSH sessions, skip the menu when a command was passed directly
# (e.g. scp, rsync, git) — only show for interactive login shells.
if [ -n "${SSH_CONNECTION:-}" ] && [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    return
fi

export DAYSHIELD_CONSOLE_RUNNING=1
export DAYSHIELD_CONSOLE_MODE=login
trap 'unset DAYSHIELD_CONSOLE_RUNNING DAYSHIELD_CONSOLE_MODE' EXIT INT TERM HUP
/usr/local/bin/dayshield-console || true
trap - EXIT INT TERM HUP
unset DAYSHIELD_CONSOLE_RUNNING DAYSHIELD_CONSOLE_MODE
