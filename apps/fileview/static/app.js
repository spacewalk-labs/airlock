'use strict';
// ====================================================================
// fileview-split — vanilla indented tree + a viewer that renders every type itself.
// Multitype preview: image, PDF (browser-native, same-origin), audio/video,
// code (highlight.js), collapsible JSON tree, CSV/TSV table, Jupyter .ipynb.
// ====================================================================

// ---- THEME ----
var STORAGE_KEY = 'fileview-theme';
var theme = localStorage.getItem(STORAGE_KEY) || 'system';
document.documentElement.setAttribute('data-theme', theme);

function setTheme(next) {
  theme = next;
  document.documentElement.setAttribute('data-theme', next);
  try { localStorage.setItem(STORAGE_KEY, next); } catch (_) {}
  document.querySelectorAll('#ms-bar [data-theme-btn]').forEach(function (b) {
    b.setAttribute('aria-pressed', b.dataset.themeBtn === next ? 'true' : 'false');
  });
  // And into whatever the viewer is showing. Reaching into contentDocument was the
  // old way and it silently did nothing: every srcdoc this app builds is
  // sandbox="", which gives it an opaque origin, so contentDocument is null and
  // the exception was swallowed. Switching theme with a code or JSON file open left
  // that pane painted in the previous theme until something else re-rendered it.
  // The srcdoc is a string we own, so the theme is swapped in the string.
  if (lastSrcdoc) {
    lastSrcdoc = lastSrcdoc.replace(/^(<!doctype html><html data-theme=")[^"]*/i, '$1' + next);
    viewer.srcdoc = lastSrcdoc;
  }
}

// ---- ELEMENTS ----
var tree     = document.getElementById('ms-tree');
var treePane = document.getElementById('ms-treepane');   // scroller + search bar
var menuEl   = document.getElementById('ms-menu');
var searchEl = document.getElementById('ms-search');
var scopeEl  = document.getElementById('ms-scope');
var viewer   = document.getElementById('ms-viewer');
var pane     = document.getElementById('ms-pane');
var pathEl   = document.getElementById('ms-path');
var editBtn  = document.getElementById('ms-edit');
var saveBtn  = document.getElementById('ms-save');
var copyBtn  = document.getElementById('ms-copy');
var dlBtn    = document.getElementById('ms-download');
var rawToggleBtn = document.getElementById('ms-rawtoggle');

/* A toolbar control changes its icon, not its width. Swapping label text made
   the buttons beside it jump every time a file opened; swapping the <use>
   reference does not move anything. The accessible name is set alongside it —
   the shape is what you see, the label is what a screen reader reads, and they
   have to say the same thing. */
function setIcon(btn, symbol, label, tip) {
  var use = btn.querySelector('use');
  if (use) use.setAttribute('href', '#i-' + symbol);
  btn.setAttribute('aria-label', label);
  btn.title = tip || label;
}
var mtimeEl  = document.getElementById('ms-mtime');
var resizeHandle = document.getElementById('ms-resize');
var toastEl  = document.getElementById('ms-toast');

// ---- STATE ----
var currentPath = '/';           // current viewer path
var currentMd   = null;          // last opened file path (for the Edit toggle)
var currentView = null;          // current file's descriptor.v (for the Raw toggle re-render)
var rawOverride = false;         // force a structured view (json/csv) to show as raw text
var inEditMode  = false;
var savedContent = null;         // last-saved content (for the dirty check)

// ---- TOAST ----
var toastTimer = null;
function showToast(msg) {
  if (toastTimer) clearTimeout(toastTimer);
  toastEl.textContent = msg;
  toastEl.classList.add('show');
  toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 1500);
}

// ---- SIDEBAR/TREE DRAG-RESIZE (touch + vertical/mobile axis aware) ----
var mainEl = document.querySelector('main');
var SIDEBAR_KEY = 'fileview-sidebar-width';   // desktop (horizontal): tree 'width' (px)
var TREEH_KEY   = 'fileview-tree-height';     // mobile (stacked): tree 'height' (px)
function isColumn() { return window.matchMedia('(max-width: 800px)').matches; }
// Apply the saved size for the current layout. If none, clear the inline value so
// the CSS default takes over (horizontal 320px / vertical 35vh).
function resizeRange() {
  return isColumn()
    ? { lo: 80, hi: Math.max(80, window.innerHeight - 120) }
    : { lo: 200, hi: 800 };
}
// A focusable separator has to publish where it is; ARIA requires aria-valuenow,
// and the orientation it announces has to be the one its arrow keys actually use
// — which flips at the stacked breakpoint.
function announceResize() {
  var r = resizeRange();
  var box = treePane.getBoundingClientRect();
  resizeHandle.setAttribute('aria-orientation', isColumn() ? 'horizontal' : 'vertical');
  resizeHandle.setAttribute('aria-valuemin', String(r.lo));
  resizeHandle.setAttribute('aria-valuemax', String(r.hi));
  resizeHandle.setAttribute('aria-valuenow',
    String(Math.round(isColumn() ? box.height : box.width)));
}
function applyTreeSize() {
  var r = resizeRange();
  var v = parseInt(localStorage.getItem(isColumn() ? TREEH_KEY : SIDEBAR_KEY) || '0', 10);
  treePane.style.flexBasis = (v >= r.lo && v <= r.hi) ? v + 'px' : '';
  announceResize();
}
applyTreeSize();
window.addEventListener('resize', applyTreeSize);   // swap axis/saved value on rotation

var dragging = false;
function dragStart(ev) {
  dragging = true; resizeHandle.classList.add('dragging');
  document.body.style.cursor = isColumn() ? 'row-resize' : 'col-resize';
  document.body.style.userSelect = 'none';
  if (ev.cancelable) ev.preventDefault();
}
function dragTo(x, y) {
  if (!dragging) return;
  if (isColumn()) {
    var top = mainEl.getBoundingClientRect().top;   // vertical: tree height = pointer y - main top
    treePane.style.flexBasis = Math.max(80, Math.min(window.innerHeight - 120, y - top)) + 'px';
  } else {
    treePane.style.flexBasis = Math.max(200, Math.min(800, x)) + 'px';
  }
}
function dragEnd() {
  if (!dragging) return;
  dragging = false; resizeHandle.classList.remove('dragging');
  document.body.style.cursor = ''; document.body.style.userSelect = '';
  var r = treePane.getBoundingClientRect();
  try { localStorage.setItem(isColumn() ? TREEH_KEY : SIDEBAR_KEY, String(Math.round(isColumn() ? r.height : r.width))); } catch (_) {}
  announceResize();
}
resizeHandle.addEventListener('mousedown', dragStart);
document.addEventListener('mousemove', function (ev) { dragTo(ev.clientX, ev.clientY); });
document.addEventListener('mouseup', dragEnd);
resizeHandle.addEventListener('touchstart', dragStart, { passive: false });
document.addEventListener('touchmove', function (ev) {
  if (!dragging) return;
  var t = ev.touches[0]; if (!t) return;
  if (ev.cancelable) ev.preventDefault();   // stop the page from scrolling while dragging
  dragTo(t.clientX, t.clientY);
}, { passive: false });
document.addEventListener('touchend', dragEnd);
// The same splitter from the keyboard. It moves in 16px steps, which is one
// spacing unit and roughly what a person expects a nudge to be; Home/End take it
// to the two ends of the range the pointer is clamped to.
resizeHandle.addEventListener('keydown', function (ev) {
  var range = resizeRange();
  var lo = range.lo, hi = range.hi;
  var r = treePane.getBoundingClientRect();
  var at = Math.round(isColumn() ? r.height : r.width);
  var grow = isColumn() ? 'ArrowDown' : 'ArrowRight';
  var shrink = isColumn() ? 'ArrowUp' : 'ArrowLeft';
  var next;
  if (ev.key === grow) next = at + 16;
  else if (ev.key === shrink) next = at - 16;
  else if (ev.key === 'Home') next = lo;
  else if (ev.key === 'End') next = hi;
  else return;
  ev.preventDefault();
  next = Math.max(lo, Math.min(hi, next));
  treePane.style.flexBasis = next + 'px';
  try { localStorage.setItem(isColumn() ? TREEH_KEY : SIDEBAR_KEY, String(next)); } catch (_) {}
  announceResize();
});
document.addEventListener('touchcancel', dragEnd);

// ---- localStorage, defensively ----
// Every subpath app on this hub shares one origin, so this quota is shared with
// notepad and everything else. A write that fails is never fatal here: the cache is
// an optimisation and the JWT can always be re-issued.
var store = {
  get: function (k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
  set: function (k, v) {
    try { localStorage.setItem(k, v); return true; }
    catch (_) { evictCache(); try { localStorage.setItem(k, v); return true; } catch (_) { return false; } }
  },
  del: function (k) { try { localStorage.removeItem(k); } catch (_) {} }
};

// ---- directory listing cache ----
// The whole answer to "a freshly installed box takes ages to show anything": paint
// the tree from what we saw last time (zero round trips), then re-fetch in the
// background and replace any directory whose listing actually changed.
//
// Only the SHAPE of the tree is cached. File contents never are — showing a stale
// file as if it were current is the one failure a viewer must not have.
var CACHE_PREFIX = 'fileview:tree:';
var OPEN_KEY = 'fileview:open';
var CACHE_MAX_DIRS = 200;
// /proc, /sys and /run are synthetic and change every second, so a cache entry for
// them is stale before it is written. This is cache POLICY, not a display filter —
// they render in the tree exactly like every other directory.
var VOLATILE_RE = /^\/(proc|sys|run)(\/|$)/;
function cacheKey(dirPath) { return CACHE_PREFIX + dirPath; }
function cacheGet(dirPath) {
  if (VOLATILE_RE.test(dirPath)) return null;
  var raw = store.get(cacheKey(dirPath));
  if (!raw) return null;
  try {
    var v = JSON.parse(raw);
    return (v && Array.isArray(v.items)) ? v : null;
  } catch (_) { store.del(cacheKey(dirPath)); return null; }
}
var cachedDirs = 0;
function cacheSet(dirPath, items) {
  if (VOLATILE_RE.test(dirPath)) return;
  var fresh = !store.get(cacheKey(dirPath));
  if (!store.set(cacheKey(dirPath), JSON.stringify({ items: items, at: Date.now() }))) return;
  // Bound it here rather than waiting for a QuotaExceededError. The quota is shared
  // with every other app on this origin, so "grow until someone fails" makes this
  // app the one that breaks a neighbour.
  if (fresh && ++cachedDirs > CACHE_MAX_DIRS) { evictCache(); cachedDirs = countCachedDirs(); }
}
function countCachedDirs() {
  var n = 0;
  try {
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (k && k.indexOf(CACHE_PREFIX) === 0) n++;
    }
  } catch (_) {}
  return n;
}
function cacheDrop(dirPath) { store.del(cacheKey(dirPath)); }
// Drop the cache entry for the directory holding `path`. Called after every write:
// a rename or a delete that left a stale row behind is worse than a slow paint.
function cacheDropParent(path) {
  var parent = path.replace(/\/[^/]*$/, '') || '/';
  cacheDrop(parent);
}
// Which directories were expanded when the tab was last used. Restoring these is
// what makes a revisit look like "where I left off" rather than "the root, again".
function saveOpenDirs() {
  var open = openDirsUnder(tree);
  store.set(OPEN_KEY, JSON.stringify(open.slice(0, CACHE_MAX_DIRS)));
}
function loadOpenDirs() {
  try {
    var v = JSON.parse(store.get(OPEN_KEY) || '[]');
    return Array.isArray(v) ? v : [];
  } catch (_) { return []; }
}

// Oldest-first eviction, used when the shared quota runs out.
// Initialised once so the bound above has a starting point.
function evictCache() {
  var entries = [];
  try {
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (k && k.indexOf(CACHE_PREFIX) === 0) {
        var at = 0;
        try { at = (JSON.parse(localStorage.getItem(k)) || {}).at || 0; } catch (_) {}
        entries.push([at, k]);
      }
    }
  } catch (_) { return; }
  entries.sort(function (a, b) { return a[0] - b[0]; });
  var drop = Math.max(1, entries.length - Math.floor(CACHE_MAX_DIRS / 2));
  for (var j = 0; j < drop && j < entries.length; j++) store.del(entries[j][1]);
}

// ---- JWT bootstrap (zero-login, filebrowser noauth) ----
// The same token travels two ways, deliberately:
//   header X-Auth  — every fetch(), and the ONLY thing filebrowser accepts for a
//                    write. Measured against the pinned binary: PUT/DELETE with
//                    the cookie alone -> 401, file untouched.
//   cookie auth=   — accepted for GET only, which is what lets <img>/<video>/the
//                    PDF viewer be plain URLs with no JS plumbing. Because writes
//                    ignore it, a cross-site request cannot mutate anything.
// Scoped to this app's subpath; SameSite=Lax; Secure unless served over plain
// http (a local-loopback test run), where a Secure cookie would be dropped.
var jwtCache = store.get('fileview-jwt') || null;
function setAuthCookie(jwt) {
  try {
    document.cookie = 'auth=' + jwt + '; path=/fileview/; SameSite=Lax'
      + (location.protocol === 'https:' ? '; Secure' : '');
  } catch (_) {}
}
if (jwtCache) setAuthCookie(jwtCache);
function getJwt() {
  if (jwtCache) return Promise.resolve(jwtCache);
  return fetch('/fileview/api/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{}'
  }).then(function (r) {
    if (!r.ok) throw new Error('login ' + r.status);
    return r.text();
  }).then(function (jwt) {
    jwtCache = jwt;
    store.set('fileview-jwt', jwt);
    setAuthCookie(jwt);
    return jwt;
  });
}

