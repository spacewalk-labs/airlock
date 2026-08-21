/* edit-button.js — Markwand Dev Server (markwand-aware)
 * Injected into every markserv-rendered .md page by nginx sub_filter.
 * Floats top-right "✏️ Edit" → opens same file in filebrowser editor.
 *
 * In an iframe (split-pane viewer) the parent already has a topbar ✏️ Edit button, so
 * it is not shown here to avoid duplication / obscuring the document. Only shown in the single-pane viewer (direct entry).
 */
(function () {
  if (!location.pathname.endsWith('.md')) return;
  // never render inside an iframe
  try { if (window.self !== window.top) return; } catch (_) { return; }

  var p = location.pathname;
  if (p.indexOf('/markwand/') === 0) p = p.substring('/markwand'.length);
  var target = location.origin + '/markwand/edit/files' + p + '?edit=true';

  var a = document.createElement('a');
  a.id = 'markwand-edit-btn';
  a.href = target;
  a.target = '_blank';
  a.rel = 'noopener';
  a.textContent = '✏️ Edit';
  a.title = 'Open in filebrowser editor';
  document.body.appendChild(a);
})();
