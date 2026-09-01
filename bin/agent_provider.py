"""Which agent CLI does a platform tool run — decided in exactly one place.

Two things on this box want the same answer and used to answer it separately.
The learning app picked between `claude` and `codex` with its own rule; the
dev-monitor action runner did not pick at all, because `claude` was written
into its argv. A box with only codex logged in therefore had one app that
worked and one that died with rc=127, and nothing said the two were related.

The rule this module owns is the selection, and only the selection:

  · a pinned preference (`claude` / `codex`) is honoured or fails loudly
  · `auto` prefers a CLI with a credential trace over one merely installed
  · an unrecognised value is NEVER quietly read as `auto`

What it deliberately does NOT own is `build_argv`. How you spell "run this
prompt headlessly" differs per caller, not just per CLI: learning's ingest
needs a workspace-write sandbox with network access because its library is
deliberately not a git repository, and the action runner needs the owner's
own settings and a turn-end hook. Folding those into one function would give
each caller a flag to switch the other one off.

Discovery and the credential trace are injected as one `probe` callable
rather than imported, for two reasons. The platform resolves binaries with
`bin_discovery` (a systemd unit's PATH finds almost nothing), while learning
resolves them against an install-time PATH plus its own per-provider override
variables — same decision, different evidence. And keeping this file free of
imports beyond the standard library is what lets it be vendored verbatim into
a package that does not live inside the platform tree.

The vendored copy is `apps/learning/backend/agent_provider.py`, byte-identical
and pinned by `install/test-agent-provider.sh`.
"""

from collections import namedtuple

AUTO = "auto"

Provider = namedtuple("Provider", "id label command")

# Declaration order IS the `auto` tie-break: with a credential trace on both,
# the first one listed wins. Recorded as a decision, not an accident — see
# `docs/design/agent-default.md` §4 (board decision AUTO_TIEBREAK).
PROVIDERS = (
    Provider("claude", "Claude Code", "claude"),
    Provider("codex", "Codex CLI", "codex"),
)

IDS = tuple(p.id for p in PROVIDERS)
CHOICES = (AUTO,) + IDS

# (provider|None, binary|None, human-readable reason). The reason is never empty:
# a caller that cannot run anything has to be able to say why.
Selection = namedtuple("Selection", "provider binary reason")

# Kept verbatim from apps/learning/backend/providers.py, which shows these to a
# person in the learning UI. Moving the logic must not reword the output.
_UNKNOWN_NOTE = " (설정의 provider 값 {value!r} 을 모릅니다 — auto 로 봤습니다)"
_PINNED_OK = "{label} (설정에서 고정){note}"
_PINNED_MISSING = ("{label}({command})를 찾지 못했습니다 — 설정이 이 제공자로 고정되어 "
                   "있습니다. 설치하거나 provider 를 auto 로 되돌리십시오{note}")
_AUTO_CREDENTIALED = "{label} (로그인 흔적 있음){note}"
_AUTO_NO_TRACE = ("{label} (설치되어 있지만 로그인 흔적을 찾지 못했습니다 — "
                  "그래도 실행합니다){note}")
_NOTHING_FOUND = ("에이전트 CLI 를 찾지 못했습니다 — {names} 중 하나가 설치되어 "
                  "있어야 합니다{note}")


def by_id(provider_id):
    for provider in PROVIDERS:
        if provider.id == provider_id:
            return provider
    return None


def normalize(preference):
    """(value, note). An unrecognised value degrades to `auto` **and says so**.

    Silently rewriting it would mean one typo in airlock.toml runs a different
    CLI than the file reads as, with nothing in any log to notice it by.
    """
    requested = str(preference or AUTO).strip().lower()
    if requested in CHOICES:
        return requested, ""
    return AUTO, _UNKNOWN_NOTE.format(value=requested)


def select(preference, probe, nothing_found=None):
    """Selection(provider, binary, reason). Nothing runnable -> (None, None, why).

    probe(provider) -> (binary_or_None, credential_trace_bool). It is one call
    rather than two so a caller whose trace costs a subprocess pays once per
    provider, and so "installed" and "logged in" cannot be measured against
    different moments.

    `nothing_found` overrides the last-resort message for a caller that can say
    something more useful about what the person just lost.
    """
    preference, note = normalize(preference)

    if preference != AUTO:
        provider = by_id(preference)
        binary, _trace = probe(provider)
        if binary:
            return Selection(provider, binary,
                             _PINNED_OK.format(label=provider.label, note=note))
        return Selection(None, None, _PINNED_MISSING.format(
            label=provider.label, command=provider.command, note=note))

    found = [(provider,) + tuple(probe(provider)) for provider in PROVIDERS]
    found = [entry for entry in found if entry[1]]
    for provider, binary, trace in found:
        if trace:
            return Selection(provider, binary, _AUTO_CREDENTIALED.format(
                label=provider.label, note=note))
    if found:
        # Installed but no trace: still run it. The trace is a hint about where a
        # login file sits, and a hint that is wrong must not be able to refuse a
        # CLI that would have worked.
        provider, binary, _trace = found[0]
        return Selection(provider, binary, _AUTO_NO_TRACE.format(
            label=provider.label, note=note))
    names = ", ".join(p.command for p in PROVIDERS)
    reason = nothing_found or _NOTHING_FOUND
    return Selection(None, None, reason.format(names=names, note=note))