// `gen`, when given, is a paintDir generation: the response is dropped (and NOT
// cached) if a newer paint of the same container has started since.
function fetchListing(dirPath, gen) {
  var startedAt = gen;
  return getJwt().then(function (jwt) {
    var url = apiUrl('resources', dirPath === '/' ? '/' : dirPath);
    if (!url.endsWith('/')) url += '/';
    return fetch(url, { headers: { 'X-Auth': jwt } });
  }).then(function (r) {
    if (r.status === 401) {
      // JWT expired — reissue and retry. The retry resolves to the ITEM ARRAY, not
      // a Response, so it has to be wrapped back into the shape the next step
      // expects. It was returned bare, and `data.items` on an array is undefined —
      // so a recovered token produced an EMPTY tree, silently, and then cached the
      // emptiness. Nothing reported anything; the pane simply had no rows.
      jwtCache = null; store.del('fileview-jwt');
      return fetchListing(dirPath, startedAt).then(function (items) { return { items: items, retried: true }; });
    }
    if (!r.ok) throw new Error('resources ' + r.status + ' for ' + dirPath);
    return r.json();
  }).then(function (data) {
    var items = data.items || [];
    // The retry already cached under its own call; caching again is harmless but
    // pointless, and skipping it keeps "one write per fetch" true.
    if (!data.retried && (startedAt === undefined || startedAt === paintGen)) cacheSet(dirPath, items);
    return items;
  });
}
// Same listing, and a comparable one: item order out of filebrowser is stable, so a
// byte comparison of the projection is enough to answer "did this directory change".
function listingFingerprint(items) {
  return items.map(function (i) {
    return i.path + '\u0000' + (i.isDir ? 'd' : 'f') + '\u0000' + i.size + '\u0000' + i.modified;
  }).join('\n');
}
// How deep this container sits, counting the groups between it and the tree. The
// indent guide says this visually; aria-level is the same fact for a reader that
// cannot see the guide.
function containerLevel(container) {
  var level = 1;
  for (var n = container; n && n !== tree; n = n.parentNode) {
    if (n.className === 'ms-children') level++;
  }
  return level;
}
function fillChildren(container, items) {
  container.innerHTML = '';
  var sorted = sortItems(items);
  var level = String(containerLevel(container));
  for (var i = 0; i < sorted.length; i++) {
    var child = renderNode(sorted[i], 0);
    child.firstChild.setAttribute('aria-level', level);
    child.firstChild.setAttribute('aria-setsize', String(sorted.length));
    child.firstChild.setAttribute('aria-posinset', String(i + 1));
    container.appendChild(child);
  }
  // A repaint replaces the row that was carrying the tree's single tab stop.
  // Without this, a tree that has been refreshed has no tab stop at all and
  // cannot be reached from the keyboard.
  syncTabStop();
}
// Paint from cache if there is one, then revalidate and repaint only on a real
// difference — repainting unconditionally would collapse whatever the user had open
// underneath, every time, for nothing.
var paintGen = 0;
function paintDir(container, dirPath, openAfter) {
  // Snapshot BEFORE anything is drawn. Reading it after the first paint reads an
  // already-replaced DOM, which is how a repaint used to fold every subtree the
  // user had open and then "restore" an empty list.
  var reopen = openAfter ? openDirsUnder(container) : null;
  // Two paints of the same container can overlap (a mutation and the visibility
  // revalidate, say). Without a generation the slower one wins by finishing last,
  // and it writes an OLDER listing over a newer one — into the DOM and the cache
  // both, resurrecting rows that were just deleted.
  var gen = ++paintGen;
  container.dataset.paintGen = String(gen);
  var cached = cacheGet(dirPath);
  var painted = false;
  if (cached) { fillChildren(container, cached.items); painted = true; }
  else container.innerHTML = '<div class="ms-loading">…</div>';
  var stale = function () { return container.dataset.paintGen !== String(gen); };
  return fetchListing(dirPath, gen).then(function (items) {
    if (stale() || items === null) return items;
    if (!painted || listingFingerprint(items) !== listingFingerprint(cached.items)) {
      fillChildren(container, items);
      if (reopen && reopen.length) reopenDirs(container, reopen);
    }
    return items;
  }).catch(function (e) {
    if (stale()) return null;
    if (!painted) container.innerHTML = '<div class="ms-error">' + escapeHTML(e.message) + '</div>';
    else showToast('Could not refresh: ' + e.message);
    return null;
  });
}
// Which directories under `container` are currently expanded, so a repaint can put
// them back rather than folding the tree under the user's cursor.
function openDirsUnder(container) {
  var out = [];
  var nodes = container.querySelectorAll('.ms-node[data-isdir="1"]');
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i].querySelector(':scope > .ms-children')) out.push(nodes[i].dataset.path);
  }
  return out;
}
function reopenDirs(container, paths) {
  paths.sort();   // parents before children: '/a' sorts before '/a/b'
  var p = Promise.resolve();
  paths.forEach(function (dirPath) {
    p = p.then(function () {
      var node = container.querySelector('.ms-node[data-path="' + cssEscape(dirPath) + '"]');
      if (node && !node.querySelector(':scope > .ms-children')) return toggleDir(node);
    });
  });
  return p;
}

// ---- TREE RENDER ----
/* TESTABLE:tree — everything between these markers is extracted and run against a
   minimal DOM by install/test-fileview-tree.mjs. The claim it pins is the one this
   app makes out loud: the tree renders one row per item it was given and drops
   nothing, dotfiles included. A grep for the absence of a filter would not prove
   that; running the renderer does. */
function extOf(name) {
  var m = name.match(/\.([a-zA-Z0-9]+)$/);
  return m ? m[1].toLowerCase() : '';
}
/* Directories first, then names. There used to be a third clause here putting
   .md ahead of everything else, from the markdown viewer this app grew out of.
   A general file viewer has no favourite extension: a rule that floats one file
   type is the same rule that would sink another, and this app's whole promise is
   that it has neither. */
function sortItems(items) {
  return items.slice().sort(function (a, b) {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return a.name.localeCompare(b.name, 'en');
  });
}

/**
 * Render one node (dir or file). Returns a DOM element.
 */
function renderNode(item, depth) {
  var node = document.createElement('div');
  node.className = 'ms-node';
  node.dataset.path = item.path;
  node.dataset.isdir = item.isDir ? '1' : '0';

  var row = document.createElement('div');
  row.className = 'ms-row';
  /* A tree you can only reach with a mouse is not finished. The rows form one
     tab stop and the arrow keys move within it — the roving-tabindex pattern,
     which is what a native outline view does. */
  row.setAttribute('role', 'treeitem');
  row.setAttribute('tabindex', '-1');
  if (item.isDir) row.setAttribute('aria-expanded', 'false');

  var chev = document.createElement('span');
  chev.className = 'ms-chev ' + (item.isDir ? 'collapsed' : 'leaf');
  row.appendChild(chev);

  var name = document.createElement('span');
  name.className = 'ms-name';
  name.textContent = item.name;
  row.appendChild(name);

  node.appendChild(row);

  row.addEventListener('click', function (ev) {
    ev.stopPropagation();
    if (item.isDir) {
      toggleDir(node);
    } else {
      openFile(item.path);
    }
  });

  return node;
}
/* :TESTABLE */

function toggleDir(node) {
  var existing = node.querySelector(':scope > .ms-children');
  var row = node.querySelector(':scope > .ms-row');
  var chev = node.querySelector(':scope > .ms-row > .ms-chev');
  if (existing) {
    existing.remove();
    chev.className = 'ms-chev collapsed';
    row.setAttribute('aria-expanded', 'false');
    saveOpenDirs();
    return Promise.resolve();
  }
  chev.className = 'ms-chev expanded';
  row.setAttribute('aria-expanded', 'true');
  var children = document.createElement('div');
  children.className = 'ms-children';
  // The rows inside are treeitems; without a group between them and the tree they
  // are announced as a flat list at one level, whatever the indent guide shows.
  children.setAttribute('role', 'group');
  node.appendChild(children);
  return paintDir(children, node.dataset.path, true).then(function (items) {
    saveOpenDirs();
    return items;
  });
}

function highlightActive(path) {
  document.querySelectorAll('#ms-tree .ms-row.active').forEach(function (r) {
    r.classList.remove('active');
  });
  var node = document.querySelector('#ms-tree .ms-node[data-path="' + cssEscape(path) + '"]');
  if (node) {
    var row = node.querySelector(':scope > .ms-row');
    row.classList.add('active');
    setTabStop(row);   // tabbing in should land on what is selected now
  }
  if (typeof announceNewTargets === 'function') announceNewTargets();
}

