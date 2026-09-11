#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
"use strict";
// Entry point for the Paseo server-side browse host sidecar.
const { BrowseHost } = require("../src/host.js");
new BrowseHost().start();
