"""Shared death-verdict marker for the subscription account pool.

The problem this exists to solve: whether an account can still be switched to is decided
by the *server*, but the thing that lists accounts (`airlock-accounts list --json`, which
the account panel renders) only ever looked at local metadata — `refreshTokenExpiresAt`
against the clock. A refreshToken can be revoked long before that date: logged out
elsewhere, rotated on another box, subscription ended, or the box itself was replaced.
Measured 2026-09-01 after a box migration: nine of ten slots reported `health = ok`, and
four of those failed a real switch with HTTP 400 `invalid_grant`. The list had no way to
know, because nothing wrote down what the server had already said out loud.

So: when a refresh attempt is actually rejected (HTTP 400/401 — a verdict, never a
timeout or a 5xx), the tool that observed it records that on the slot, and the list
honours it. No new probing is added anywhere; this only stops throwing away evidence
that was already in hand.

Two properties keep a wrong marker from becoming expensive:

  * It lives inside `_meta`, which every re-login and relabel path replaces wholesale
    (`_store_account`, `cmd_relabel`, `_saveback`). A revived account therefore loses the
    marker structurally, without anyone having to remember to clear it.
  * It carries the `refreshTokenExpiresAt` it was recorded against. If that value has
    moved, the lineage rotated after the verdict, so the marker is stale and ignored.
    This is a backstop, not the primary clear: the server only sends
    `refresh_token_expires_in` on some responses, so the field does not always move.

A false marker is not merely cosmetic — `cmd_prune` treats a dead verdict as input to an
irreversible deletion — which is why the write side is deliberately narrow: an observed
400/401 and nothing else.
"""
import json
import os
import time

DEAD_REASON = ("refresh rejected by the server (HTTP 400/401) — re-login required. "
               "The stored expiry has not passed; the lineage was revoked before it.")


def _oauth(creds):
    return creds.get("claudeAiOauth") or creds


def _rt_expiry(creds):
    value = _oauth(creds).get("refreshTokenExpiresAt")
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def dead_marker(creds):
    """The recorded verdict for this slot, or None.

    None when there is no marker, when it is malformed, or when the lineage has rotated
    since it was written — in that last case the account got a new refreshToken after the
    rejection, so the old verdict says nothing about the current one.
    """
    if not isinstance(creds, dict):
        return None
    meta = creds.get("_meta")
    if not isinstance(meta, dict):
        return None
    marker = meta.get("dead")
    if not isinstance(marker, dict):
        return None
    if marker.get("rtExpiry") != _rt_expiry(creds):
        return None
    return marker


def clear_dead_marker(creds):
    """Drop the marker in place. The caller persists. Safe to call unconditionally."""
    if not isinstance(creds, dict):
        return False
    meta = creds.get("_meta")
    if not isinstance(meta, dict):
        return False
    return meta.pop("dead", None) is not None


def build_marker(creds, reason=DEAD_REASON):
    return {"since": time.time(), "reason": reason, "rtExpiry": _rt_expiry(creds)}


def mark_dead(path, creds, reason=DEAD_REASON):
    """Record the verdict on the slot file. Never raises, never rotates a token.

    Recording is best-effort on purpose: failing a switch or a status read because a note
    could not be written would trade a real answer for a bookkeeping error. Returns True
    only when it actually landed on disk.
    """
    if not isinstance(creds, dict):
        return False
    if dead_marker(creds) is not None:
        # Already recorded for this same lineage. Re-writing would push `since` forward
        # on every status read, so "dead since" would always say "just now" — and it
        # would rewrite a credential file for no reason each time a panel opens.
        return True
    try:
        meta = creds.get("_meta")
        if not isinstance(meta, dict):
            meta = {}
            creds["_meta"] = meta
        meta["dead"] = build_marker(creds, reason)
        tmp = f"{path}.tmp.{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(creds, f)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
        os.replace(tmp, path)
        return True
    except (OSError, ValueError, TypeError):
        return False
