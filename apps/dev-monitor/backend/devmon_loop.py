#!/usr/bin/env python3
"""One message loop: collect, send one due card, and clean up every 15 minutes."""
import sys
import time

import devmon_messages as M
import devmon_slack as slack
import devmon_spool as spool

INTERVAL = 2
CLEANUP_INTERVAL = 15 * 60


def deliver_once(webhook, console_url='', after_post=None):
    card = M.next_delivery() if webhook else None
    if card is None:
        return False
    ok, code, retry_after = slack.send(webhook,slack.format_text(card,console_url))
    if ok and after_post is not None:
        after_post()  # Deterministic process-death oracle: response received, no commit yet.
    M.finish_delivery(card,ok,slack._retry_after_seconds(code,retry_after))
    return True


def tick(directory, webhook, console_url='', cleanup=False, after_post=None):
    collected = spool.scan_once(directory)
    deliver_once(webhook,console_url,after_post)
    if cleanup:
        spool.purge_receipts(directory)
        M.sweep()
    return collected


def run(directory, webhook, stop, console_url=''):
    cleanup_at = time.monotonic()
    while not stop.is_set():
        started = time.monotonic()
        cleanup = started >= cleanup_at
        try:
            tick(directory,webhook,console_url,cleanup)
            if cleanup:
                cleanup_at = started + CLEANUP_INTERVAL
        except Exception as error:
            sys.stderr.write('[messages] loop error: '+type(error).__name__+'\n')
        stop.wait(max(0,INTERVAL-(time.monotonic()-started)))