function cssEscape(s) {
  return s.replace(/(["\\])/g, '\\$1');
}

// ---- VIEWER / EDITOR swap ----
function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, function (c) {
    return { '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c];
  });
}
function langByExt(path) {
  var m = path.match(/\.([a-zA-Z0-9]+)$/);
  if (!m) return '';
  var ext = m[1].toLowerCase();
  return ({
    json:'json', js:'javascript', ts:'typescript', py:'python', sh:'bash',
    yaml:'yaml', yml:'yaml', toml:'toml', conf:'ini', cfg:'ini', ini:'ini',
    env:'bash', gitignore:'bash', dockerignore:'bash',
    html:'html', css:'css', md:'markdown', xml:'xml', sql:'sql', go:'go',
    rs:'rust', java:'java', cpp:'cpp', c:'c', tf:'hcl'
  })[ext] || '';
}
// ---- RENDERER REGISTRY (extension -> descriptor) ----
// transport: 'url'  = the browser requests the raw file itself (the auth cookie
//                     authenticates; Content-Type/Range/cache are automatic).
//            'text' = JS fetches the raw file via filebrowser and transforms it
//                     (the default fallback).
// view: how to render. Any extension not registered as a url flows through text and
//       hits the size/binary guards.
var VIEW_MAP = {
  // images — <img> (svg included, scripts do not execute)
  png:{t:'url',v:'img'}, jpg:{t:'url',v:'img'}, jpeg:{t:'url',v:'img'},
  gif:{t:'url',v:'img'}, webp:{t:'url',v:'img'}, avif:{t:'url',v:'img'},
  bmp:{t:'url',v:'img'}, ico:{t:'url',v:'img'}, svg:{t:'url',v:'img'},
  // PDF — the browser's built-in viewer (same-origin document)
  pdf:{t:'url',v:'pdf'},
  // media — native elements (Range seek verified)
  mp4:{t:'url',v:'video'}, webm:{t:'url',v:'video'}, mov:{t:'url',v:'video'}, m4v:{t:'url',v:'video'},
  mp3:{t:'url',v:'audio'}, wav:{t:'url',v:'audio'}, ogg:{t:'url',v:'audio'},
  m4a:{t:'url',v:'audio'}, flac:{t:'url',v:'audio'}, aac:{t:'url',v:'audio'},
  // markdown — parsed and rendered by this document (marked + DOMPurify)
  md:{t:'text',v:'md'}, markdown:{t:'text',v:'md'},
  // structured text (text transport, parsed by the parent into a static srcdoc)
  json:{t:'text',v:'json'}, csv:{t:'text',v:'csv'}, tsv:{t:'text',v:'csv'}, ipynb:{t:'text',v:'ipynb'}
};
function descriptorFor(path) {
  var ext = extOf(path.split('/').pop());
  return VIEW_MAP[ext] || { t:'text', v:'code' };  // fallback: text (binary/oversize guarded inside)
}
// The ONE way a file path becomes part of a URL. Per-segment encoding plus a
// traversal/control-char block, so a name containing a space, '#', '%' or '?'
// survives the round trip. Every API call site below goes through this — they
// used to concatenate the raw path, which broke listing/read/save on such names.
function encPath(path) {
  var segs = String(path).split('/');
  for (var i = 0; i < segs.length; i++) {
    if (segs[i] === '..' || segs[i] === '.') throw new Error('unsafe path segment');
    if (/[\x00-\x1f]/.test(segs[i])) throw new Error('control char in path');
  }
  return segs.map(function (s) { return encodeURIComponent(s); }).join('/');
}
// filebrowser API URL for a path (kind = 'resources' | 'raw' | 'files').
function apiUrl(kind, path, query) {
  return '/fileview/api/' + kind + encPath(path) + (query ? '?' + query : '');
}

var TEXT_MAX_BYTES = 3 * 1024 * 1024;   // text-preview ceiling (over it, offer a download)
var HLJS_MAX_BYTES = 256 * 1024;        // above this, skip highlighting -> plain <pre> (avoids locking the parent thread)
var JSON_MAX_NODES = 10000, JSON_MAX_DEPTH = 100, JSON_OPEN_DEPTH = 2, JSON_STR_CLAMP = 2048, JSON_HTML_MAX = 4 * 1024 * 1024;
var CSV_MAX_ROWS = 2000, CSV_MAX_CELLS = 50000, CSV_MAX_COLS = 100, CSV_CELL_CLAMP = 2048;

// ---- SANDBOX POLICY ----
// Every srcdoc we generate (media/text/json/csv/notice) is isolated with
// sandbox="" — this blocks any access to the parent's sessionStorage (the
// filebrowser write JWT). No scripts are needed inside. The browser's PDF viewer
// needs a real same-origin document, so the sandbox is removed for that one.
// Exactly one of the two render targets is live at a time. Switching to the pane
// also blanks the iframe: an <iframe> left holding a playing video keeps playing.
function showPane(nodes) {
  lastSrcdoc = null;
  if (viewer.hasAttribute('srcdoc')) viewer.removeAttribute('srcdoc');
  viewer.src = 'about:blank';
  viewer.hidden = true;
  pane.textContent = '';
  if (nodes) pane.appendChild(nodes);
  pane.hidden = false;
}
function showViewer() {
  pane.hidden = true;
  pane.textContent = '';
  viewer.hidden = false;
}
function sandboxViewer() { viewer.setAttribute('sandbox', ''); }
function unsandboxViewer() { viewer.removeAttribute('sandbox'); }
// Defense-in-depth CSP — even if our own escaping slips once, external resource
// loads and script execution are blocked.
function cspMeta(kind) {
  var p;
  if (kind === 'ipynb') p = "default-src 'none'; img-src data:; style-src 'self' 'unsafe-inline'; font-src 'self'";  // output images = renderer-produced data URIs only
  else p = "default-src 'none'; style-src 'self' 'unsafe-inline'; font-src 'self'";
  return '<meta http-equiv="Content-Security-Policy" content="' + p + '">';
}
function stripBom(s) { return s.charCodeAt(0) === 0xFEFF ? s.slice(1) : s; }
// Kept so the theme toggle can re-issue the current document with a different
// theme (setTheme). Cleared whenever the viewer stops showing a srcdoc.
var lastSrcdoc = null;
function commitSrcdoc(srcdoc) {
  showViewer();
  sandboxViewer();
  if (viewer.hasAttribute('src')) viewer.removeAttribute('src');
  lastSrcdoc = srcdoc;
  viewer.srcdoc = srcdoc;
}
// The single source of truth for the srcdoc skeleton — doctype+theme+CSP(kind)+
// tokens CSS in one place. headExtra = additional <link> tags.
function docShell(cspKind, headExtra, styleCss, bodyHtml) {
  return '<!doctype html><html data-theme="' + theme + '"><head><meta charset="utf-8">' + cspMeta(cspKind) +
    '<link rel="stylesheet" href="/assets/airlock-tokens.css">' +
    '<link rel="stylesheet" href="/__fv/tokens.css">' + (headExtra || '') +
    '<style>' + styleCss + '</style></head><body>' + bodyHtml + '</body></html>';
}

// shared srcdoc for notices/errors (sandbox + CSP)
function renderNoticeSrcdoc(inner) {
  commitSrcdoc(docShell('text', '',
    'html,body{margin:0;padding:0;max-width:none;}' +
    'body{background:var(--bg);color:var(--text);font-family:var(--font-sans);}' +
    '.notice{max-width:640px;margin:12vh auto;text-align:center;color:var(--text-muted);padding:0 var(--sp-6);}' +
    '.notice h2{color:var(--text);font-size:var(--fs-lg);font-weight:var(--fw-semibold);}' +
    '.notice code{background:var(--code-bg);padding:2px 8px;border-radius:var(--r-sm);color:var(--text);font-family:var(--font-mono);}',
    '<div class="notice">' + inner + '</div>'));
}
function renderDownloadNotice(path, bytes, reason) {
  var fname = escapeHTML(path.split('/').pop());
  var sizeStr = bytes ? ' <code>' + (bytes / 1024 / 1024).toFixed(1) + ' MB</code>' : '';
  renderNoticeSrcdoc('<h2>' + escapeHTML(reason) + '</h2>' +
    '<p><code>' + fname + '</code>' + sizeStr + ' is not previewed.</p>' +
    '<p>Use the <strong>Download</strong> button in the top bar.</p>');
}
function renderErrorInViewer(msg) {
  renderNoticeSrcdoc('<h2>Load failed</h2><p><code>' + escapeHTML(msg) + '</code></p>');
}

// ---- image / audio / video (raw API url + cookie, parent pane) ----
// Built with DOM calls, not an HTML string: the only untrusted input here is the
// file name, and createTextNode/setAttribute cannot be escaped out of.
function renderMediaInViewer(path, kind) {
  var url = apiUrl('raw', path, 'inline=true');   // may throw -> caught by openFile
  var wrap = document.createElement('div');
  wrap.className = 'media-wrap' + (kind === 'audio' ? ' audio' : '');
  var el;
  if (kind === 'img') {
    el = document.createElement('img');
    el.alt = path;
  } else if (kind === 'video') {
    el = document.createElement('video');
    el.controls = true; el.playsInline = true;
  } else {
    el = document.createElement('audio');
    el.controls = true;
  }
  el.src = url;
  el.addEventListener('error', function () { renderErrorInViewer('could not load ' + path); });
  wrap.appendChild(el);
  if (kind === 'audio') {
    var fn = document.createElement('div');
    fn.className = 'fname';
    fn.appendChild(document.createTextNode(path.split('/').pop()));
    wrap.appendChild(fn);
  }
  showPane(wrap);
}

// shared shell for text/structured views (bar + body). CSP(kind) + hljs theme link.
function viewerDoc(styleExtra, bodyHtml, cspKind) {
  return docShell(cspKind || 'text', '<link rel="stylesheet" href="/__fv/hljs-theme.css">',
    'html,body{margin:0;padding:0;max-width:none;}' +
    'body{padding:var(--sp-6) var(--sp-8);background:var(--bg);color:var(--text);font-family:var(--font-sans);}' +
    '.vbar{display:flex;align-items:center;gap:var(--sp-3);margin-bottom:var(--sp-4);padding-bottom:var(--sp-3);border-bottom:1px solid var(--border-muted);font-size:var(--fs-sm);color:var(--text-muted);}' +
    '.vbar .kind{text-transform:uppercase;letter-spacing:var(--track-caps);font-weight:var(--fw-semibold);color:var(--text);}' +
    '.vbar code{background:var(--code-bg);padding:2px 8px;border-radius:var(--r-sm);color:var(--text);}' +
    '.vbar .warn{color:var(--color-warning);font-weight:var(--fw-semibold);}' +
    styleExtra,
    bodyHtml);
}
function vbar(path, badge, warn) {
  return '<div class="vbar"><span class="kind">' + badge + '</span><code>' + escapeHTML(path) + '</code>' +
    (warn ? '<span class="warn">' + escapeHTML(warn) + '</span>' : '') +
    '<span style="flex:1"></span>' +
    '<span style="color:var(--text-muted)">Copy / Download in the top bar</span></div>';
}

// filebrowser raw fetch + guards (oversize/binary). Promise<string|null>.
// null = already handled (notice shown). maxBytes sets the per-type ceiling.
function fetchTextGuarded(path, maxBytes) {
  var cap = maxBytes || TEXT_MAX_BYTES;
  return getJwt().then(function (jwt) {
    return fetch(apiUrl('raw', path, 'algo=none'), { headers: { 'X-Auth': jwt } });
  }).then(function (r) {
    if (path !== currentPath) return null;   // another file opened meanwhile -> stale, suppress render/notice/error
    if (!r.ok) throw new Error('raw ' + r.status);
    var len = parseInt(r.headers.get('content-length') || '0', 10);
    if (len && len > cap) { renderDownloadNotice(path, len, 'File too large'); return null; }
    return readCapped(r, cap);
  }).then(function (res) {
    if (res == null) return null;
    if (path !== currentPath) return null;   // guard against a switch during the read
    if (res.overflow) { renderDownloadNotice(path, res.bytes, 'File too large'); return null; }
    var text = res.text;
    // binary sniff: a NUL byte within the first 8KB -> not text (defends unregistered binary extensions)
    if (text.slice(0, 8192).indexOf(String.fromCharCode(0)) !== -1) { renderDownloadNotice(path, null, 'Binary file'); return null; }
    return text;
  });
}

// Read a response body up to `cap` bytes and then STOP — cancel the stream rather
// than buffering it and measuring afterwards.
//
// This is not only about big files. With the tree rooted at `/`, a path like
// /dev/zero answers with no content-length and never ends: `r.text()` would grow
// until the tab died, and no size check placed after it can ever run. Streaming
// makes the cap real regardless of what the server claims or how the file was
// reached. Falls back to r.text() where streams are unavailable.
function readCapped(r, cap) {
  if (!r.body || !r.body.getReader) {
    return r.text().then(function (t) { return { text: t, bytes: t.length, overflow: t.length > cap }; });
  }
  var reader = r.body.getReader();
  var chunks = [], total = 0;
  return (function pump() {
    return reader.read().then(function (step) {
      if (step.done) return { text: new TextDecoder().decode(concatChunks(chunks, total)), bytes: total, overflow: false };
      total += step.value.length;
      if (total > cap) {
        reader.cancel();
        return { text: '', bytes: total, overflow: true };
      }
      chunks.push(step.value);
      return pump();
    });
  })();
}
function concatChunks(chunks, total) {
  var out = new Uint8Array(total), at = 0;
  for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], at); at += chunks[i].length; }
  return out;
}

// text/code render — the parent colours with hljs (skipped when large) -> static
// srcdoc. banner shows the fallback reason.
function renderCodeText(path, text, langOverride, banner) {
  var lang = langOverride || langByExt(path);
  var body = text;
  if (lang === 'json') {
    try { body = JSON.stringify(JSON.parse(stripBom(text)), null, 2); } catch (_) { body = text; }
  }
  var H = window.hljs;
  var codeHtml;
  if (H && lang && H.getLanguage(lang) && body.length <= HLJS_MAX_BYTES) {
    try { codeHtml = H.highlight(body, { language: lang, ignoreIllegals: true }).value; }
    catch (_) { codeHtml = escapeHTML(body); }
  } else {
    codeHtml = escapeHTML(body);   // unknown language / hljs not loaded / oversize -> plain
  }
  var badge = 'raw' + (lang ? ' <span style="color:var(--text-muted);text-transform:none;font-weight:400">' + escapeHTML(lang) + '</span>' : '');
  var style = 'pre{background:var(--code-bg);color:var(--text);padding:var(--sp-4);border-radius:var(--r-md);overflow:auto;font-family:var(--font-mono);font-size:var(--fs-md);line-height:var(--lh-normal);margin:0;}' +
    'pre code{background:transparent;padding:0;color:inherit;}';
  commitSrcdoc(viewerDoc(style, vbar(path, badge, banner) + '<pre><code class="hljs language-' + lang + '">' + codeHtml + '</code></pre>'));
}
// Original entry point (fetch + code render). Path for code / unknown text.
function renderRawInViewer(path) {
  return fetchTextGuarded(path).then(function (text) {
    if (text == null) return;
    renderCodeText(path, text, null, null);
  }).catch(function (e) { renderErrorInViewer(e.message); });
}

// ---- JSON collapsible tree (native <details>, zero scripts) ----
// The parent JSON.parses, then recurses into static tree HTML. On a node/depth/
// HTML overflow it falls back to raw text (never a partial tree).
function jtNode(label, value, depth, budget) {
  if (++budget.nodes > JSON_MAX_NODES) throw new Error('JSON_TOO_BIG');
  if (depth > JSON_MAX_DEPTH) throw new Error('JSON_TOO_DEEP');
  var lab = label != null ? '<span class="hljs-attr">"' + escapeHTML(label) + '"</span><span class="jt-pun">: </span>' : '';
  var t = typeof value;
  if (value === null) return '<div class="jt-row">' + lab + '<span class="hljs-keyword">null</span></div>';
  if (t === 'number' || t === 'boolean') return '<div class="jt-row">' + lab + '<span class="hljs-number">' + escapeHTML(String(value)) + '</span></div>';
  if (t === 'string') {
    var s = value.length > JSON_STR_CLAMP ? value.slice(0, JSON_STR_CLAMP) + '…(' + value.length + ')' : value;
    return '<div class="jt-row">' + lab + '<span class="hljs-string">"' + escapeHTML(s) + '"</span></div>';
  }
  var isArr = Array.isArray(value);
  var keys = isArr ? null : Object.keys(value);
  var count = isArr ? value.length : keys.length;
  var brO = isArr ? '[' : '{', brC = isArr ? ']' : '}';
  if (count === 0) return '<div class="jt-row">' + lab + '<span class="jt-pun">' + brO + brC + '</span></div>';
  var openAttr = depth < JSON_OPEN_DEPTH ? ' open' : '';
  var parts = ['<details class="jt-node"' + openAttr + '><summary>' + lab +
    '<span class="jt-pun">' + brO + '</span> <span class="jt-count">' + count + '</span> <span class="jt-pun">' + brC + '</span></summary><div class="jt-body">'];
  if (isArr) { for (var i = 0; i < count; i++) parts.push(jtNode(null, value[i], depth + 1, budget)); }
  else { for (var j = 0; j < count; j++) parts.push(jtNode(keys[j], value[keys[j]], depth + 1, budget)); }
  parts.push('</div></details>');
  return parts.join('');
}
function renderJson(path) {
  return fetchTextGuarded(path).then(function (text) {
    if (text == null) return;
    var clean = stripBom(text);
    var parsed;
    try { parsed = JSON.parse(clean); }
    catch (_) { renderCodeText(path, clean, 'json', 'JSON parse failed — showing raw'); return; }  // partial JSON / JSONL
    var treeHtml;
    try {
      treeHtml = jtNode(null, parsed, 0, { nodes: 0 });
      if (treeHtml.length > JSON_HTML_MAX) throw new Error('JSON_TOO_BIG');
    } catch (e) {
      renderCodeText(path, clean, 'json', 'Tree disabled (too large) — showing raw');   // no partial tree: full raw
      return;
    }
    var style = '.jt-body{margin-left:var(--sp-4);border-left:1px solid var(--border-muted);padding-left:var(--sp-3);}' +
      '.jt-node,.jt-row{font-family:var(--font-mono);font-size:var(--fs-md);line-height:var(--lh-loose);}' +
      '.jt-row{white-space:pre-wrap;word-break:break-word;}' +   /* preserve newlines inside string values */
      '.jt-node>summary{cursor:pointer;list-style:none;}' +
      '.jt-node>summary::-webkit-details-marker{display:none;}' +
      '.jt-node>summary::before{content:"";display:inline-block;width:5px;height:5px;margin:0 8px 1px 2px;border-right:1.5px solid var(--text-muted);border-bottom:1.5px solid var(--text-muted);border-radius:1px;transform:rotate(-45deg);transition:transform var(--dur-fast) var(--ease);}' +
      '.jt-node[open]>summary::before{transform:rotate(45deg);}' +
      '.jt-pun{color:var(--syn-pun,var(--text-muted));}' +
      '.jt-count{color:var(--text-muted);font-size:var(--fs-sm);}';
    commitSrcdoc(viewerDoc(style, vbar(path, 'json', null) + '<div class="jt-root">' + treeHtml + '</div>'));
  }).catch(function (e) { renderErrorInViewer(e.message); });
}

