#!/usr/bin/env node
// SPDX-License-Identifier: MIT
"use strict";
// Entry point for the Paseo server-side browse host sidecar.
const { BrowseHost } = require("../src/host.js");
new BrowseHost().start();
