#!/usr/bin/env bash
# fileview deactivate — no app-specific stop step. The ledger's generic
# "units" class stops/disables/deletes both airlock-markserv.service and
# airlock-fileview.service; "fragments"/"webroot"/"files" remove the
# nginx fragment, the __fv/ static assets, and the markserv/filebrowser
# binaries + npm tree + branding dir. CODE_ROOT (the served tree) and
# ~/.config/filebrowser/fb.db are retained data — never declared, so never
# touched. Idempotent by construction (does nothing).
set -euo pipefail
exit 0
