// Contract test for the shared return widget's TWO panel destinations.
//
// The widget used to take one data-panel base and open both "Subscription accounts"
// and "Secret drop" from it, which tied both entries to devterm's gate. It now reads
// data-account-panel and data-secret-panel as separate authorities; new renders point
// both at the platform surface under the hub's owner-gated prefix.
//
// The property under test is the separation itself, so the cases that matter are the
// asymmetric ones: each explicit destination alone, and the legacy data-panel alias,
// which is accepted for one release as the ACCOUNT destination ONLY. A test that always
// passes both attributes together stays green after one authority starts granting both.
//
// No browser and no server: the real hub/assets/airlock-return.js is executed against a
// DOM stub small enough to read, and the menu is opened by dispatching a click the same
// way a tap does.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const WIDGET = join(ROOT, "hub/assets/airlock-return.js");
const SRC = readFileSync(WIDGET, "utf8");

let pass = 0;
const failures = [];
function check(name, cond, observed) {
  if (cond) { pass++; console.log(`ok   ${name}`); }
  else { failures.push(name); console.log(`FAIL ${name}${observed === undefined ? "" : ` — observed: ${observed}`}`); }
}

// ---------------------------------------------------------------- DOM stub
function makeElement(tag) {
  const listeners = {};
  const el = {
    tagName: tag.toUpperCase(),
    children: [],
    style: {},
    dataset: {},
    textContent: "",
    attrs: {},
    parent: null,
    appendChild(c) { c.parent = el; el.children.push(c); return c; },
    removeChild(c) { el.children = el.children.filter((x) => x !== c); },
    remove() { if (el.parent) el.parent.removeChild(el); el.parent = null; },
    setAttribute(k, v) { el.attrs[k] = String(v); },
    getAttribute(k) { return k in el.attrs ? el.attrs[k] : null; },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener(type, fn) {
      listeners[type] = (listeners[type] || []).filter((f) => f !== fn);
    },
    dispatch(type, ev) {
      for (const fn of (listeners[type] || []).slice()) fn(ev);
    },
    contains(other) {
      if (other === el) return true;
      return el.children.some((c) => c.contains && c.contains(other));
    },
    getBoundingClientRect() { return { top: 10, bottom: 40, left: 10, right: 40, width: 30, height: 30 }; },
    offsetHeight: 120,
    offsetWidth: 236,
  };
  el.style.cssText = "";
  return el;
}

function descendants(el, out = []) {
  for (const c of el.children) { out.push(c); descendants(c, out); }
  return out;
}
function textOf(el) {
  return (el.textContent || "") + descendants(el).map((c) => c.textContent || "").join(" ");
}

// Runs the real widget with the given injected <script> dataset and returns handles to
// what it built. Every global the widget touches is provided here and nowhere else, so
// a new browser dependency shows up as a crash rather than as a silent pass.
function run(dataset, options = {}) {
  const body = makeElement("body");
  const script = makeElement("script");
  Object.assign(script.dataset, dataset);
  const fetched = [];
  const timers = [];
  const windowListeners = {};
  const doc = {
    currentScript: script,
    body,
    documentElement: body,
    createElement: makeElement,
    getElementById: () => null,
    querySelector: () => null,
    addEventListener() {},
    removeEventListener() {},
  };
  const win = {
    innerWidth: 1200,
    innerHeight: 800,
    location: { hostname: "box.example.ts.net", href: "" },
    console,
    addEventListener(type, fn) { (windowListeners[type] = windowListeners[type] || []).push(fn); },
    removeEventListener(type, fn) {
      windowListeners[type] = (windowListeners[type] || []).filter((f) => f !== fn);
    },
  };
  const safeArea = options.safeArea || {};
  win.getComputedStyle = () => ({
    paddingTop: `${safeArea.top || 0}px`,
    paddingRight: `${safeArea.right || 0}px`,
    paddingBottom: `${safeArea.bottom || 0}px`,
    paddingLeft: `${safeArea.left || 0}px`,
  });
  win.top = win;
  win.self = win;
  const store = { ...(options.store || {}) };
  const storage = {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
  };
  const fn = new Function(
    "window", "document", "location", "localStorage", "fetch",
    "setTimeout", "setInterval", "clearInterval", "clearTimeout", "navigator",
    SRC,
  );
  fn(
    win, doc, win.location, storage,
    (url) => { fetched.push(String(url)); return Promise.reject(new Error("offline")); },
    (f) => { timers.push(f); return timers.length; },
    (f) => { timers.push(f); return timers.length; },
    () => {}, () => {},
    { userAgent: "node" },
  );
  const btn = body.children[0];
  return {
    body, btn, fetched, store,
    // A tap: the widget navigates or opens its menu from the click handler.
    tap() { btn.dispatch("click", { preventDefault() {}, stopPropagation() {} }); },
    menu() { return body.children.find((c) => c !== btn && textOf(c).includes("Go to Airlock")); },
    rows(menuEl) { return (menuEl ? menuEl.children : []).map((c) => (c.children[0] || {}).textContent || ""); },
    clickRow(menuEl, label) {
      const row = menuEl.children.find((c) => (c.children[0] || {}).textContent === label);
      if (!row) throw new Error(`no menu row: ${label}`);
      row.dispatch("click", { preventDefault() {}, stopPropagation() {} });
      const overlay = body.children[body.children.length - 1];
      const frame = descendants(overlay).find((c) => c.tagName === "IFRAME");
      return frame ? frame.src : null;
    },
    dispatchWindow(type, event = {}) {
      for (const fn of (windowListeners[type] || []).slice()) fn(event);
    },
    href() { return win.location.href; },
  };
}

