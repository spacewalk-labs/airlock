#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
"use strict";
// Entry point for the Paseo server-side browse host sidecar.
const { BrowseHost } = require("../src/host.js");
new BrowseHost().start();
