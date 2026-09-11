"""The app's control environment cannot also hold a selected credential value."""
import re
import sys

SELECTORS = ('DEVMON_SLACK_WEBHOOK_NAME', 'DEVMON_SLACK_WEBHOOK_ROUTINE_NAME',
             'DEVMON_SMTP_PASSWORD_NAME')
# EnvironmentFile metadata, unit settings, and additional backend controls. These
# names already have a meaning even when a particular feature/lane is disabled.
# Only controls read/emitted by the service are reserved. Installer-only inputs
# are translated before systemd loads the app secret file; they cannot collide
# with generated runtime metadata and are not part of this namespace.
# Credential value names (including legacy names) deliberately are not controls.
CONTROL_NAMES = frozenset(SELECTORS) | frozenset('''
DEV_MONITOR_OWNER DEV_MONITOR_PROXY_SECRET DEV_MONITOR_SPOOL DEV_MONITOR_DB
DEV_MONITOR_CWD_ROOT DEV_MONITOR_EXEC_SESSION DEV_MONITOR_ROSTER
DEV_MONITOR_SMTP_HOST DEV_MONITOR_SMTP_PORT DEV_MONITOR_SMTP_FROM
DEV_MONITOR_SMTP_TO DEV_MONITOR_SMTP_USER DEV_MONITOR_TOKEN_SNAPSHOT
AIRLOCK_DEVMON_CONSOLE_URL AIRLOCK_DEV_MONITOR_BACKEND_PORT
AIRLOCK_DEV_MONITOR_MESSAGES AIRLOCK_IDENTITY_HEADER AIRLOCK_DEV_MONITOR_CORS_ORIGINS
AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS
AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_STALE_HOURS AIRLOCK_DEV_MONITOR_ACCOUNTS_STATUS_BIN
AIRLOCK_AGENT_PROVIDER AIRLOCK_AGENT_BIN AIRLOCK_HARNESS_RUN_DIR
AIRLOCK_UPDATE_RUN_DIR AIRLOCK_UPDATES_STATE AIRLOCK_HARNESS_HOOK_CHECK
CRON_CONSOLE_SUDO CRON_CONSOLE_JOURNALCTL CRON_CONSOLE_DESCRIPTIONS HOME PATH
'''.split())

# Python startup, the ELF loader, and the bash children launched by this app
# consume these before application configuration can protect the process.
# devmon_updates.codex_latest launches npm with the inherited environment;
# Node interprets NODE_OPTIONS before executing that child program.
# systemd also supplies notification/socket-activation/watchdog and invocation
# metadata (systemd.exec: Environment Variables in Spawned Processes).
EXECUTION_NAMES = frozenset('''
BASH_ENV ENV BASHOPTS SHELLOPTS GLIBC_TUNABLES GCONV_PATH NODE_OPTIONS
NOTIFY_SOCKET WATCHDOG_PID WATCHDOG_USEC LISTEN_PID LISTEN_FDS LISTEN_FDNAMES
SYSTEMD_EXEC_PID INVOCATION_ID JOURNAL_STREAM
'''.split())


def validate_names(*names):
    for name in names:
        if name and (not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name)
                     or name in CONTROL_NAMES or name in EXECUTION_NAMES
                     or name.startswith(('PYTHON', 'LD_'))):
            # Never echo configuration/credential bytes in diagnostics.
            raise ValueError('credential name must not be an app control variable or invalid environment name')


def validate_config(env):
    validate_names(*(env.get(key, '').strip() for key in SELECTORS))


if __name__ == '__main__':
    try:
        validate_names(*sys.argv[1:])
    except ValueError as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