// ---- CSV/TSV table ----
// Hand-written RFC 4180 state machine — handles quoted delimiters/newlines, ""
// escapes, CRLF/lone CR, and trailing empty fields. Parses the whole file to get
// the total row count, but only stores up to maxRows/maxCells. No dynamic typing
// (raw values preserved).
function parseDelimited(text, delim, maxRows, maxCells) {
  var rows = [], row = [], field = '', inQ = false, total = 0, maxCols = 0, truncated = false, cells = 0;
  var i = 0, n = text.length;
  function endRow() {
    row.push(field); field = '';
    total++;
    if (row.length > maxCols) maxCols = row.length;
    if (rows.length < maxRows && cells + row.length <= maxCells) { rows.push(row); cells += row.length; }
    else { truncated = true; }
    row = [];
  }
  while (i < n) {
    var c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i += 2; continue; } inQ = false; i++; continue; }
      field += c; i++; continue;
    }
    if (c === '"') {
      if (field === '') { inQ = true; i++; continue; }   // a quote opens a quoted field only at the field start (RFC 4180)
      field += '"'; i++; continue;                        // a mid-field quote is a literal (avoids swallowing delimiters)
    }
    if (c === delim) { row.push(field); field = ''; i++; continue; }
    if (c === '\r') { if (text[i + 1] === '\n') i++; endRow(); i++; continue; }
    if (c === '\n') { endRow(); i++; continue; }
    field += c; i++;
  }
  if (field !== '' || row.length > 0) endRow();   // last row without a trailing newline
  return { rows: rows, total: total, cols: maxCols, truncated: truncated };
}
function sniffDelim(text) {
  var nl = text.indexOf('\n');
  var first = nl < 0 ? text : text.slice(0, nl);
  return (first.split(';').length > first.split(',').length) ? ';' : ',';
}
function renderCsv(path) {
  return fetchTextGuarded(path).then(function (text) {
    if (text == null) return;
    var clean = stripBom(text);
    var ext = extOf(path.split('/').pop());
    var delim = ext === 'tsv' ? '\t' : sniffDelim(clean);
    var res;
    try { res = parseDelimited(clean, delim, CSV_MAX_ROWS, CSV_MAX_CELLS); }
    catch (_) { renderCodeText(path, clean, null, 'CSV parse failed — showing raw'); return; }
    if (res.rows.length === 0) { renderCodeText(path, clean, null, 'Empty table — showing raw'); return; }
    if (res.cols > CSV_MAX_COLS) { renderCodeText(path, clean, null, 'Too many columns (' + res.cols + ') — showing raw'); return; }
    function cell(c) {
      var v = c.length > CSV_CELL_CLAMP ? c.slice(0, CSV_CELL_CLAMP) + '…' : c;
      return escapeHTML(v);
    }
    var head = res.rows[0].map(function (c) { return '<th>' + cell(c) + '</th>'; }).join('');
    var bodyRows = [];
    for (var r = 1; r < res.rows.length; r++) {
      bodyRows.push('<tr>' + res.rows[r].map(function (c) { return '<td>' + cell(c) + '</td>'; }).join('') + '</tr>');
    }
    var banner = res.truncated ? ('Showing ' + res.rows.length + ' of ' + res.total + ' rows — download for all') : null;
    var style = '.tbl-wrap{overflow:auto;max-width:100%;border:1px solid var(--border-muted);border-radius:var(--r-md);}' +
      'table{border-collapse:collapse;font-family:var(--font-mono);font-size:var(--fs-sm);white-space:pre;}' +
      'th,td{padding:4px var(--sp-3);border-right:1px solid var(--border-muted);border-bottom:1px solid var(--border-muted);text-align:left;vertical-align:top;}' +
      'thead th{position:sticky;top:0;background:var(--chrome);color:var(--text);font-weight:var(--fw-semibold);z-index:1;}' +
      'tbody tr:nth-child(even){background:var(--code-bg);}';
    var tableHtml = '<div class="tbl-wrap"><table><thead><tr>' + head + '</tr></thead><tbody>' + bodyRows.join('') + '</tbody></table></div>';
    commitSrcdoc(viewerDoc(style, vbar(path, escapeHTML(ext), banner) + tableHtml));
  }).catch(function (e) { renderErrorInViewer(e.message); });
}

// ---- Jupyter notebook (.ipynb) render (nbformat v4, parent-parsed -> static srcdoc, sandbox="" + CSP img-src data:) ----
var IPYNB_MAX_BYTES = 20 * 1024 * 1024;
var IPYNB_MAX_CELLS = 300, IPYNB_MAX_OUTPUTS = 20;
var IPYNB_TEXT_CLAMP = 64 * 1024, IPYNB_HTML_IN = 256 * 1024, IPYNB_HTML_OUT = 512 * 1024;
var IPYNB_IMG_MAX = 3 * 1024 * 1024, IPYNB_IMG_GLOBAL = 12 * 1024 * 1024, IPYNB_IMG_COUNT = 100;
var IPYNB_HTML_TOTAL = 16 * 1024 * 1024;

function joinSrc(s) { return Array.isArray(s) ? s.join('') : (s == null ? '' : String(s)); }
// Strip ANSI/OSC/control sequences (no colour conversion — Pike). ESC=27 is built
// via fromCharCode so no literal control char is typed into the source.
function stripAnsi(s) {
  var ESC = String.fromCharCode(27), BEL = String.fromCharCode(7), CSI8 = String.fromCharCode(0x9b);
  return s.replace(new RegExp('(?:' + ESC + '\\[|' + CSI8 + ')[0-9:;<=>?]*[ -/]*[@-~]', 'g'), '')  // CSI (7/8-bit) — full ECMA-48 parameter bytes (colon-form SGR included)
          .replace(new RegExp(ESC + '\\][^' + BEL + ESC + ']*(' + BEL + '|' + ESC + '\\\\)?', 'g'), '')  // OSC … BEL/ST
          .replace(new RegExp(ESC + '[ -/]*[0-~]', 'g'), '')  // nF escape sequences (charset select ESC(B etc.)
          .replace(new RegExp(ESC, 'g'), '');                 // leftover ESC
}
function clampText(s, cap) { return s.length > cap ? s.slice(0, cap) + '\n…(' + s.length + ' chars, truncated)' : s; }
function preBlock(s, cls) { return '<pre class="nb-out ' + (cls || '') + '">' + escapeHTML(s) + '</pre>'; }

function hlCode(src, lang) {
  var H = window.hljs;
  if (H && lang && H.getLanguage(lang) && src.length <= HLJS_MAX_BYTES) {
    try { return H.highlight(src, { language: lang, ignoreIllegals: true }).value; } catch (_) {}
  }
  return escapeHTML(src);
}
// Strict DOMPurify profile — img/meta/link/style/svg/… FORBID (blocks image-guard
// bypass). Returns null when DOMPurify is not loaded.
function sanitizeHtml(html) {
  var DP = window.DOMPurify;
  if (!DP) return null;
  return DP.sanitize(html, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ['style', 'svg', 'math', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'video', 'audio', 'img', 'meta', 'link'],
    FORBID_ATTR: ['style', 'srcset'],
    ALLOW_DATA_ATTR: false
  });
}
function renderMdCell(src) {
  var M = window.marked;
  if (M && window.DOMPurify) {
    try {
      var html = (typeof M.parse === 'function') ? M.parse(src) : M(src);
      var safe = sanitizeHtml(html);
      if (safe != null) return '<div class="nb-md">' + safe + '</div>';
    } catch (_) {}
  }
  return preBlock(src, 'nb-mdsrc');   // marked/DOMPurify not loaded/failed -> source fallback
}
// One output: branch on output_type -> for data bundles, pick one representation
// by priority (png>jpeg>html>plain>json). Unknown MIME = a badge.
function renderOutput(out, budget) {
  var ot = out.output_type;
  if (ot === 'stream') return preBlock(clampText(stripAnsi(joinSrc(out.text)), IPYNB_TEXT_CLAMP), out.name === 'stderr' ? 'nb-stderr' : '');
  if (ot === 'error') {
    var tb = clampText(stripAnsi(joinSrc(out.traceback)), IPYNB_TEXT_CLAMP);
    if (!tb) tb = (out.ename || '') + ': ' + (out.evalue || '');
    return preBlock(tb, 'nb-error');
  }
  if (ot === 'execute_result' || ot === 'display_data') {
    var data = out.data || {};
    if (data['image/png'] || data['image/jpeg']) {
      var mime = data['image/png'] ? 'image/png' : 'image/jpeg';
      var b64 = joinSrc(data[mime]).replace(/\s+/g, '');
      if (budget.imgCount >= IPYNB_IMG_COUNT || b64.length > IPYNB_IMG_MAX || budget.imgBytes + b64.length > IPYNB_IMG_GLOBAL) {
        return '<div class="nb-badge">Image omitted (size/count limit)</div>';
      }
      budget.imgCount++; budget.imgBytes += b64.length;
      return '<div class="nb-img"><img src="data:' + mime + ';base64,' + b64 + '" alt="output"></div>';
    }
    if (data['text/html']) {
      var safe = sanitizeHtml(clampText(joinSrc(data['text/html']), IPYNB_HTML_IN));
      if (safe == null) return '<div class="nb-badge warn">HTML output not shown — the sanitizer did not load</div>';
      return '<div class="nb-html">' + safe.slice(0, IPYNB_HTML_OUT) + '</div>';
    }
    if (data['text/plain']) return preBlock(clampText(joinSrc(data['text/plain']), IPYNB_TEXT_CLAMP), '');
    if (data['application/json']) {
      var j = joinSrc(data['application/json']);
      try { j = JSON.stringify(JSON.parse(j), null, 2); } catch (_) {}
      return preBlock(clampText(j, IPYNB_TEXT_CLAMP), '');
    }
    return '<div class="nb-badge">Unsupported MIME: ' + escapeHTML(Object.keys(data).join(', ')) + '</div>';
  }
  return '';   // unknown output_type
}
function nbStyle() {
  return '.nb{max-width:960px;}' +
    '.nb-cell{margin:0 0 var(--sp-4);border:1px solid var(--border-muted);border-radius:var(--r-md);overflow:hidden;}' +
    ':root{--nb-plate:#ffffff;}' +   /* matplotlib draws on white; keep the plate under it in both themes */
    '.nb-cell-md{padding:var(--sp-3) var(--sp-5);}' +
    '.nb-md{line-height:var(--lh-normal);} .nb-md h1,.nb-md h2,.nb-md h3{margin:var(--sp-3) 0;} .nb-md code{background:var(--code-bg);padding:1px 5px;border-radius:var(--r-sm);}' +
    '.nb-in{display:flex;gap:var(--sp-2);align-items:flex-start;background:var(--code-bg);}' +
    '.nb-prompt{flex:0 0 auto;padding:var(--sp-3) var(--sp-2);color:var(--text-muted);font-family:var(--font-mono);font-size:var(--fs-sm);user-select:none;}' +
    '.nb-src{flex:1 1 auto;margin:0;padding:var(--sp-3) var(--sp-4);overflow:auto;font-family:var(--font-mono);font-size:var(--fs-md);line-height:var(--lh-normal);}' +
    '.nb-src code{background:transparent;} .nb-outputs{padding:var(--sp-2) var(--sp-4);border-top:1px solid var(--border-muted);}' +
    '.nb-out{margin:var(--sp-2) 0;white-space:pre-wrap;font-family:var(--font-mono);font-size:var(--fs-sm);}' +
    '.nb-stderr{color:var(--text);border-left:2px solid var(--color-warning);padding-left:var(--sp-2);}' +
    '.nb-error{color:var(--color-danger);}' +
    '.nb-img img{max-width:100%;height:auto;border-radius:var(--r-sm);background:var(--nb-plate);} .nb-html{overflow:auto;}' +
    '.nb-html table{border-collapse:collapse;} .nb-html th,.nb-html td{border:1px solid var(--border-muted);padding:2px 6px;}' +
    '.nb-badge{display:inline-block;margin:var(--sp-2) 0;padding:2px 10px;border-radius:var(--r-pill);background:var(--code-bg);color:var(--text-muted);font-size:var(--fs-sm);}' +
    '.nb-badge.warn{color:var(--text);}' +
    '.nb-badge.warn::before{content:"";display:inline-block;width:6px;height:6px;border-radius:50%;margin-right:6px;background:var(--color-warning);}';
}
function renderIpynb(path) {
  return fetchTextGuarded(path, IPYNB_MAX_BYTES).then(function (text) {
    if (text == null) return;
    var clean = stripBom(text), nb;
    try { nb = JSON.parse(clean); }
    catch (_) { renderCodeText(path, clean, 'json', 'ipynb parse failed — showing raw'); return; }
    if (rawOverride) { renderCodeText(path, clean, 'json', null); return; }          // Raw toggle -> raw JSON
    if (!nb || typeof nb !== 'object' || !Array.isArray(nb.cells)) { renderCodeText(path, clean, 'json', 'Not a cells structure — showing raw'); return; }
    if ((nb.nbformat || 0) < 4) { renderCodeText(path, clean, 'json', 'nbformat v' + (nb.nbformat || '?') + ' unsupported (v4 only) — showing raw'); return; }
    var lang = (nb.metadata && nb.metadata.kernelspec && nb.metadata.kernelspec.language) ||
               (nb.metadata && nb.metadata.language_info && nb.metadata.language_info.name) || 'python';
    var budget = { imgCount: 0, imgBytes: 0 };
    var cells = nb.cells, shown = Math.min(cells.length, IPYNB_MAX_CELLS), parts = [], htmlLen = 0;
    for (var i = 0; i < shown; i++) {
      var cell = cells[i], srcTxt = joinSrc(cell.source), sec;
      if (cell.cell_type === 'markdown') {
        sec = '<section class="nb-cell nb-cell-md">' + renderMdCell(srcTxt) + '</section>';
      } else if (cell.cell_type === 'code') {
        var ec = (cell.execution_count != null) ? cell.execution_count : ' ';
        var outs = Array.isArray(cell.outputs) ? cell.outputs.slice(0, IPYNB_MAX_OUTPUTS) : [];
        var outHtml = '';
        for (var o = 0; o < outs.length; o++) outHtml += renderOutput(outs[o], budget);
        if (Array.isArray(cell.outputs) && cell.outputs.length > IPYNB_MAX_OUTPUTS) {
          outHtml += '<div class="nb-badge">' + (cell.outputs.length - IPYNB_MAX_OUTPUTS) + ' outputs omitted</div>';
        }
        sec = '<section class="nb-cell nb-cell-code">' +
          '<div class="nb-in"><span class="nb-prompt">[' + escapeHTML(String(ec)) + ']:</span>' +
          '<pre class="nb-src"><code class="hljs">' + hlCode(srcTxt, lang) + '</code></pre></div>' +
          (outHtml ? '<div class="nb-outputs">' + outHtml + '</div>' : '') + '</section>';
      } else {
        sec = '<section class="nb-cell nb-cell-raw">' + preBlock(srcTxt, 'nb-mdsrc') + '</section>';
      }
      parts.push(sec);
      htmlLen += sec.length;
      if (htmlLen > IPYNB_HTML_TOTAL) { shown = i + 1; break; }   // total-HTML hard stop (running counter = O(n))
    }
    var banner = shown < cells.length ? ('Showing ' + shown + '/' + cells.length + ' cells — rest truncated') : null;
    commitSrcdoc(viewerDoc(nbStyle(), vbar(path, 'ipynb <span style="color:var(--text-muted);text-transform:none;font-weight:400">' + escapeHTML(lang) + '</span>', banner) + '<div class="nb">' + parts.join('') + '</div>', 'ipynb'));
  }).catch(function (e) { renderErrorInViewer(e.message); });
}