// ------------------------- floating position cannot enter an iPhone unsafe area
{
  const safeArea = { top: 47, right: 0, bottom: 34, left: 0 };
  const w = run({}, {
    safeArea,
    store: { "airlock:btn-pos-v1": JSON.stringify({ x: 1199, y: 0 }) },
  });
  check("floating: a restored position above the iPhone safe area is moved below it",
    w.btn.style.top === "60px", w.btn.style.top);
  check("floating: the right-side badge also stays inside the safe area",
    w.btn.style.left === "1143px", w.btn.style.left);
  safeArea.top = 59;
  w.dispatchWindow("resize");
  check("floating: a viewport change remeasures and reapplies the safe area",
    w.btn.style.top === "72px", w.btn.style.top);
}

const HUB = "https://box.example.ts.net/airlock-accounts/";
const DEVTERM = "https://box.example.ts.net:19300/";
const ACCOUNT_PAGE = HUB + "panel.html?p=accounts&embed=1";
const SECRET_PAGE = HUB + "panel.html?p=secret&embed=1";

// ------------------------------------------------- 1. both destinations given
let bothRows = "", bothAcctSrc = "", bothSecretSrc = "", bothFetch = "";
{
  const w = run({ menu: "1", accountPanel: HUB, secretPanel: HUB });
  w.tap();
  const m = w.menu();
  check("both: the tap opens the menu", !!m);
  bothRows = JSON.stringify(w.rows(m));
  check("both: all four rows are present",
    bothRows === JSON.stringify(["Go to Airlock", "Inbox · 0 unread", "Subscription accounts", "Secret drop"]),
    bothRows);
  bothAcctSrc = w.clickRow(m, "Subscription accounts");
  check("both: accounts opens the hub prefix", bothAcctSrc === ACCOUNT_PAGE, bothAcctSrc);
  w.tap();
  bothSecretSrc = w.clickRow(w.menu(), "Secret drop");
  check("both: secret drop opens the hub prefix", bothSecretSrc === SECRET_PAGE, bothSecretSrc);
  check("both: separate authorities may share the platform base",
    bothAcctSrc === ACCOUNT_PAGE && bothSecretSrc === SECRET_PAGE,
    `${bothAcctSrc} | ${bothSecretSrc}`);
  bothFetch = JSON.stringify(w.fetched);
  check("both: platform panel attributes do not imply a cross-origin alert poll",
    !w.fetched.some((u) => u.includes("acct-alert")), bothFetch);
}

// -------------------------- 2. explicit account authority without secret authority
let acctOnlyRows = "", acctOnlySrc = "", acctOnlyFetch = "";
{
  const w = run({ menu: "1", accountPanel: HUB });
  w.tap();
  const m = w.menu();
  check("account-only: the tap still opens the menu", !!m);
  acctOnlyRows = JSON.stringify(w.rows(m));
  check("account-only: the subscription row is there and secret drop is not",
    acctOnlyRows === JSON.stringify(["Go to Airlock", "Inbox · 0 unread", "Subscription accounts"]), acctOnlyRows);
  acctOnlySrc = w.clickRow(m, "Subscription accounts");
  check("account-only: it opens the hub prefix", acctOnlySrc === ACCOUNT_PAGE, acctOnlySrc);
  acctOnlyFetch = JSON.stringify(w.fetched);
  check("account-only: a panel authority does not imply a cross-origin alert poll",
    !w.fetched.some((u) => u.includes("acct-alert")), acctOnlyFetch);
}

// ------------------------------------- 3. legacy data-panel alias = ACCOUNT only
let legacyRows = "", legacySrc = "";
{
  const w = run({ menu: "1", panel: DEVTERM });
  w.tap();
  const m = w.menu();
  legacyRows = JSON.stringify(w.rows(m));
  check("legacy alias: grants the account row only, never secret drop",
    legacyRows === JSON.stringify(["Go to Airlock", "Inbox · 0 unread", "Subscription accounts"]), legacyRows);
  legacySrc = w.clickRow(m, "Subscription accounts");
  check("legacy alias: the account row opens the base it was given",
    legacySrc === DEVTERM + "panel.html?p=accounts&embed=1", legacySrc);
  check("legacy alias: keeps polling that base for the ring",
    w.fetched.some((u) => u === DEVTERM + "acct-alert"), JSON.stringify(w.fetched));
}

