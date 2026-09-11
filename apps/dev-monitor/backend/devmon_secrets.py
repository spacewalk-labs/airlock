"""One name/legacy precedence contract for already-loaded process environments."""
from devmon_secret_names import validate_names


def resolve(env, selector, legacy_keys=(), *, marker=None):
    # An omitted or blank selector preserves legacy direct configuration until
    # Phase 4. A real selector is authoritative, even when its target is missing.
    name = (selector or '').strip()
    validate_names(name)
    keys = (name,) if name else legacy_keys
    for key in keys:
        raw = env.get(key, '')
        if marker is not None and raw == marker:
            continue
        # Empty-value validation must not change a valid SMTP password.
        if raw.strip():
            return raw
    return ''


SLACK_CONFIG = {
    'slack-urgent': ('DEVMON_SLACK_WEBHOOK_NAME',
                     ('AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT',)),
}


def slack_webhooks(env):
    return {lane: resolve(env, env.get(key), legacy).strip() for lane, (key, legacy) in SLACK_CONFIG.items()}