// text-transport dispatch (honours the Raw toggle). When rawOverride, always code text.
// ================= MARKDOWN (client-side) =================
// marked passes raw HTML through by design, so DOMPurify is not defence in depth
// here — it is the only defence. Order matters: sanitize first, then rewrite, so
// the rewrite pass only ever walks nodes that survived. The fragment is rewritten
// while still detached, so no <img> ever requests the pre-rewrite URL.
var MD_MAX_BYTES = 2 * 1024 * 1024;
function sanitizeMarkdownDoc(html) {
  var DP = window.DOMPurify;
  if (!DP) return null;
  return DP.sanitize(html, {
    USE_PROFILES: { html: true },
    // svg/math: not needed by markdown and historically the awkward corners.
    // style/link/meta/base: would restyle or re-point the whole app, which is the
    //   parent document now — the srcdoc's CSP used to make that moot.
    // iframe/object/embed: no embedding from file content.
    // form: an <input> without a form cannot submit anywhere (task lists need input).
    // video/audio/source/track/picture: they issue their OWN outbound request as
    // soon as they are inserted, and the rewrite pass below only walks img/a — so
    // a file could beacon out to an arbitrary host just by being previewed. Media
    // FILES still play; they open through the tree, which builds their URL.
    FORBID_TAGS: ['style', 'svg', 'math', 'iframe', 'object', 'embed', 'form', 'meta', 'link', 'base',
                  'video', 'audio', 'source', 'track', 'picture'],
    // srcset would smuggle a second image URL past the src rewrite below.
    FORBID_ATTR: ['style', 'srcset'],
    ALLOW_DATA_ATTR: false,
    RETURN_DOM_FRAGMENT: true
  });
}
// GitHub-style heading slug. marked v15 emits no heading ids at all (headerIds
// left the core), and the anchor/deep-link behaviour used to ride on markserv's.
function slugify(text, used) {
  var base = String(text).toLowerCase().trim()
    .replace(/[\u2000-\u206f\u2e00-\u2e7f'"!-\/:-@\[-`{-~]/g, '')
    .replace(/\s+/g, '-');
  if (!base) base = 'section';
  var slug = base, n = 0;
  while (used[slug]) { n++; slug = base + '-' + n; }
  used[slug] = true;
  return slug;
}
// Resolve a document-relative reference against the directory of `fromPath`.
// Returns an absolute path in filebrowser's namespace, or null if it escapes it.
function resolveRelPath(fromPath, ref) {
  var base = ref.charAt(0) === '/' ? [] : fromPath.replace(/\/[^/]*$/, '').split('/');
  var out = [];
  var parts = base.concat(ref.split('/'));
  for (var i = 0; i < parts.length; i++) {
    var seg = parts[i];
    if (seg === '' || seg === '.') continue;
    if (seg === '..') { if (!out.length) return null; out.pop(); continue; }
    out.push(seg);
  }
  return '/' + out.join('/');
}
function isExternalHref(href) { return /^[a-z][a-z0-9+.-]*:/i.test(href) || href.indexOf('//') === 0; }

function renderMarkdown(path) {
  return fetchTextGuarded(path, MD_MAX_BYTES).then(function (text) {
    if (rawOverride) return renderCodeText(path, text, 'markdown', null);
    var M = window.marked;
    if (!M || !window.DOMPurify) return renderCodeText(path, text, 'markdown', 'renderer not loaded — showing source');
    // breaks:true reproduces markserv's renderer. It is load-bearing, not taste:
    // a GFM callout marker has to end up alone in its own text node for
    // applyAlerts to recognise it, which is also why enhance.js stripped the
    // leading <br> the same setting produces.
    var frag;
    try {
      var html = (typeof M.parse === 'function') ? M.parse(text, { gfm: true, breaks: true }) : M(text);
      frag = sanitizeMarkdownDoc(html);
    } catch (e) {
      return renderCodeText(path, text, 'markdown', 'render failed (' + e.message + ') — showing source');
    }
    if (!frag) return renderCodeText(path, text, 'markdown', 'sanitizer not loaded — showing source');
    rewriteMarkdownRefs(frag, path);
    var used = {};
    var hs = frag.querySelectorAll('h1,h2,h3,h4,h5,h6');
    for (var i = 0; i < hs.length; i++) hs[i].id = slugify(hs[i].textContent, used);
    highlightCodeBlocks(frag);
    var wrap = document.createElement('div');
    wrap.className = 'markdown-viewer';
    wrap.appendChild(frag);
    applyAlerts(wrap);
    applyAnchors(wrap);
    showPane(wrap);
    // Scroll now, and again once the images have settled: a deep link resolved
    // before the images have their box lands short, because every image that
    // loads afterwards pushes the target further down.
    scrollToHash();
    afterImagesSettle(wrap, scrollToHash);
  }).catch(function (e) { renderErrorInViewer(e.message); });
}
// src/href rewriting. Relative refs used to resolve against markserv's own URL;
// now they resolve against the raw API, and in-tree links drive the tree instead
// of navigating the app away.
function rewriteMarkdownRefs(frag, path) {
  var imgs = frag.querySelectorAll('img[src]');
  for (var i = 0; i < imgs.length; i++) {
    var src = imgs[i].getAttribute('src');
    if (!src || src.indexOf('data:') === 0 || isExternalHref(src)) continue;
    var abs = resolveRelPath(path, src);
    if (abs == null) { imgs[i].removeAttribute('src'); continue; }
    try { imgs[i].setAttribute('src', apiUrl('raw', abs, 'inline=true')); }
    catch (_) { imgs[i].removeAttribute('src'); }
  }
  var as = frag.querySelectorAll('a[href]');
  for (var j = 0; j < as.length; j++) {
    var a = as[j], href = a.getAttribute('href');
    if (!href) continue;
    if (href.charAt(0) === '#') {
      a.addEventListener('click', hashLinkHandler(href.slice(1)));
      continue;
    }
    if (isExternalHref(href)) { a.target = '_blank'; a.rel = 'noopener noreferrer'; continue; }
    var hashPart = href.split('#')[1] || '';
    var target = resolveRelPath(path, href.split('#')[0]);
    if (target == null) { a.removeAttribute('href'); continue; }
    a.href = '?path=' + encodeURIComponent(target) + (hashPart ? '#' + hashPart : '');
    a.addEventListener('click', treeLinkHandler(target, hashPart));
  }
}
function hashLinkHandler(id) {
  return function (ev) {
    ev.preventDefault();
    pendingHash = id;
    scrollToId(id);
    history.replaceState(null, '', location.pathname + location.search.split('#')[0] + '#' + id);
  };
}
function treeLinkHandler(target, hash) {
  return function (ev) {
    if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.button) return;   // let a new tab be a new tab
    ev.preventDefault();
    expandPathChain(target).then(function () { openFile(target, hash); });
  };
}
// No selector string: an id is attacker-shaped text (it comes from a heading),
// and cssEscape only handles quotes and backslashes — an id containing a newline
// made querySelector throw a SyntaxError and took the page with it.
function scrollToId(id) {
  if (!id) return;
  var all = pane.querySelectorAll('[id]');
  for (var i = 0; i < all.length; i++) {
    if (all[i].id === id) { all[i].scrollIntoView({ block: 'start' }); return; }
  }
}
// The fragment this navigation asked for. It cannot be read back off location at
// render time: openFile's own replaceState rewrites the URL to ?path=... and drops
// the hash long before the (async) render finishes.
var pendingHash = '';
function scrollToHash() { if (pendingHash) scrollToId(pendingHash); }
// Call back once every image in `scope` has loaded or failed. Capped, so one
// never-answering request cannot leave the callback unfired.
function afterImagesSettle(scope, fn) {
  var imgs = scope.querySelectorAll('img');
  var pending = 0, done = false;
  function finish() { if (!done) { done = true; fn(); } }
  for (var i = 0; i < imgs.length; i++) {
    if (imgs[i].complete) continue;
    pending++;
    var settle = function () { if (--pending === 0) finish(); };
    imgs[i].addEventListener('load', settle, { once: true });
    imgs[i].addEventListener('error', settle, { once: true });
  }
  if (!pending) return finish();
  setTimeout(finish, 2000);
}
function highlightCodeBlocks(frag) {
  var H = window.hljs;
  if (!H) return;
  var blocks = frag.querySelectorAll('pre > code');
  for (var i = 0; i < blocks.length; i++) {
    var code = blocks[i];
    var m = (code.className || '').match(/language-([\w-]+)/);
    var src = code.textContent;
    if (!m || src.length > HLJS_MAX_BYTES || !H.getLanguage(m[1])) continue;
    try { code.innerHTML = H.highlight(src, { language: m[1], ignoreIllegals: true }).value; } catch (_) {}
  }
}
// Ported from fileview-enhance.js, which ran inside the markserv page.
var ALERT_RE = /^\s*\[!(NOTE|TIP|WARNING|CAUTION|IMPORTANT)\]\s*$/;
function applyAlerts(scope) {
  var quotes = scope.querySelectorAll('blockquote');
  for (var i = 0; i < quotes.length; i++) {
    var bq = quotes[i], firstP = bq.querySelector('p');
    if (!firstP) continue;
    var firstLine = firstP.firstChild;
    if (!firstLine || firstLine.nodeType !== 3) continue;
    var m = firstLine.nodeValue.match(ALERT_RE);
    if (!m) continue;
    var kind = m[1].toLowerCase();
    bq.classList.add('fileview-alert', 'alert-' + kind);
    firstLine.nodeValue = '';
    var title = document.createElement('div');
    title.className = 'fileview-alert-title';
    title.textContent = kind.toUpperCase();
    bq.insertBefore(title, firstP);
    // Drop the <br> the marker's own line break produced. enhance.js looked at
    // firstChild only, which is the now-emptied text node, so the <br> survived
    // and left a blank first line inside every callout.
    var n = firstP.firstChild;
    while (n && n.nodeType === 3 && n.nodeValue === '') n = n.nextSibling;
    if (n && n.nodeName === 'BR') firstP.removeChild(n);
  }
}
function applyAnchors(scope) {
  var hs = scope.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]');
  for (var i = 0; i < hs.length; i++) {
    var h = hs[i], a = document.createElement('a');
    a.className = 'fileview-anchor';
    a.href = '#' + h.id;
    a.textContent = '#';
    a.title = 'Copy link to this heading';
    a.addEventListener('click', (function (id) {
      return function (ev) {
        ev.preventDefault();
        var url = location.origin + location.pathname + location.search + '#' + id;
        if (navigator.clipboard) navigator.clipboard.writeText(url).then(function () { showToast('Copied heading link'); }, function () {});
        history.replaceState(null, '', '#' + id);
      };
    })(h.id));
    h.appendChild(a);
  }
}

function renderStructured(path, view) {
  if (view === 'md') return renderMarkdown(path);   // rawOverride handled inside renderMarkdown
  if (view === 'ipynb') return renderIpynb(path);   // rawOverride handled inside renderIpynb
  if (!rawOverride && view === 'json') return renderJson(path);
  if (!rawOverride && view === 'csv') return renderCsv(path);
  return renderRawInViewer(path);
}