// ------------------ 4. an explicit secret authority works without granting accounts
{
  const w = run({ menu: "1", secretPanel: HUB });
  w.tap();
  const m = w.menu();
  const rows = m && w.rows(m);
  check("secret-only: the menu has Secret drop and no accounts row",
    !!rows && rows.includes("Secret drop") && !rows.includes("Subscription accounts"),
    JSON.stringify(rows));
  const secret = w.clickRow(m, "Secret drop");
  check("secret-only: Secret drop opens the platform prefix", secret === SECRET_PAGE, secret);
}

// --------------------------------------------- 5. only the legacy account alias is a ring source
{
  const w = run({ menu: "1", accountPanel: HUB, secretPanel: HUB });
  check("ring: platform panel destinations do not silently grant alert-fetch authority",
    !w.fetched.some((u) => u.includes("acct-alert")), JSON.stringify(w.fetched));
}

// ------------------------------------------------------------------- wiring
// The stub proves the LOGIC. These prove the widget is actually FED that way: a
// renderer still emitting one data-panel would leave every assertion above green.
const injectors = {
  "apps/orca/install.sh": readFileSync(join(ROOT, "apps/orca/install.sh"), "utf8"),
  "apps/paseo/install.sh": readFileSync(join(ROOT, "apps/paseo/install.sh"), "utf8"),
};
for (const [path, text] of Object.entries(injectors)) {
  check(`${path}: derives the shared platform base without devterm`,
    text.includes('PLATFORM_PANEL_URL="$(airlock_secret_panel_url || true)"'));
  check(`${path}: emits separate account and secret authorities and no legacy data-panel`,
    text.includes("data-account-panel=") && text.includes("data-secret-panel=") &&
      !text.includes("data-panel="));
  check(`${path}: feeds both destinations the same platform URL`,
    text.includes('data-account-panel=\\"${PLATFORM_PANEL_URL}\\" data-secret-panel=\\"${PLATFORM_PANEL_URL}\\"'));
}
// The installer-path goldens are rendered by running the real installer on a box
// without devterm — the delivered form of case 2 above.
for (const g of ["orca/installer-path", "paseo/installer-path"]) {
  const conf = readFileSync(join(ROOT, "install/golden/render", g, "nginx.conf"), "utf8");
  // The shared gate injects the widget with no menu attrs on the proxied app itself
  // (gate/nginx-lib.sh, unchanged here); the app's own page is the one that carries the
  // menu. Pin exactly one menu-bearing injection so a second one cannot appear unnoticed.
  const menuLines = conf.split("\n").filter((l) => l.includes("sub_filter '</body>'") && l.includes('data-menu="1"'));
  const line = menuLines.join(" | ");
  check(`golden ${g}: devterm absent injects both platform destinations, exactly once`,
    menuLines.length === 1 &&
      line.includes('data-account-panel="https://box.example.ts.net/airlock-accounts/"') &&
      line.includes('data-secret-panel="https://box.example.ts.net/airlock-accounts/"'),
    line.trim() || "(no menu-bearing injection)");
  check(`golden ${g}: emits no legacy account alias`,
    !line.includes("data-panel="), line.trim());
}

// --------------------------------------------------------------------- AC rows
const ac = [
  ["AC-DTI-P2A",
    "both injectors emit separate account+secret attributes with one platform URL and no data-panel",
    Object.keys(injectors).map((p) => `${p}: account=${injectors[p].includes("data-account-panel=")} secret=${injectors[p].includes("data-secret-panel=")} legacy=${injectors[p].includes("data-panel=")}`).join("; ")],
  ["AC-DTI-P2B",
    "without devterm both rows exist and open their views on the platform prefix",
    `rows=${bothRows} account=${bothAcctSrc} secret=${bothSecretSrc} fetches=${bothFetch}`],
  ["AC-DTI-P2C",
    "the installer-path goldens (devterm absent, real installer) carry both platform destinations and no legacy alias",
    "orca/installer-path, paseo/installer-path"],
  ["AC-DTI-P2D",
    "the legacy data-panel alias grants account authority only",
    `rows=${legacyRows} src=${legacySrc}`],
];
console.log("");
for (const [id, expected, observed] of ac) {
  console.log(`${id} | expected: ${expected} | observed: ${observed} | verdict: ${failures.length ? "SEE FAILURES" : "PASS"} | signal: fixture | evidence: install/test-return-widget-contract.mjs`);
}
console.log("");
console.log(`return-widget-contract: ${pass} ok, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
