/* markwand-enhance.js — vanilla JS, ~120 lines.
 * Injected into every markserv-rendered .md/index page by nginx sub_filter.
 *
 * Features:
 *   1. 3-way theme toggle (system|light|dark) with localStorage persistence
 *   2. GFM Alert callouts (NOTE/TIP/WARNING/CAUTION/IMPORTANT)
 *   3. Heading anchor copy buttons (h1~h6)
 *   4. Filename clipboard copy (top bar)
 *   5. ToC sidebar (h1~h6 auto extract, sticky)
 *   6. Hash highlight handled by CSS (:target animation)
 */
(function () {
  'use strict';

  // ====== 1. THEME TOGGLE ======
  var STORAGE_KEY = 'markwand-theme';
  var theme = localStorage.getItem(STORAGE_KEY) || 'system';
  document.documentElement.setAttribute('data-theme', theme);

  function setTheme(next) {
    theme = next;
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem(STORAGE_KEY, next); } catch (_) {}
    updateThemeButtons();
  }
  function updateThemeButtons() {
    var btns = document.querySelectorAll('#markwand-topbar [data-theme-btn]');
    for (var i = 0; i < btns.length; i++) {
      btns[i].setAttribute('aria-pressed', btns[i].dataset.themeBtn === theme ? 'true' : 'false');
    }
  }

  // ====== 2. GFM ALERT CALLOUTS ======
  var ALERT_RE = /^\s*\[!(NOTE|TIP|WARNING|CAUTION|IMPORTANT)\]\s*$/;
  function applyAlerts() {
    var quotes = document.querySelectorAll('blockquote');
    for (var i = 0; i < quotes.length; i++) {
      var bq = quotes[i];
      var firstP = bq.querySelector('p');
      if (!firstP) continue;
      var firstLine = firstP.firstChild;
      if (!firstLine || firstLine.nodeType !== 3) continue;  // not text node
      var m = firstLine.nodeValue.match(ALERT_RE);
      if (!m) continue;
      var kind = m[1].toLowerCase();
      bq.classList.add('markwand-alert', 'alert-' + kind);
      firstLine.nodeValue = '';
      var title = document.createElement('div');
      title.className = 'markwand-alert-title';
      title.textContent = kind.toUpperCase();
      bq.insertBefore(title, firstP);
      // strip leading <br> from firstP
      if (firstP.firstChild && firstP.firstChild.nodeName === 'BR') firstP.removeChild(firstP.firstChild);
    }
  }

  // ====== 3. HEADING ANCHOR COPY ======
  function applyAnchors() {
    var hs = document.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]');
    for (var i = 0; i < hs.length; i++) {
      var h = hs[i];
      var a = document.createElement('a');
      a.className = 'markwand-anchor';
      a.href = '#' + h.id;
      a.textContent = '#';
      a.title = 'Copy link to this heading';
      a.addEventListener('click', function (id) {
        return function (ev) {
          ev.preventDefault();
          var url = location.origin + location.pathname + '#' + id;
          if (navigator.clipboard) navigator.clipboard.writeText(url);
          history.replaceState(null, '', '#' + id);
        };
      }(h.id));
      h.appendChild(a);
    }
  }

  // ====== 4. TOP BAR (theme toggle + filename copy) ======
  function buildTopbar() {
    var bar = document.createElement('div');
    bar.id = 'markwand-topbar';
    var modes = [['system','⊙'],['light','☀'],['dark','☾']];
    for (var i = 0; i < modes.length; i++) {
      var m = modes[i];
      var b = document.createElement('button');
      b.dataset.themeBtn = m[0];
      b.title = m[0];
      b.textContent = m[1];
      (function (mode) { b.addEventListener('click', function () { setTheme(mode); }); })(m[0]);
      bar.appendChild(b);
    }
    // filename copy
    var fname = decodeURIComponent(location.pathname.replace(/^\/markwand\/?/, '/'));
    var fnameEl = document.createElement('span');
    fnameEl.className = 'markwand-filename';
    fnameEl.textContent = fname;
    fnameEl.title = 'Click to copy path';
    fnameEl.style.cursor = 'pointer';
    fnameEl.addEventListener('click', function () {
      if (navigator.clipboard) navigator.clipboard.writeText(fname);
      fnameEl.style.opacity = '0.4';
      setTimeout(function () { fnameEl.style.opacity = '1'; }, 250);
    });
    bar.appendChild(fnameEl);
    document.body.appendChild(bar);
    updateThemeButtons();
  }

  // ====== 5. ToC SIDEBAR ======
  function buildToc() {
    var hs = document.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]');
    if (hs.length < 3) return;  // ToC not shown on pages that are too short
    var aside = document.createElement('aside');
    aside.id = 'markwand-toc';
    // initial collapsed state = localStorage. default = expanded (per user's changed intent — expanded by default)
    var TOC_KEY = 'markwand-toc-collapsed';
    var saved = localStorage.getItem(TOC_KEY);
    var collapsed = saved === '1';   // null/missing → false (expanded default)
    if (collapsed) aside.classList.add('collapsed');
    // toggle button
    var toggle = document.createElement('button');
    toggle.className = 'toc-toggle';
    toggle.title = 'Toggle table of contents';
    toggle.setAttribute('aria-label', 'Toggle table of contents');
    toggle.textContent = collapsed ? '☰' : '×';
    toggle.addEventListener('click', function () {
      aside.classList.toggle('collapsed');
      var nowCol = aside.classList.contains('collapsed');
      toggle.textContent = nowCol ? '☰' : '×';
      try { localStorage.setItem(TOC_KEY, nowCol ? '1' : '0'); } catch (_) {}
    });
    aside.appendChild(toggle);
    var head = document.createElement('h4');
    head.textContent = 'On this page';
    aside.appendChild(head);
    var ul = document.createElement('ul');
    for (var i = 0; i < hs.length; i++) {
      var h = hs[i];
      var li = document.createElement('li');
      li.className = 'toc-' + h.tagName.toLowerCase();
      var a = document.createElement('a');
      a.href = '#' + h.id;
      var txt = (h.textContent || '').replace(/#$/, '').trim();
      a.textContent = txt;
      a.title = txt;   // hover full title
      li.appendChild(a);
      ul.appendChild(li);
    }
    aside.appendChild(ul);
    document.body.appendChild(aside);
  }

  // ====== bootstrap ======
  // inside the viewer iframe the topbar duplicates the split-pane parent + obscures the document → skip
  var inIframe = (function () { try { return window.self !== window.top; } catch (_) { return true; } })();
  function init() {
    // R7: add .markdown-viewer class to the markserv body (Markwand upstream scope)
    document.body.classList.add('markdown-viewer');
    applyAlerts();
    applyAnchors();
    if (!inIframe) buildTopbar();   // topbar only in single-pane viewer mode (inside an iframe the parent handles it)
    buildToc();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
