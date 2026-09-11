#!/usr/bin/env python3
"""Publish the daily heartbeat through the same spool contract as other producers."""
import argparse
from datetime import datetime, timezone

from examples.emit_message import emit
from backend.devmon_heartbeat import heartbeat_payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--spool', required=True)
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    result = emit(args.spool, heartbeat_payload(now))
    print('heartbeat: ' + result)


if __name__ == '__main__':
    main()
