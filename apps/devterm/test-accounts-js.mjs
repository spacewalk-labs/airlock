#!/usr/bin/env node
/* Dependency-free contract checks for the Codex and OpenCode xAI sections. */
import fs from 'node:fs';
import vm from 'node:vm';

// accounts.js is a platform asset (ACCT_OWN, 2026-09-01); this test stays here
// because the other half of what it pins down is devterm's own app.js.
const source = fs.readFileSync(
  new URL('../../hub/assets/accounts/accounts.js', import.meta.url), 'utf8');
const appSource = fs.readFileSync(new URL('./web/app.js', import.meta.url), 'utf8');
const failures = [];

function check(name, condition) {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}`);
  if (!condition) failures.push(name);
}

function makeElement(tagName) {
  const element = {
    tagName: tagName.toUpperCase(),
    className: '',
    classList: {
      add(name) {
        const names = new Set(element.className.split(/\s+/).filter(Boolean));
        names.add(name);
        element.className = [...names].join(' ');
      },
      toggle(name, force) {
        const names = new Set(element.className.split(/\s+/).filter(Boolean));
        if (force) names.add(name); else names.delete(name);
        element.className = [...names].join(' ');
      },
    },
    children: [],
    parentNode: null,
    style: {},
    disabled: false,
    offsetWidth: 0,
    offsetHeight: 0,
    _text: '',
    _listeners: new Map(),
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child);
      this.children.push(child);
      child.parentNode = this;
      this._text = '';
      return child;
    },
    removeChild(child) {
      const index = this.children.indexOf(child);
      if (index >= 0) {
        this.children.splice(index, 1);
        child.parentNode = null;
      }
      return child;
    },
    remove() {
      if (this.parentNode) this.parentNode.removeChild(this);
    },
    contains(node) {
      if (node === this) return true;
      return this.children.some((child) => child.contains(node));
    },
    addEventListener(type, listener) {
      const listeners = this._listeners.get(type) || [];
      listeners.push(listener);
      this._listeners.set(type, listeners);
    },
    dispatchEvent(event) {
      for (const listener of this._listeners.get(event.type) || []) listener(event);
    },
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    },
    querySelectorAll(selector) {
      const matches = [];
      const visit = (node) => {
        for (const child of node.children) {
          if (selector.startsWith('.') && child.className.split(/\s+/).includes(selector.slice(1))) {
            matches.push(child);
          } else if (!selector.startsWith('.') && child.tagName === selector.toUpperCase()) {
            matches.push(child);
          }
          visit(child);
        }
      };
      visit(this);
      return matches;
    },
    getBoundingClientRect() {
      return { left: 0, right: 0, top: 0, bottom: 0 };
    },
  };
  Object.defineProperty(element, 'textContent', {
    get() {
      return element.children.length
        ? element.children.map((child) => child.textContent).join('')
        : element._text;
    },
    set(value) {
      element.children.forEach((child) => { child.parentNode = null; });
      element.children = [];
      element._text = String(value);
    },
  });
  return element;
}

function jsonResponse(value) {
  return { json: () => Promise.resolve(value) };
}

function makeHarness({ statuses, usage, xaiStatuses = [{ enabled: false }],
                       postResponses = {}, accountPayload = null }) {
  const document = {
    body: makeElement('body'),
    createElement: (tagName) => makeElement(tagName),
    querySelectorAll: () => [],
  };
  const timers = [];
  const fetchCalls = [];
  const postCalls = [];
  const flashes = [];
  const accounts = accountPayload || {
    enabled: true,
    thresholds: { warn5: 78, crit5: 88, warn7: 88, crit7: 93, rtWarnDays: 5 },
    accounts: [{ active: true, email: 'claude@example.com', kind: 'personal', sub: 'Claude' }],
  };
  let statusIndex = 0;
  let usageIndex = 0;
  let xaiIndex = 0;
  let deferredReject = null;
  const deferredPosts = new Map();

  const window = {
    document,
    console,
    innerWidth: 1000,
    innerHeight: 800,
    visualViewport: null,
    confirm: () => true,
  };

  function fetch(url, options = {}) {
    fetchCalls.push({ url, options });
    if (url === '/accounts') return Promise.resolve(jsonResponse(accounts));
    if (url === '/claude-status') {
      const value = statuses[Math.min(statusIndex++, statuses.length - 1)];
      return Promise.resolve(jsonResponse({ codex: value }));
    }
    if (url === '/codex-usage') {
      const value = usage[Math.min(usageIndex++, usage.length - 1)];
      if (value && value.deferred) {
        return new Promise((_resolve, reject) => { deferredReject = reject; });
      }
      if (value && value.reject) return Promise.reject(new Error(value.reject));
      return Promise.resolve(jsonResponse(value));
    }
    if (url === '/xai-status') {
      const value = xaiStatuses[Math.min(xaiIndex++, xaiStatuses.length - 1)];
      return Promise.resolve(jsonResponse(value));
    }
    return Promise.reject(new Error(`unexpected fetch: ${url}`));
  }

  const context = {
    window,
    document,
    console,
    fetch,
    Promise,
    Date,
    setTimeout(callback, delay) {
      timers.push({ callback, delay });
      return timers.length;
    },
    clearTimeout() {},
    setInterval() { return 1; },
    clearInterval() {},
    navigator: { clipboard: null },
  };
  window.window = window;
  window.setTimeout = context.setTimeout;
  window.clearTimeout = context.clearTimeout;

  vm.runInNewContext(source, context, { filename: 'accounts.js' });
  const api = window.initAccounts({
    flash: (message) => flashes.push(message),
    postJson: (url, body) => {
      postCalls.push({ url, body });
      const response = postResponses[url] || {};
      if (response.deferred) {
        return new Promise((resolve) => { deferredPosts.set(url, resolve); });
      }
      return Promise.resolve(response);
    },
    mkFocus() {},
    closeTabPops() {},
    placePop() {},
  });

  async function flush() {
    for (let i = 0; i < 12; i += 1) await Promise.resolve();
  }

  async function runNextTimer() {
    const timer = timers.shift();
    if (!timer) throw new Error('expected a scheduled timer');
    timer.callback();
    await flush();
    return timer;
  }

  function mountPanel() {
    const container = document.createElement('div');
    document.body.appendChild(container);
    api.renderAcctPanel(container);
    return container;
  }

  return {
    document,
    timers,
    fetchCalls,
    postCalls,
    flashes,
    mountPanel,
    flush,
    runNextTimer,
    rejectDeferred(error) {
      if (!deferredReject) throw new Error('no deferred request');
      const reject = deferredReject;
      deferredReject = null;
      reject(error);
    },
    resolvePost(url, value) {
      const resolve = deferredPosts.get(url);
      if (!resolve) throw new Error(`no deferred post: ${url}`);
      deferredPosts.delete(url);
      resolve(value);
    },
    codexFetches() { return fetchCalls.filter((call) => call.url === '/codex-usage').length; },
    codexRequests() { return fetchCalls.filter((call) => call.url === '/codex-usage'); },
    codexBox(container) { return container.querySelector('.codex-box'); },
    xaiBox(container) { return container.querySelector('.xai-box'); },
  };
}

async function staleResponseSchedulesOneReask() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [
      { use7d: 42, accountId: 'A', stale: true },
      { use7d: 43, accountId: 'A', stale: false },
    ],
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  const staleText = box.textContent;
  check('P2 stale response schedules exactly one re-ask',
        h.codexFetches() === 1 && h.timers.length === 1 && h.timers[0].delay === 3000
        && staleText.includes('42%') && staleText.includes('(last value)'));
  await h.runNextTimer();
  const reask = h.codexRequests()[1];
  check('P2 stale response converges after its one re-ask',
        h.codexFetches() === 2 && h.timers.length === 0
        && reask.options.headers['X-Airlock-Revalidate'] === 'wait'
        && box.textContent.includes('43%') && !box.textContent.includes('(last value)'));
}

async function freshResponseSchedulesNothing() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [{ use7d: 43, accountId: 'A', stale: false }],
  });
  const panel = h.mountPanel();
  await h.flush();
  check('P2 fresh response schedules no re-ask',
        h.codexFetches() === 1 && h.timers.length === 0
        && h.codexBox(panel).textContent.includes('43%'));
}

async function identityChangeCancelsDelayedWork() {
  const h = makeHarness({
    statuses: [
      { state: 'ok', accountId: 'A', email: 'a@example.com' },
      { state: 'ok', accountId: 'B', email: 'b@example.com' },
    ],
    usage: [
      { use7d: 42, accountId: 'A', stale: true },
      { use7d: 21, accountId: 'B', stale: false },
    ],
  });
  const firstPanel = h.mountPanel();
  await h.flush();
  const firstBox = h.codexBox(firstPanel);
  const before = firstBox.textContent;
  const secondPanel = h.mountPanel();
  await h.flush();
  await h.runNextTimer();
  check('P2 identity change prevents stale delayed work',
        h.codexFetches() === 2 && firstBox.textContent === before && h.flashes.length === 0
        && h.codexBox(secondPanel).textContent.includes('21%'));
}

async function unmountBeforeReaskCancelsTimer() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [{ use7d: 42, accountId: 'A', stale: true }],
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  const before = box.textContent;
  panel.remove();
  await h.runNextTimer();
  check('P2 unmount prevents the delayed re-ask from mutating UI',
        h.codexFetches() === 1 && box.textContent === before && h.flashes.length === 0);
}

async function unmountDuringReaskSuppressesError() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [
      { use7d: 42, accountId: 'A', stale: true },
      { deferred: true },
    ],
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  const before = box.textContent;
  await h.runNextTimer();
  panel.remove();
  h.rejectDeferred(new Error('late refresh failed'));
  await h.flush();
  check('P2 unmount suppresses a late re-ask error',
        h.codexFetches() === 2 && box.textContent === before
        && !box.textContent.includes('query failed') && h.flashes.length === 0);
}

async function reloginInvalidatesScheduledReask() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [{ use7d: 42, accountId: 'A', stale: true }],
    postResponses: {
      '/codex-login-start': { ok: true, url: 'https://example.test/device', code: 'ABCD' },
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  box.querySelectorAll('button')[0].onclick();
  await h.flush();
  await h.runNextTimer();
  check('P2 re-login guide invalidates the scheduled stale re-ask',
        h.codexFetches() === 1 && box.textContent.includes('Current login is cleared')
        && !box.textContent.includes('42%'));
}

async function logoutInvalidatesScheduledReask() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [{ use7d: 42, accountId: 'A', stale: true }],
    postResponses: { '/codex-logout': { ok: true } },
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  box.querySelectorAll('button')[1].onclick();
  await h.flush();
  await h.runNextTimer();
  check('P2 logout invalidates the scheduled stale re-ask',
        h.codexFetches() === 1 && box.textContent.includes('Not logged in')
        && !box.textContent.includes('42%'));
}

async function liveUsageCannotErasePendingRelogin() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [{ use7d: 42, accountId: 'A', stale: false }],
    postResponses: {
      '/acct-usage-now': { deferred: true },
      '/codex-login-start': { deferred: true },
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  box.querySelectorAll('button')[0].onclick();
  h.resolvePost('/acct-usage-now', {
    email: 'claude@example.com', kind: 'personal',
    usage: { use5h: 10, use7d: 20 },
  });
  await h.flush();
  h.resolvePost('/codex-login-start', {
    ok: true, url: 'https://example.test/device', code: 'ABCD',
  });
  await h.flush();
  check('P2 late Claude usage cannot erase a pending Codex re-login',
        h.codexBox(panel) === box && box.textContent.includes('Current login is cleared'));
}

async function liveUsageCannotErasePendingLogout() {
  const h = makeHarness({
    statuses: [{ state: 'ok', accountId: 'A', email: 'a@example.com' }],
    usage: [{ use7d: 42, accountId: 'A', stale: false }],
    postResponses: {
      '/acct-usage-now': { deferred: true },
      '/codex-logout': { deferred: true },
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.codexBox(panel);
  box.querySelectorAll('button')[1].onclick();
  h.resolvePost('/acct-usage-now', {
    email: 'claude@example.com', kind: 'personal',
    usage: { use5h: 10, use7d: 20 },
  });
  await h.flush();
  h.resolvePost('/codex-logout', { ok: true });
  await h.flush();
  check('P2 late Claude usage cannot erase a pending Codex logout',
        h.codexBox(panel) === box && box.textContent.includes('Not logged in'));
}

async function persistedClaudeUsageHasInlineMarker() {
  const staleAccount = {
    active: true, email: 'claude@example.com', kind: 'personal', sub: 'Claude',
    usage: { use5h: 10, use7d: 20, stale: true },
  };
  const h = makeHarness({
    statuses: [{ state: 'none' }],
    usage: [{}],
    accountPayload: {
      enabled: true,
      thresholds: { warn5: 78, crit5: 88, warn7: 88, crit7: 93, rtWarnDays: 5 },
      accounts: [staleAccount],
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const row = panel.querySelector('.acctrow');
  const label = row.querySelector('.pl');
  const numbers = row.querySelector('.acct-r');
  const freshHarness = makeHarness({
    statuses: [{ state: 'none' }],
    usage: [{}],
    accountPayload: {
      enabled: true,
      thresholds: { warn5: 78, crit5: 88, warn7: 88, crit7: 93, rtWarnDays: 5 },
      accounts: [Object.assign({}, staleAccount, {
        usage: { use5h: 10, use7d: 20, stale: false },
      })],
    },
  });
  const freshPanel = freshHarness.mountPanel();
  await freshHarness.flush();
  const freshLabel = freshPanel.querySelector('.acctrow').querySelector('.pl');
  check('P1 persisted Claude usage shows an inline stale marker',
        label.textContent.includes('(last value)')
        && !numbers.textContent.includes('(last value)')
        && numbers.textContent.includes('5h 10%') && numbers.textContent.includes('7d 20%')
        && !freshLabel.textContent.includes('(last value)'));
}

async function emptyLiveUsageCannotErasePersistedRows() {
  const h = makeHarness({
    statuses: [{ state: 'none' }],
    usage: [{}],
    postResponses: { '/acct-usage-now': { deferred: true } },
    accountPayload: {
      enabled: true,
      thresholds: { warn5: 78, crit5: 88, warn7: 88, crit7: 93, rtWarnDays: 5 },
      accounts: [
        { active: true, email: 'a@example.com', kind: 'personal', sub: 'Claude',
          usage: { use5h: 11, use7d: 21, stale: true } },
        { active: false, email: 'b@example.com', kind: 'team', sub: 'Claude',
          usage: { use5h: 31, use7d: 41, stale: true } },
      ],
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const cachedRows = panel.querySelectorAll('.acctrow');
  const cachedVisible = cachedRows[0].textContent.includes('5h 11%')
    && cachedRows[1].textContent.includes('5h 31%');
  h.resolvePost('/acct-usage-now', {
    usage: {}, email: 'a@example.com', kind: 'personal',
  });
  await h.flush();
  const rows = panel.querySelectorAll('.acctrow');
  check('P1 value-less fresh reading cannot erase persisted account rows',
        cachedVisible
        && rows[0].textContent.includes('5h 11%') && rows[0].textContent.includes('7d 21%')
        && rows[1].textContent.includes('5h 31%') && rows[1].textContent.includes('7d 41%'));
}

async function valuedLiveUsageReplacesPersistedRow() {
  const h = makeHarness({
    statuses: [{ state: 'none' }],
    usage: [{}],
    postResponses: { '/acct-usage-now': { deferred: true } },
    accountPayload: {
      enabled: true,
      thresholds: { warn5: 78, crit5: 88, warn7: 88, crit7: 93, rtWarnDays: 5 },
      accounts: [
        { active: true, email: 'a@example.com', kind: 'personal', sub: 'Claude',
          usage: { use5h: 11, use7d: 21, stale: true } },
        { active: false, email: 'b@example.com', kind: 'team', sub: 'Claude',
          usage: { use5h: 31, use7d: 41, stale: true } },
      ],
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const before = panel.querySelectorAll('.acctrow');
  const cachedVisible = before[0].textContent.includes('5h 11%')
    && before[0].textContent.includes('(last value)');
  h.resolvePost('/acct-usage-now', {
    usage: { use5h: 55, use7d: 65, stale: false },
    email: 'a@example.com', kind: 'personal',
  });
  await h.flush();
  const rows = panel.querySelectorAll('.acctrow');
  check('P1 valued fresh reading replaces only its persisted account row',
        cachedVisible
        && rows[0].textContent.includes('5h 55%') && rows[0].textContent.includes('7d 65%')
        && !rows[0].textContent.includes('(last value)')
        && rows[1].textContent.includes('5h 31%') && rows[1].textContent.includes('7d 41%'));
}

async function xaiFiveStatesRenderExactActions() {
  const cases = [
    {
      name: 'ok', payload: { enabled: true, state: 'ok', expires: Date.now() + 60_000 },
      text: ['Signed in', 'access token expires'], buttons: ['Re-login', 'Log out'],
    },
    {
      name: 'expired', payload: { enabled: true, state: 'expired', expires: 1 },
      text: ['Access token refresh needed', 'OpenCode refreshes on use'],
      buttons: ['Re-login', 'Log out'],
    },
    {
      name: 'none', payload: { enabled: true, state: 'none' },
      text: ['Not signed in', 'OpenCode xAI login required'], buttons: ['Log in'],
    },
    {
      name: 'malformed', payload: { enabled: true, state: 'malformed', reason: 'bad shape' },
      text: ['Credential unreadable', 'bad shape'], buttons: ['Re-login'],
    },
    {
      name: 'err', payload: { enabled: true, state: 'err', reason: 'PermissionError' },
      text: ['Credential status error', 'PermissionError'], buttons: [],
    },
  ];
  for (const item of cases) {
    const h = makeHarness({
      statuses: [{ state: 'none' }], usage: [{}], xaiStatuses: [item.payload],
    });
    const panel = h.mountPanel();
    await h.flush();
    const box = h.xaiBox(panel);
    const buttons = box.querySelectorAll('button').map((button) => button.textContent);
    check(`P3 xAI ${item.name} state renders safely with exact actions`,
          item.text.every((part) => box.textContent.includes(part))
          && JSON.stringify(buttons) === JSON.stringify(item.buttons)
          && box.textContent.includes('ACCESS_DO_NOT_EMIT') === false
          && box.textContent.includes('REFRESH_DO_NOT_EMIT') === false);
  }
}

async function xaiOldCredentialCannotCompletePendingLogin() {
  const h = makeHarness({
    statuses: [{ state: 'none' }], usage: [{}],
    xaiStatuses: [
      { enabled: true, state: 'ok', expires: Date.now() + 60_000, loginState: 'idle' },
      { enabled: true, state: 'ok', expires: Date.now() + 60_000, loginState: 'pending' },
      { enabled: true, state: 'ok', expires: Date.now() + 60_000, loginState: 'failed' },
    ],
    postResponses: {
      '/xai-login-start': {
        ok: true, url: 'https://accounts.x.ai/device', code: 'ABCD-EFGH',
      },
    },
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.xaiBox(panel);
  box.querySelectorAll('button')[0].onclick();
  await h.flush();
  const checkButton = box.querySelectorAll('button')[0];
  checkButton.onclick();
  await h.flush();
  check('P3 old signed credential cannot complete a pending xAI re-login',
        box.textContent.includes('Enter this code')
        && !h.flashes.some((message) => message.includes('login complete')));
  checkButton.onclick();
  await h.flush();
  check('P3 failed xAI child is reported instead of accepting the old credential',
        box.textContent.includes('Enter this code')
        && h.flashes.some((message) => message.includes('login failed')));
}

async function xaiRendersWithoutClaudeAccounts() {
  const h = makeHarness({
    statuses: [{ state: 'none' }], usage: [{}],
    accountPayload: { enabled: false, active: null, accounts: [] },
    xaiStatuses: [{ enabled: true, state: 'none', loginState: 'idle' }],
  });
  const panel = h.mountPanel();
  await h.flush();
  const box = h.xaiBox(panel);
  check('P3 xAI-only panel renders when Claude accounts are disabled',
        !!box && box.textContent.includes('Not signed in')
        && box.querySelectorAll('button').some((button) => button.textContent === 'Log in'));
}

await staleResponseSchedulesOneReask();
await freshResponseSchedulesNothing();
await identityChangeCancelsDelayedWork();
await unmountBeforeReaskCancelsTimer();
await unmountDuringReaskSuppressesError();
await reloginInvalidatesScheduledReask();
await logoutInvalidatesScheduledReask();
await liveUsageCannotErasePendingRelogin();
await liveUsageCannotErasePendingLogout();
await persistedClaudeUsageHasInlineMarker();
await emptyLiveUsageCannotErasePersistedRows();
await valuedLiveUsageReplacesPersistedRow();
await xaiFiveStatesRenderExactActions();
await xaiOldCredentialCannotCompletePendingLogin();
await xaiRendersWithoutClaudeAccounts();
check('P3 shared account buttons retain the Claude warning selector contract',
      !appSource.includes("'Subscription accounts'")
      && appSource.includes("'Switch account / subscriptions'"));

if (failures.length) {
  console.error(`\nFAILED: ${failures.join(', ')}`);
  process.exitCode = 1;
} else {
  console.log('\nall frontend contract checks passed');
}