function openFile(path, hash) {
  pendingHash = hash || '';
  currentPath = path;
  currentMd = path;  // every file is editable (dotfiles like .env included)
  var d = descriptorFor(path);
  currentView = d.v;
  rawOverride = false;
  var structured = (d.t === 'text' && (d.v === 'json' || d.v === 'csv' || d.v === 'ipynb'));
  rawToggleBtn.hidden = !structured;
  setIcon(rawToggleBtn, 'raw', 'Show the raw text instead', 'Raw text');
  try {
    if (d.t === 'url' && d.v === 'pdf') {
      // the browser's own PDF viewer. A real (non-srcdoc) same-origin src, so the
      // auth cookie is sent; ?inline=true or filebrowser answers with
      // Content-Disposition: attachment and the browser downloads instead.
      showViewer();
      unsandboxViewer();
      if (viewer.hasAttribute('srcdoc')) viewer.removeAttribute('srcdoc');
      lastSrcdoc = null;   // the browser's PDF viewer, not a document we wrote
      viewer.src = apiUrl('raw', path, 'inline=true');
    } else if (d.t === 'url') {
      renderMediaInViewer(path, d.v);         // image/audio/video (sandbox srcdoc)
    } else {
      renderStructured(path, d.v);            // text/code/json/csv + guards (sandbox srcdoc)
    }
  } catch (e) {
    renderErrorInViewer(e.message);
  }
  inEditMode = false;
  savedContent = null;
  editorEl = null;
  updateBarPath(path, false, true);
  updateMtime(path);
  highlightActive(path);
  history.replaceState(null, '', '?path=' + encodeURIComponent(path) + (pendingHash ? '#' + pendingHash : ''));
}

// Show the last-modified time (fb api/resources/<path> .modified).
function updateMtime(path) {
  mtimeEl.textContent = '';
  if (!path || path === '/') return;
  getJwt().then(function (jwt) {
    return fetch(apiUrl('resources', path), { headers: { 'X-Auth': jwt } });
  }).then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      if (!d || !d.modified) return;
      var dt = new Date(d.modified);
      if (isNaN(dt)) return;
      var now = new Date();
      var diffMs = now - dt;
      var diffMin = Math.floor(diffMs / 60000);
      var label;
      if (diffMin < 1) label = 'just now';
      else if (diffMin < 60) label = diffMin + 'm ago';
      else if (diffMin < 60*24) label = Math.floor(diffMin/60) + 'h ago';
      else if (diffMin < 60*24*7) label = Math.floor(diffMin/(60*24)) + 'd ago';
      else label = dt.toISOString().slice(0,10);
      mtimeEl.textContent = label;
      mtimeEl.title = 'Last modified: ' + dt.toLocaleString();
    }).catch(function () {});
}
// ---- EDITOR (a textarea in this document) ----
// It used to be filebrowser's own ace editor in an iframe, read across frames via
// win.ace.edit(...). That cost a sandbox removal, a 1 s dirty poll, an nginx
// sub_filter injection, and a "use the editor's own Ctrl+S" fallback for when the
// reach-across failed — and it broke outright whenever filebrowser changed its
// editor. A textarea has none of that: the value is simply here.
var editorEl = null;
function openEditor(path) {
  currentPath = path;
  currentMd = path;
  rawToggleBtn.hidden = true;   // no structured/raw toggle in edit mode
  inEditMode = true;
  savedContent = null;
  var ta = document.createElement('textarea');
  ta.id = 'ms-editor';
  ta.spellcheck = false;
  ta.setAttribute('aria-label', 'File contents');
  ta.value = 'Loading…';
  ta.disabled = true;
  editorEl = ta;
  showPane(ta);
  updateBarPath(path, true, true);
  updateMtime(path);
  highlightActive(path);
  history.replaceState(null, '', '?path=' + encodeURIComponent(path));
  return fetchTextGuarded(path).then(function (text) {
    if (path !== currentPath || !inEditMode) return;   // moved on while loading
    ta.value = text;
    ta.disabled = false;
    savedContent = text;
    ta.addEventListener('input', markDirty);
    ta.addEventListener('keydown', editorTabKey);
    ta.focus();
  }).catch(function (e) {
    if (path !== currentPath) return;
    inEditMode = false;
    renderErrorInViewer(e.message);
    updateBarPath(path, false, true);
  });
}
// Tab inserts a tab instead of leaving the field. Without this, editing anything
// indented means reaching for the mouse after every line.
function editorTabKey(ev) {
  if (ev.key !== 'Tab' || ev.ctrlKey || ev.metaKey || ev.altKey) return;
  ev.preventDefault();
  var ta = ev.target, a = ta.selectionStart, b = ta.selectionEnd;
  ta.value = ta.value.slice(0, a) + '\t' + ta.value.slice(b);
  ta.selectionStart = ta.selectionEnd = a + 1;
  markDirty();
}
function getEditorValue() { return editorEl ? editorEl.value : null; }
function isDirty() {
  if (!inEditMode || savedContent == null) return false;
  var cur = getEditorValue();
  return cur != null && cur !== savedContent;
}
function markDirty() {
  if (!saveBtn) return;
  if (isDirty()) saveBtn.classList.add('dirty');
  else saveBtn.classList.remove('dirty');
}
function triggerSave() {
  if (!inEditMode) return Promise.resolve(false);
  var cur = getEditorValue();
  if (cur == null) return Promise.resolve(false);
  var target = currentPath;
  return getJwt().then(function (jwt) {
    return fetch(apiUrl('resources', target), {
      method: 'PUT',
      headers: { 'X-Auth': jwt, 'content-type': 'text/plain' },
      body: cur
    });
  }).then(function (r) {
    if (r.ok) {
      if (target === currentPath) { savedContent = cur; markDirty(); }
      showToast('Saved');
      updateMtime(target);
      return true;
    }
    showToast('Save failed: ' + r.status);
    return false;
  }).catch(function (e) {
    showToast('Save error: ' + e.message);
    return false;
  });
}
// Closing the tab with unsaved changes is the one exit the in-app guard cannot see.
window.addEventListener('beforeunload', function (ev) {
  if (!isDirty()) return;
  ev.preventDefault();
  ev.returnValue = '';
});

// Is this path a file? The listing already answered that — the tree row carries
// data-isdir — so ask it rather than guess from the name.
//
// The guess was a regex for "has an extension, or starts with a dot", and it got
// the answer backwards in both directions: `LICENSE` and `Makefile` are ordinary
// files with no extension, and it disabled Edit, Copy and Download on them, while
// `.bashrc` matched the dotfile clause and worked. A directory called `release.v1`
// matched too. Extensionless files being treated worse than dotfiles is the exact
// inequality this app exists to not have.
function pathIsFile(path) {
  if (!path || path === '/') return false;
  var node = tree.querySelector('.ms-node[data-path="' + cssEscape(path) + '"]');
  if (node) return node.dataset.isdir !== '1';
  return null;   // not painted yet — the caller knows, or has to ask the API
}
function updateBarPath(path, isEdit, known) {
  pathEl.textContent = path || '/';
  var isFile = known;
  if (isFile == null) isFile = pathIsFile(path);
  if (isFile) {
    editBtn.disabled = false;
    copyBtn.disabled = false;
    dlBtn.disabled = false;
    dlBtn.title = 'Download ' + path.split('/').pop();
    copyBtn.title = 'Copy contents to clipboard';
    if (isEdit) {
      setIcon(editBtn, 'view', 'Stop editing and go back to the viewer',
        'Back to the viewer (warns if there are unsaved changes)');
      editBtn.setAttribute('aria-pressed', 'true');
      saveBtn.hidden = false;
    } else {
      setIcon(editBtn, 'edit', 'Edit this file', 'Edit in the right pane');
      editBtn.setAttribute('aria-pressed', 'false');
      saveBtn.hidden = true;
      saveBtn.classList.remove('dirty');
    }
  } else {
    editBtn.disabled = true;
    copyBtn.disabled = true;
    dlBtn.disabled = true;
    setIcon(editBtn, 'edit', 'Edit this file', 'Select a file to enable');
    editBtn.setAttribute('aria-pressed', 'false');
    saveBtn.hidden = true;
  }
}

// Copy / Download wiring (any file — .md/.json/.env/.gitignore, etc.)
function fetchCurrentRaw() {
  if (!currentPath || currentPath === '/') return Promise.resolve(null);
  return getJwt().then(function (jwt) {
    return fetch(apiUrl('raw', currentPath, 'algo=none'), { headers: { 'X-Auth': jwt } });
  }).then(function (r) { return r.ok ? r.text() : null; });
}
copyBtn.addEventListener('click', function () {
  if (copyBtn.disabled) return;
  fetchCurrentRaw().then(function (text) {
    if (text == null) { showToast('Copy failed'); return; }
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text)
        .then(function () { showToast('Copied content (' + text.length + ' chars)'); })
        .catch(function () { showToast('Clipboard permission denied'); });
    } else {
      showToast('Clipboard API unavailable');
    }
  });
});
dlBtn.addEventListener('click', function () {
  if (dlBtn.disabled || !currentPath) return;
  // The JWT header is required, so fetch the blob and download it directly
  // (binaries stay intact; .text() would corrupt images/PDFs).
  getJwt().then(function (jwt) {
    return fetch(apiUrl('raw', currentPath, 'algo=none&inline=false'), {
      headers: { 'X-Auth': jwt }
    });
  }).then(function (r) {
    if (!r.ok) throw new Error('download ' + r.status);
    return r.blob();
  }).then(function (blob) {
    var fname = currentPath.split('/').pop() || 'file';
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = fname;
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
    showToast('Downloading ' + fname);
  }).catch(function (e) {
    showToast('Download failed: ' + e.message);
  });
});

// ---- topbar wiring ----
document.querySelectorAll('#ms-bar [data-theme-btn]').forEach(function (b) {
  b.addEventListener('click', function () { setTheme(b.dataset.themeBtn); });
});
setTheme(theme);

pathEl.addEventListener('click', function () {
  if (navigator.clipboard && pathEl.textContent) navigator.clipboard.writeText(pathEl.textContent.trim());
  showToast('Copied: ' + pathEl.textContent.trim());
});

// tree fold toggle
var TREE_FOLD_KEY = 'fileview-tree-collapsed';
if (store.get(TREE_FOLD_KEY) === '1') treePane.classList.add('collapsed');
document.getElementById('ms-refresh').addEventListener('click', function () { refreshTree(); });

// Coming back to a tab that has been in the background: revalidate what is on
// screen, so the tree stops showing a file that was deleted in a terminal ten
// minutes ago.
//
// Two things this does NOT do. It does not fire on every tab switch — alt-tabbing
// away and back within seconds is not a reason to re-walk the tree, and on a tree
// with many directories open that is one request per directory, every time. And it
// does not paint the root and the open directories in parallel: repainting the root
// can replace the very nodes the second loop is about to look up, which spends
// requests on containers that are already detached.
var REVALIDATE_AFTER_MS = 30 * 1000;
var hiddenSince = 0;
function revalidateVisible() {
  var open = openDirsUnder(tree);
  return paintDir(tree, '/', true).then(function () { return reopenDirs(tree, open); });
}
document.addEventListener('visibilitychange', function () {
  if (document.visibilityState !== 'visible') { hiddenSince = Date.now(); return; }
  if (!hiddenSince || Date.now() - hiddenSince < REVALIDATE_AFTER_MS) return;
  hiddenSince = 0;
  revalidateVisible();
});

var treeToggleBtn = document.getElementById('ms-tree-toggle');
// aria-pressed has to say what the sidebar is actually doing, including on load
// from the saved state — it read "false" whatever the sidebar was.
function announceTreeFold() {
  treeToggleBtn.setAttribute('aria-pressed',
    treePane.classList.contains('collapsed') ? 'true' : 'false');
}
announceTreeFold();
treeToggleBtn.addEventListener('click', function () {
  treePane.classList.toggle('collapsed');
  var fold = treePane.classList.contains('collapsed');
  try { localStorage.setItem(TREE_FOLD_KEY, fold ? '1' : '0'); } catch (_) {}
  announceTreeFold();
});

editBtn.addEventListener('click', function () {
  if (editBtn.disabled || !currentMd) return;
  if (inEditMode) {
    // back to View — confirm if dirty (unsaved guard)
    if (isDirty()) {
      if (!confirm('You have unsaved changes.\n\nOK = discard changes and return to the viewer\nCancel = keep editing')) {
        return;
      }
    }
    openFile(currentMd);
  } else {
    openEditor(currentMd);
  }
});
saveBtn.addEventListener('click', function () { triggerSave(); });

// Ctrl+S parent capture -> triggerSave
document.addEventListener('keydown', function (ev) {
  if ((ev.ctrlKey || ev.metaKey) && ev.key === 's') {
    ev.preventDefault();
    if (inEditMode) triggerSave();
  }
});

// When the deferred vendors (hljs/marked/dompurify) finish loading, re-render the
// current text file if it opened before they were ready (deep-link early open —
// code colouring / ipynb md cells).
function reRenderIfStructured() {
  if (!inEditMode && currentPath && currentPath !== '/' && descriptorFor(currentPath).t === 'text') {
    renderStructured(currentPath, currentView);
  }
}
// This script is deferred and declared AFTER the three library tags, so in the
// normal case they have already executed by the time this runs — the listener would
// never fire. Only wait on one that is genuinely still loading (a slow or errored
// fetch); otherwise there is nothing to wait for.
['/__fv/highlight.min.js', '/__fv/marked.min.js', '/__fv/purify.min.js'].forEach(function (src) {
  // Prefix match: the installer appends ?v=<hash> to these URLs in the served HTML.
  var el = document.querySelector('script[src^="' + src + '"]');
  if (el && !el.dataset.loaded) el.addEventListener('load', function () {
    el.dataset.loaded = '1';
    reRenderIfStructured();
  });
});

