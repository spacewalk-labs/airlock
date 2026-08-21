// SPDX-License-Identifier: MIT
const assert = require("node:assert/strict");
const { isTerminalCloseCode, applyRosterMessage, closeAction } = require("../web/browse-view-client.js");

assert.equal(isTerminalCloseCode(4001), true);
assert.equal(isTerminalCloseCode(1000), false);
assert.equal(isTerminalCloseCode(1006), false);
assert.equal(closeAction(4001, false), "terminal");
assert.equal(closeAction(1006, false), "reconnect");
assert.equal(closeAction(1000, false), "reconnect");
assert.equal(closeAction(4001, true), "none");
assert.equal(closeAction(1006, true), "none");

const first = { browserId: "b1", workspaceId: "wks_one", url: "https://one" };
const second = { browserId: "b2", workspaceId: "wks_two", url: "https://two" };
const tabs = new Map([["old", { browserId: "old" }]]);

applyRosterMessage(tabs, { type: "snapshot", tabs: [first, second] });
assert.deepEqual([...tabs.keys()], ["b1", "b2"]);

const updated = { ...first, url: "https://updated" };
applyRosterMessage(tabs, { type: "upsert", tab: updated });
assert.equal(tabs.get("b1").url, "https://updated");

applyRosterMessage(tabs, { type: "remove", browserId: "b2" });
assert.equal(tabs.has("b2"), false);

applyRosterMessage(tabs, { type: "reset" });
assert.equal(tabs.size, 0);

tabs.set("keep", { browserId: "keep" });
applyRosterMessage(tabs, null);
applyRosterMessage(tabs, "invalid");
applyRosterMessage(tabs, { type: "unknown" });
assert.equal(tabs.size, 1);

console.log("companion unit OK");
