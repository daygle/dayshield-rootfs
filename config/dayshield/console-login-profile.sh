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

# Restrict to local console-style TTYs, not remote SSH pts sessions.
TTY_PATH="$(tty 2>/dev/null || true)"
case "${TTY_PATH}" in
    /dev/tty1|/dev/ttyS0|/dev/console) ;;
    *) return ;;
esac

export DAYSHIELD_CONSOLE_RUNNING=1
export DAYSHIELD_CONSOLE_MODE=login
/usr/local/bin/dayshield-console || true
unset DAYSHIELD_CONSOLE_RUNNING
unset DAYSHIELD_CONSOLE_MODE