// Raw toggle — structured view (json/csv) <-> raw. The parent swaps the srcdoc
// (the sandbox stays script-free).
rawToggleBtn.addEventListener('click', function () {
  if (rawToggleBtn.hidden) return;
  rawOverride = !rawOverride;
  if (rawOverride) {
    var back = currentView === 'csv' ? 'table' : 'tree';
    setIcon(rawToggleBtn, 'structured', 'Back to the ' + back + ' view', 'Back to the ' + back);
  } else {
    setIcon(rawToggleBtn, 'raw', 'Show the raw text instead', 'Raw text');
  }
  renderStructured(currentPath, currentView);
});

// ---- tree bootstrap ----
function bootstrapTree() {
  return paintDir(tree, '/', true).then(function () {
    return reopenDirs(tree, loadOpenDirs());
  });
}
// Re-read everything currently on screen, cache be damned. The cache is refreshed in
// the background on its own, but a button that says "look again NOW" is the exit when
// something changed outside this tab and the eye does not believe the screen.
function refreshTree() {
  var open = openDirsUnder(tree);
  cacheDrop('/');
  for (var i = 0; i < open.length; i++) cacheDrop(open[i]);
  return revalidateVisible().then(function () {
    if (currentPath && currentPath !== '/') highlightActive(currentPath);
    showToast('Tree refreshed');
  });
}

// ---- deep link path expand ----
function expandPathChain(targetPath) {
  // /a/b/c.md -> ['/a', '/a/b'] (directories only)
  var parts = targetPath.split('/').filter(Boolean);
  if (parts.length <= 1) return Promise.resolve();   // root file
  var chain = [];
  for (var i = 0; i < parts.length - 1; i++) {
    chain.push('/' + parts.slice(0, i + 1).join('/'));
  }
  var p = Promise.resolve();
  chain.forEach(function (dirPath) {
    p = p.then(function () {
      var node = document.querySelector('#ms-tree .ms-node[data-path="' + cssEscape(dirPath) + '"]');
      if (!node) return;
      var hasChildren = node.querySelector(':scope > .ms-children');
      if (!hasChildren) return toggleDir(node);
    });
  });
  return p;
}

// =================== MANAGEMENT ===================
// Every operation here is one filebrowser API call plus one cache invalidation.
// Measured against the pinned binary (2.63.x): mkdir/upload/rename/copy answer 200,
// delete answers 204, and search streams newline-delimited JSON.
//
// Deliberately NOT here: dragging a row onto another row to move it (it needs
// hover-expand, drop highlighting and an undo story, and it is the operation you
// least want to fat-finger when the root is `/`), and zip-download of a directory
// (the archiver has no FIFO guard — a directory holding a socket or a pipe answered
// nothing for 8 seconds when it was measured).
function apiWrite(method, kind, path, query, body, headers, retried) {
  return getJwt().then(function (jwt) {
    var h = { 'X-Auth': jwt };
    for (var k in (headers || {})) h[k] = headers[k];
    return fetch(apiUrl(kind, path, query), { method: method, headers: h, body: body });
  }).then(function (r) {
    // The token is valid for two hours. A tab left open past that had every write
    // fail with the same dead token until something else happened to re-issue it —
    // reads already recover this way, writes did not.
    if (r.status === 401 && !retried) {
      jwtCache = null; store.del('fileview-jwt');
      return apiWrite(method, kind, path, query, body, headers, true);
    }
    if (!r.ok) throw new Error(method + ' ' + r.status);
    return r;
  });
}
// After any mutation: forget the affected directories and repaint whatever of them
// is on screen. Without this the tree keeps showing a file that no longer exists.
// Creating something inside a folder that is not expanded leaves the tree looking
// unchanged. Open the chain so the new row is where the eye is already going.
function revealPath(path) { return expandPathChain(path).then(function () { highlightActive(path); }); }
function afterMutation(paths) {
  var dirs = {};
  paths.forEach(function (p) { dirs[p.replace(/\/[^/]*$/, '') || '/'] = true; });
  Object.keys(dirs).forEach(cacheDrop);
  Object.keys(dirs).forEach(function (d) {
    if (d === '/') return paintDir(tree, '/', true);
    var node = tree.querySelector('.ms-node[data-path="' + cssEscape(d) + '"]');
    var kids = node && node.querySelector(':scope > .ms-children');
    if (kids) paintDir(kids, d, true);
  });
}
function parentOf(path) { return path.replace(/\/[^/]*$/, '') || '/'; }
function isUnder(path, dir) { return path === dir || path.indexOf(dir + '/') === 0; }
// What the viewer should do when `path` was renamed/moved to `dest` (or deleted, if
// dest is null). Checking `currentPath === path` alone was wrong for directories:
// renaming /a while /a/file.md is open left the viewer showing a path that no longer
// exists, and a save from the editor would write to it.
function followMutation(path, dest) {
  if (!currentPath || !isUnder(currentPath, path)) return;
  if (dest === null) {
    currentPath = null; currentMd = null; inEditMode = false; editorEl = null;
    showViewer();
    if (viewer.hasAttribute('srcdoc')) viewer.removeAttribute('srcdoc');
    lastSrcdoc = null;
    viewer.src = 'about:blank';
    updateBarPath('/', false, false);
    return;
  }
  var moved = dest + currentPath.slice(path.length);
  if (inEditMode && isDirty()) {
    // Do not silently repoint an editor holding unsaved text at a new path.
    showToast('Moved on disk — reopen ' + moved + ' (unsaved changes kept here)');
    return;
  }
  openFile(moved);
}
function joinPath(dir, name) { return (dir === '/' ? '' : dir) + '/' + name; }

function opNewFolder(dir) {
  var name = prompt('New folder in ' + dir, '');
  if (!name) return;
  if (name.indexOf('/') >= 0) return showToast('A folder name cannot contain "/"');
  var target = joinPath(dir, name);
  apiWrite('POST', 'resources', target + '/', null, null)
    .then(function () { afterMutation([target]); return revealPath(target + '/x'); })
    .then(function () { showToast('Created ' + name); })
    .catch(function (e) { showToast('Could not create: ' + e.message); });
}
function opNewFile(dir) {
  var name = prompt('New file in ' + dir, '');
  if (!name) return;
  if (name.indexOf('/') >= 0) return showToast('A file name cannot contain "/"');
  var target = joinPath(dir, name);
  apiWrite('POST', 'resources', target, 'override=false', '', { 'content-type': 'text/plain' })
    .then(function () { afterMutation([target]); return revealPath(target); })
    .then(function () { openFile(target); })
    .catch(function (e) { showToast('Could not create: ' + e.message); });
}
function opRename(path) {
  var old = path.split('/').pop();
  var name = prompt('Rename', old);
  if (!name || name === old) return;
  if (name.indexOf('/') >= 0) return showToast('Use Move… to change the folder');
  var target = joinPath(parentOf(path), name);
  apiWrite('PATCH', 'resources', path, 'action=rename&destination=' + encodeURIComponent(target))
    .then(function () {
      afterMutation([path, target]);
      followMutation(path, target);
      showToast('Renamed');
    }).catch(function (e) { showToast('Could not rename: ' + e.message); });
}
// A destination has to be a normalised absolute path, and a directory cannot be
// moved inside itself — the API answers an opaque 4xx for that, which tells the
// person nothing about what they did wrong.
function badDestination(path, target, isDir) {
  if (target.charAt(0) !== '/') return 'Give an absolute path, starting with /';
  var segs = target.split('/');
  for (var i = 0; i < segs.length; i++) {
    if (segs[i] === '.' || segs[i] === '..') return 'Give a plain path — no "." or ".." segments';
  }
  if (isDir && isUnder(target, path)) return 'A folder cannot be moved inside itself';
  return null;
}
function opMove(path, isDir) {
  // A full destination path, not a folder picker: the tree already shows where things
  // are, and a text field is the only control that can also express "somewhere I have
  // not expanded yet".
  var target = prompt('Move to (full path)', path);
  if (!target || target === path) return;
  var bad = badDestination(path, target, isDir);
  if (bad) return showToast(bad);
  apiWrite('PATCH', 'resources', path, 'action=rename&destination=' + encodeURIComponent(target))
    .then(function () {
      afterMutation([path, target]);
      followMutation(path, target);
      showToast('Moved');
    }).catch(function (e) { showToast('Could not move: ' + e.message); });
}
function opDelete(path, isDir) {
  // The confirm names the full path, not the file name. At `--root /` "delete src?"
  // is not enough information to answer.
  if (!confirm('Delete this ' + (isDir ? 'folder and everything in it' : 'file') + '?\n\n' + path)) return;
  apiWrite('DELETE', 'resources', path)
    .then(function () {
      afterMutation([path]);
      followMutation(path, null);
      showToast('Deleted');
    }).catch(function (e) { showToast('Could not delete: ' + e.message); });
}
function uploadFiles(dir, files) {
  if (!files || !files.length) return;
  var done = 0, failed = 0, total = files.length;
  var targets = [];
  var chain = Promise.resolve();
  Array.prototype.forEach.call(files, function (f) {
    var target = joinPath(dir, f.name);
    targets.push(target);
    chain = chain.then(function () {
      // override=false: an upload must not silently replace a file that is already
      // there. filebrowser answers 409 and the count below reports it.
      return apiWrite('POST', 'resources', target, 'override=false', f)
        .then(function () { done++; }, function () { failed++; });
    });
  });
  showToast('Uploading ' + total + '…');
  return chain.then(function () {
    afterMutation(targets);
    if (targets.length) revealPath(targets[0]);
    showToast(failed ? (done + ' uploaded, ' + failed + ' failed (already there?)')
                     : ('Uploaded ' + done));
  });
}

// ---- context menu ----
function closeMenu() { menuEl.hidden = true; menuEl.textContent = ''; }
function menuItem(label, fn, cls) {
  var b = document.createElement('button');
  b.className = 'mi' + (cls ? ' ' + cls : '');
  b.type = 'button';
  b.textContent = label;
  b.addEventListener('click', function () { closeMenu(); fn(); });
  return b;
}
function openMenu(x, y, path, isDir) {
  menuEl.textContent = '';
  var hdr = document.createElement('div');
  hdr.className = 'hdr';
  hdr.textContent = path;
  menuEl.appendChild(hdr);
  if (isDir) {
    menuEl.appendChild(menuItem('New folder…', function () { opNewFolder(path); }));
    menuEl.appendChild(menuItem('New file…', function () { opNewFile(path); }));
    menuEl.appendChild(menuItem('Search here', function () { setScope(path); searchEl.focus(); }));
  } else {
    menuEl.appendChild(menuItem('Open', function () { openFile(path); }));
    menuEl.appendChild(menuItem('Edit', function () { openEditor(path); }));
  }
  var sep = document.createElement('div'); sep.className = 'sep';
  menuEl.appendChild(sep);
  menuEl.appendChild(menuItem('Copy path', function () {
    if (navigator.clipboard) navigator.clipboard.writeText(path).then(function () { showToast('Copied path'); }, function () {});
  }));
  menuEl.appendChild(menuItem('Rename…', function () { opRename(path); }));
  menuEl.appendChild(menuItem('Move…', function () { opMove(path, isDir); }));
  menuEl.appendChild(menuItem('Delete', function () { opDelete(path, isDir); }, 'danger'));
  menuEl.hidden = false;
  // Keep it on screen: near the right or bottom edge, flip rather than overflow.
  var r = menuEl.getBoundingClientRect();
  menuEl.style.left = Math.max(4, Math.min(x, window.innerWidth - r.width - 4)) + 'px';
  menuEl.style.top = Math.max(4, Math.min(y, window.innerHeight - r.height - 4)) + 'px';
}
document.addEventListener('click', function (ev) { if (!menuEl.contains(ev.target)) closeMenu(); });
document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') closeMenu(); });
window.addEventListener('blur', closeMenu);
tree.addEventListener('contextmenu', function (ev) {
  var row = ev.target.closest && ev.target.closest('.ms-row');
  if (!row) return;
  var node = row.parentNode;
  if (!node.dataset.path) return;
  ev.preventDefault();
  openMenu(ev.clientX, ev.clientY, node.dataset.path, node.dataset.isdir === '1');
});

