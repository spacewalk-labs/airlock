#!/usr/bin/env python3
"""Measure the messages-on/no-webhook delivery consumer in one disposable database."""

import json
import sys
import urllib.request
import threading


def observation_timing(requested_seconds, elapsed_milliseconds):
    """Normalize the requested window separately from the monotonic measurement."""
    requested = int(requested_seconds)
    elapsed = int(elapsed_milliseconds)
    return {
        "observation_requested_seconds": requested,
        "observation_elapsed_milliseconds": elapsed,
        "observation_seconds": elapsed // 1000,
    }


def _delivery_state(messages, card_id):
    card = messages.get_card(card_id)
    if card is None:
        raise RuntimeError("synthetic delivery card is missing")
    return {
        "send_attempts": card["send_attempts"],
        "pending": card["delivery"] == "pending",
    }


def collect(db_path, backend_dir, health_url, soak_seconds, elapsed_milliseconds):
    """Exercise the deployed loop's no-webhook and stubbed delivery branches.

    The first branch deliberately passes an empty webhook to the same consumer the
    service loop uses.  The second replaces only its HTTP transport with a local
    success stub; it therefore proves the loop's selection and receipt mutation
    without sending an external message from the disposable acceptance guest.
    """
    timing = observation_timing(soak_seconds, elapsed_milliseconds)
    with urllib.request.urlopen(health_url, timeout=6) as response:
        health = json.load(response)
    if health.get("messages") != "on" or health.get("slack") != "not configured":
        raise RuntimeError("effective messages/slack state does not match no-webhook")

    sys.path.insert(0, backend_dir)
    import devmon_loop as loop
    import devmon_messages as messages

    messages._local = threading.local()
    messages.init_db(db_path)
    card_id = "live-no-webhook-delivery-control"
    if messages.ingest({
        "id": card_id,
        "group": card_id,
        "source": "live-collector",
        "level": "urgent",
        "title": "live no-webhook delivery control",
        "body": "synthetic card; the empty webhook must preserve it",
    }) != "inserted":
        raise RuntimeError("synthetic delivery card was not inserted")

    no_webhook_before = _delivery_state(messages, card_id)
    no_webhook_return = loop.deliver_once("")
    no_webhook_after = _delivery_state(messages, card_id)
    if no_webhook_return is not False or no_webhook_before != no_webhook_after:
        raise RuntimeError("empty webhook changed the pending synthetic card")

    original_send = loop.slack.send
    try:
        loop.slack.send = lambda _webhook, _text: (True, 204, None)
        configured_return = loop.deliver_once("collector-stub")
    finally:
        loop.slack.send = original_send
    configured_after = _delivery_state(messages, card_id)
    if configured_return is not True or configured_after != {
        "send_attempts": 1,
        "pending": False,
    }:
        raise RuntimeError("configured stub did not deliver the synthetic card")

    return {
        "messages_effective": health["messages"],
        "slack_effective": health["slack"],
        **timing,
        "no_webhook_control": {
            "returned": no_webhook_return,
            "before": no_webhook_before,
            "after": no_webhook_after,
        },
        "configured_stub_control": {
            "returned": configured_return,
            "before": no_webhook_after,
            "after": configured_after,
        },
    }


def main():
    try:
        observation = collect(*sys.argv[1:6])
    except Exception as exc:  # preserve a safe diagnosis without recording runtime bytes
        print(json.dumps({
            "error": "collector execution failed",
            "error_type": type(exc).__name__,
        }, sort_keys=True))
        return 1
    print(json.dumps(observation, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
