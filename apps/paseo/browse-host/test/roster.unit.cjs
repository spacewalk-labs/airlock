// SPDX-License-Identifier: MIT
"use strict";

const { BrowserHostExecutor, HostError } = require("../src/executor.js");
const security = require("../src/security.js");

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const policy = {
  assertUrlAllowed: async (url) => (String(url).startsWith("data:") ? new URL(url) : security.assertUrlAllowed(url)),
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

function loadChromium() {
  for (const c of ["playwright", process.env.PASEO_PLAYWRIGHT_PATH]) {
    try { return require(c).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

const pageUrl = (title) => `data:text/html,${encodeURIComponent(`<!doctype html><title>${title}</title><h1>${title}</h1>`)}`;

let passed = 0, failed = 0;
function check(name, condition, detail) {
  if (condition) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? ` :: ${detail}` : ""}`); }
}

(async () => {
  let orphanClosed = false;
  const failureExecutor = new BrowserHostExecutor({ urlPolicy: policy });
  failureExecutor._openPage = async () => ({
    browserId: "failed-new-tab",
    page: {
      goto: async () => { throw new Error("navigation failed"); },
      close: async () => { orphanClosed = true; },
    },
  });
  let navigationError;
  try { await failureExecutor.cmdNewTab({ url: pageUrl("Failure") }, "failure-new-tab-ws"); }
  catch (error) { navigationError = error; }
  check("failed new_tab closes orphan page", orphanClosed && navigationError instanceof HostError && navigationError.code === "browser_unknown_error");

  const chromium = loadChromium();
  const events = [];
  const executor = new BrowserHostExecutor({
    launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
    urlPolicy: policy,
  });
  executor.rosterSink = (event) => events.push(event);

  const newTab = await executor.execute({
    requestId: "new-agent",
    workspaceId: "agent-ws",
    command: { command: "new_tab", args: {} },
  });
  const agentId = newTab.result.browserId;
  check("new_tab succeeds", newTab.ok, JSON.stringify(newTab.error));
  check("new_tab emits one agent open", events.filter((e) => e.kind === "open" && e.browserId === agentId && e.origin === "agent").length === 1);

  const viewerId = "viewer-roster-unit";
  await executor.ensureTab(viewerId, "viewer-ws");
  check("ensureTab emits viewer open", events.some((e) => e.kind === "open" && e.browserId === viewerId && e.origin === "viewer"));
  check("rosterSnapshot returns agent tabs only", executor.rosterSnapshot().length === 1 && executor.rosterSnapshot()[0].browserId === agentId);
  check("crash listener is registered", executor.getTab(agentId).page.listenerCount("crash") > 0);

  const crashTab = await executor.cmdNewTab({ url: pageUrl("Crash") }, "crash-ws");
  const crashCloseBefore = events.filter((e) => e.kind === "close" && e.browserId === crashTab.browserId).length;
  const crashPage = executor.getTab(crashTab.browserId).page;
  crashPage.emit("close");
  crashPage.emit("close");
  check("duplicate close finalizes once", events.filter((e) => e.kind === "close" && e.browserId === crashTab.browserId).length === crashCloseBefore + 1);

  const lateTab = await executor.cmdNewTab({ url: pageUrl("Late") }, "late-ws");
  const lateRecord = executor.getTab(lateTab.browserId);
  const navBefore = events.filter((e) => e.kind === "nav" && e.browserId === lateTab.browserId).length;
  lateRecord.closed = true;
  executor._scheduleNavEmit(lateRecord, lateRecord.navGen, pageUrl("Zombie"));
  await wait(350);
  check("late nav does not resurrect closed tab", events.filter((e) => e.kind === "nav" && e.browserId === lateTab.browserId).length === navBefore);
  await lateRecord.page.close();

  const navUrl = pageUrl("Navigated");
  const navigate = await executor.execute({
    requestId: "navigate-agent",
    workspaceId: "agent-ws",
    command: { command: "navigate", args: { browserId: agentId, url: navUrl } },
  });
  await wait(450);
  const nav = events.find((e) => e.kind === "nav" && e.browserId === agentId);
  check("navigate succeeds", navigate.ok, JSON.stringify(navigate.error));
  check("navigate emits url delta", !!nav && nav.url === navUrl && nav.origin === "agent");
  check("navigate emits title delta", !!nav && nav.title === "Navigated");

  const closeEventsBefore = events.filter((e) => e.kind === "close" && e.browserId === agentId).length;
  const close = await executor.execute({
    requestId: "close-agent",
    workspaceId: "agent-ws",
    command: { command: "close_tab", args: { browserId: agentId } },
  });
  check("close_tab succeeds", close.ok, JSON.stringify(close.error));
  check("close event removes tab", !executor.getTab(agentId));
  check("close event is emitted by page close", events.filter((e) => e.kind === "close" && e.browserId === agentId).length === closeEventsBefore + 1);

  const throwingExecutor = new BrowserHostExecutor({ launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }), urlPolicy: policy });
  const sinkLogs = [];
  throwingExecutor.log = (message) => sinkLogs.push(message);
  throwingExecutor.rosterSink = () => { throw new Error("sink failure"); };
  const throwingNewTab = await throwingExecutor.execute({ requestId: "throwing-sink", workspaceId: "throw-ws", command: { command: "new_tab", args: {} } });
  check("throwing sink does not fail executor command", throwingNewTab.ok, JSON.stringify(throwingNewTab.error));
  check("throwing sink is logged", sinkLogs.some((message) => /roster sink error: sink failure/.test(message)));
  await throwingExecutor.shutdown();

  const failingTab = await executor.ensureTab("close-failure", "failure-ws");
  const originalClose = failingTab.page.close;
  failingTab.page.close = async () => { throw new Error("page close failed"); };
  let closeError;
  try { await executor.cmdCloseTab(failingTab); } catch (error) { closeError = error; }
  failingTab.page.close = originalClose;
  check("close failure is HostError", closeError instanceof HostError && closeError.code === "browser_unknown_error");
  check("close failure preserves tab", executor.getTab("close-failure") === failingTab);
  await failingTab.page.close();

  await executor.ensureTab("reset-agent", "reset-ws");
  const resetPromise = new Promise((resolve) => {
    const timer = setInterval(() => {
      const reset = events.find((e) => e.kind === "reset" && e.reason === "chromium_disconnected");
      if (reset) { clearInterval(timer); resolve(reset); }
    }, 20);
  });
  await executor.browser.close();
  await resetPromise;
  check("chromium disconnect emits reset", events.some((e) => e.kind === "reset" && e.reason === "chromium_disconnected"));

  await executor.shutdown();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((error) => { console.error("FATAL", error); process.exit(2); });