// ---- keyboard navigation ----
// The tree is ONE tab stop and the arrow keys move within it. That is the
// roving-tabindex pattern, and the part that is easy to get wrong is which
// element holds the stop.
//
// The first attempt put `tabindex="0"` on the container and left every row at
// -1, delegating container focus to a row. That is a one-way keyboard trap:
// rows come after the container in document order, so Shift+Tab from a row lands
// on the container, whose focus handler sends it straight back to a row. Focus
// could enter the tree and never leave it backwards — a keyboard user could not
// reach the search field again. So the stop lives on exactly one ROW, the
// container has no tabindex and no focus handler, and Shift+Tab leaves the way
// it arrived.
//
// "The rows you can see" is not a stored list. It is the rows currently in the
// tree that are actually rendered — collapsing a directory removes rows, and
// collapsing the whole sidebar hides them without removing them, which is what
// the offsetParent test catches. Reading it fresh per keystroke costs nothing at
// this size and cannot go stale, which a cached list does the moment a directory
// is renamed underneath it.
// Collapsing the sidebar is the only thing that hides a row without removing it,
// so that is one class check rather than a per-row layout question. Asking each
// row for its offsetParent instead was correct and cost 19ms on a 6,000-row tree,
// which a held-down arrow key notices.
function visibleRows() {
  if (treePane.classList.contains('collapsed')) return [];
  return Array.prototype.slice.call(tree.querySelectorAll('.ms-row'));
}
// Exactly one row carries the tab stop, and moving it is two attribute writes, not
// one per row: at 6,000 rows the sweep was most of a 36ms keypress.
var tabStop = null;
function setTabStop(row) {
  if (tabStop === row) return;
  if (tabStop) tabStop.setAttribute('tabindex', '-1');
  tabStop = row || null;
  if (tabStop) tabStop.setAttribute('tabindex', '0');
}
// Called after every paint, because a repaint replaces the row that had the stop
// and a tree with no stop cannot be reached from the keyboard at all.
function syncTabStop() {
  if (tabStop && tabStop.isConnected && tree.contains(tabStop)) return;
  tabStop = null;
  setTabStop(tree.querySelector('.ms-row.active') || tree.querySelector('.ms-row'));
}
function focusRow(row) {
  // A repaint can land between an async open and this call, and the row that was
  // captured is then detached — focus() on it silently does nothing and leaves
  // focus on <body>, outside the tree, where the arrow keys are dead.
  if (!row || !row.isConnected) return;
  setTabStop(row);
  row.focus();
  if (row.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
}
function rowFor(path) {
  var node = tree.querySelector('.ms-node[data-path="' + cssEscape(path) + '"]');
  return node && node.querySelector(':scope > .ms-row');
}
function parentRow(row) {
  var children = row.parentNode.parentNode;   // .ms-row -> .ms-node -> .ms-children
  if (!children || children.className !== 'ms-children') return null;
  return children.parentNode.querySelector(':scope > .ms-row');
}
tree.addEventListener('keydown', function (ev) {
  var row = ev.target.closest && ev.target.closest('.ms-row');
  if (!row) return;
  var node = row.parentNode;
  var path = node.dataset.path;
  var isDir = node.dataset.isdir === '1';
  var open = row.getAttribute('aria-expanded') === 'true';
  var rows = visibleRows();
  var i = rows.indexOf(row);

  switch (ev.key) {
    case 'ArrowDown': focusRow(rows[i + 1]); break;
    case 'ArrowUp':   focusRow(rows[i - 1]); break;
    case 'Home':      focusRow(rows[0]); break;
    case 'End':       focusRow(rows[rows.length - 1]); break;
    case 'ArrowRight':
      // Closed directory: open it and stay put, so the next Down is the first
      // child. Open directory: step into it. Both are what the ARIA practices
      // for a tree say, and the row is looked up again after the await because
      // the one captured before it may no longer be in the document.
      if (isDir && !open) {
        // Re-focusing after the listing arrives is right only if the user is still
        // where they were. On a slow directory they may have pressed Down three
        // times by then, and yanking focus back to the folder they opened is worse
        // than not restoring it at all.
        var was = document.activeElement;
        toggleDir(node).then(function () {
          if (document.activeElement === was || document.activeElement === document.body) {
            focusRow(rowFor(path));
          }
        });
      }
      else if (isDir) { var after = visibleRows(); focusRow(after[after.indexOf(row) + 1]); }
      else return;
      break;
    case 'ArrowLeft':
      if (isDir && open) { toggleDir(node); focusRow(rowFor(path)); }
      else focusRow(parentRow(row));
      break;
    case 'Enter':
    case ' ':
      if (isDir) toggleDir(node); else openFile(path);
      break;
    default: return;
  }
  ev.preventDefault();
});

// ---- drag-and-drop upload (OS files only) ----
// Drop on a directory row to upload into it; drop anywhere else in the tree to
// upload into the directory currently in scope.
function dropDirFor(target) {
  var row = target && target.closest && target.closest('.ms-row');
  var node = row && row.parentNode;
  if (node && node.dataset && node.dataset.isdir === '1') return { dir: node.dataset.path, row: row };
  return { dir: searchScope, row: null };
}
var lastDropRow = null;
function clearDropTarget() {
  if (lastDropRow) lastDropRow.classList.remove('droptarget');
  lastDropRow = null;
}
tree.addEventListener('dragover', function (ev) {
  if (!ev.dataTransfer || Array.prototype.indexOf.call(ev.dataTransfer.types, 'Files') < 0) return;
  ev.preventDefault();
  ev.dataTransfer.dropEffect = 'copy';
  var d = dropDirFor(ev.target);
  if (d.row !== lastDropRow) { clearDropTarget(); if (d.row) { d.row.classList.add('droptarget'); lastDropRow = d.row; } }
});
tree.addEventListener('dragleave', function (ev) { if (ev.target === tree) clearDropTarget(); });
tree.addEventListener('drop', function (ev) {
  if (!ev.dataTransfer || !ev.dataTransfer.files || !ev.dataTransfer.files.length) return;
  ev.preventDefault();
  var d = dropDirFor(ev.target);
  clearDropTarget();
  uploadFiles(d.dir, ev.dataTransfer.files);
});

// ---- search ----
// filebrowser has no index: a search is `afero.Walk` with no timeout, and from `/` it
// descends /proc and /sys and does not come back — measured still running at 12 s.
// So a search is always scoped to one directory, the scope is shown, and the request
// is abortable. Searching at `/` asks first, and says why.
var searchScope = '/';
var searchAbort = null;
function setScope(dir) {
  searchScope = dir || '/';
  scopeEl.textContent = '';
  var label = document.createElement('span');
  label.textContent = 'search in ' + searchScope;
  scopeEl.appendChild(label);
  scopeEl.title = searchScope === '/'
    ? 'Search looks under the whole filesystem'
    : 'Search looks under this directory only — click to widen it back to /';
  if (searchScope === '/') {
    var w = document.createElement('span');
    w.className = 'warn';
    w.textContent = 'whole disk';
    scopeEl.appendChild(document.createTextNode(' — '));
    scopeEl.appendChild(w);
  }
}
function runSearch(q) {
  if (searchAbort) { searchAbort.abort(); searchAbort = null; }
  // Clearing the box restores the TREE, not the scope's directory. Repainting the
  // scope instead left the tree rooted somewhere the user never asked to be rooted,
  // with no way back to /.
  if (!q) { bootstrapTree(); return; }
  if (searchScope === '/' &&
      !confirm('Search the whole disk?\n\nThere is no index, so this walks every '
             + 'directory under / and can take a long time. Right-click a folder and '
             + 'choose "Search here" to scope it.')) return;
  var ac = new AbortController();
  searchAbort = ac;
  tree.innerHTML = '<div class="ms-loading">Searching ' + escapeHTML(searchScope) + '…</div>';
  getJwt().then(function (jwt) {
    return fetch(apiUrl('search', searchScope, 'query=' + encodeURIComponent(q)),
                 { headers: { 'X-Auth': jwt }, signal: ac.signal });
  }).then(function (r) {
    if (!r.ok) throw new Error('search ' + r.status);
    return r.text();
  }).then(function (text) {
    if (searchAbort !== ac) return;   // superseded by a newer search
    searchAbort = null;
    var hits = text.split('\n').filter(Boolean).map(function (line) {
      try { return JSON.parse(line); } catch (_) { return null; }
    }).filter(Boolean);
    renderSearchHits(hits, q);
  }).catch(function (e) {
    if (e.name === 'AbortError') return;
    tree.innerHTML = '<div class="ms-error">' + escapeHTML(e.message) + '</div>';
  });
}
function renderSearchHits(hits, q) {
  tree.textContent = '';
  var head = document.createElement('div');
  head.className = 'ms-loading';
  head.textContent = hits.length + ' match' + (hits.length === 1 ? '' : 'es') + ' for "' + q + '"';
  tree.appendChild(head);
  hits.slice(0, 500).forEach(function (h) {
    // filebrowser returns paths relative to the search root.
    var abs = searchScope === '/' ? '/' + h.path : joinPath(searchScope, h.path);
    tree.appendChild(renderNode({ name: abs, path: abs, isDir: !!h.dir }, 0));
  });
  if (hits.length > 500) {
    var more = document.createElement('div');
    more.className = 'ms-loading';
    more.textContent = 'showing the first 500 of ' + hits.length + ' — narrow the search';
    tree.appendChild(more);
  }
  syncTabStop();   // results are rows too, and they replaced the ones with the stop
}
var searchTimer = null;
searchEl.addEventListener('input', function () {
  clearTimeout(searchTimer);
  var q = searchEl.value.trim();
  searchTimer = setTimeout(function () { runSearch(q); }, 350);
});
searchEl.addEventListener('keydown', function (ev) {
  if (ev.key === 'Escape') { searchEl.value = ''; runSearch(''); }
});
// "Here" is the folder you are looking at, in the order you would say it out loud:
// the directory you have selected, or the one holding the file you have open, and
// only then the search scope. Using the search scope alone made both buttons point
// at `/` until you had narrowed a search — so "New file here" meant "new file in
// the filesystem root", which fails, and deserved to.
function currentDir() {
  var active = tree.querySelector('.ms-row.active');
  var node = active && active.parentNode;
  if (node && node.dataset.isdir === '1') return node.dataset.path;
  if (currentPath && currentPath !== '/') {
    var known = pathIsFile(currentPath);
    if (known === false) return currentPath;          // a directory is open
    if (known === true) return parentOf(currentPath);  // a file is open
  }
  return searchScope;
}
// The buttons say where they will write, rather than saying "here" and leaving you
// to work out which "here" they meant.
function announceNewTargets() {
  var dir = currentDir();
  newFileBtn.title = 'New file in ' + dir;
  newFileBtn.setAttribute('aria-label', 'New file in ' + dir);
  newDirBtn.title = 'New folder in ' + dir;
  newDirBtn.setAttribute('aria-label', 'New folder in ' + dir);
}
// New file was only ever reachable by right-clicking a folder row — the capability
// existed, the way in did not, and creating a `.env` is exactly the thing this app
// promises you can do like any other file.
var newFileBtn = document.getElementById('ms-newfile');
var newDirBtn  = document.getElementById('ms-newdir');
newFileBtn.addEventListener('click', function () { opNewFile(currentDir()); });
newDirBtn.addEventListener('click', function () { opNewFolder(currentDir()); });
tree.addEventListener('click', function () { setTimeout(announceNewTargets, 0); });
announceNewTargets();
// One click back to the whole filesystem. Without it a narrowed scope is a one-way
// door — the only control that sets it is a menu item on a row you may have scrolled
// away from.
scopeEl.addEventListener('click', function () {
  if (searchScope === '/') return;
  setScope('/');
  if (searchEl.value.trim()) runSearch(searchEl.value.trim());
  showToast('Search scope: /');
});
setScope('/');
cachedDirs = countCachedDirs();

// The home directory of the account this app runs as, written into the page by the
// installer. Not a setting — there is no key, nothing reads config, and a box that
// serves the file unstamped simply lands at the root.
function accountHome() {
  var m = document.querySelector('meta[name="fileview-home"]');
  var v = m && m.getAttribute('content');
  return v && v.charAt(0) === '/' && v !== '/' ? v.replace(/\/+$/, '') : null;
}
function landAtHome() {
  var home = accountHome();
  if (!home) return Promise.resolve();
  // expandPathChain opens every directory ABOVE its argument, so give it a child
  // that does not need to exist — the same trick opNewFolder uses to reveal a
  // freshly created directory.
  return expandPathChain(home + '/x').then(function () {
    var node = tree.querySelector('.ms-node[data-path="' + cssEscape(home) + '"]');
    if (!node) return;
    var row = node.querySelector(':scope > .ms-row');
    if (row && row.scrollIntoView) row.scrollIntoView({ block: 'center' });
    setTabStop(row);
    announceNewTargets();
  }).catch(function () {});
}

// ---- start ----
bootstrapTree().then(function () {
  var qs   = new URLSearchParams(location.search);
  var DEEP = qs.get('path');
  if (DEEP) {
    return expandPathChain(DEEP).then(function () {
      // File or directory is a fact, not a naming convention. expandPathChain has
      // just painted the chain, so the tree usually knows; if it does not, ask
      // filebrowser. Guessing from the name opened `Makefile` as a directory and
      // tried to read a directory called `release.v1` as a file.
      var known = pathIsFile(DEEP);
      var decide = known != null
        ? Promise.resolve(known)
        : getJwt()
            .then(function (jwt) {
              return fetch(apiUrl('resources', DEEP), { headers: { 'X-Auth': jwt } });
            })
            .then(function (r) { return r.ok ? r.json() : null; })
            .then(function (d) { return d ? !d.isDir : null; })
            .catch(function () { return null; });
      return decide.then(function (isFile) {
        if (isFile) openFile(DEEP, decodeURIComponent(location.hash.slice(1)));
        else {
          // null (unreachable path) lands here too: show it, do not try to read it
          updateBarPath(DEEP, false, isFile === false ? false : null);
          highlightActive(DEEP);
        }
      });
    });
  } else {
    // No deep link: open at the running account's home. A filesystem root is a
    // correct place to start and a useless one — /bin, /boot, /dev, and the
    // directory you actually keep things in is four rows down and closed. The
    // root and every sibling stay exactly where they were; this only decides
    // where the tree is already open when it appears.
    landAtHome();
    // The pane that has no file in it says so, quietly and in one line — an ASCII
    // rocket reading "M A R K W A N D" used to sit here, from the markdown viewer
    // this app grew out of, and it was both the wrong product's name and the
    // loudest thing on the screen.
    sandboxViewer();
    commitSrcdoc(docShell('text', '',
      'html,body{height:100%;}' +
      'body{margin:0;padding:0;max-width:none;display:flex;align-items:center;justify-content:center;background:var(--bg);}' +
      '.empty{color:var(--text-muted);font-family:var(--font-sans);font-size:var(--fs-md);}',
      '<div class="empty">No file selected</div>'));
  }
});
