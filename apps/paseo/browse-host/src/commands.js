// SPDX-License-Identifier: Apache-2.0
"use strict";
// Single source of truth for the commands this host implements.
// The capability we advertise MUST equal what the executor can actually run —
// the broker returns browser_unsupported for anything not listed, so we only
// advertise verified commands (task doc §5: staged capability).
const SUPPORTED_COMMANDS = [
  "new_tab",
  "list_tabs",
  "navigate",
  "back",
  "forward",
  "reload",
  "snapshot",
  "screenshot",
  "click",
  "fill",
  "wait",
  "close_tab",
  "logs",
];

module.exports = { SUPPORTED_COMMANDS };
