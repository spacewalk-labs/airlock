/* markwand-editor.js — saving in the filebrowser editor auto-returns to the markserv viewer
 *
 * Injected via nginx sub_filter into the HTML response of /markwand/edit/ (filebrowser SPA).
 * filebrowser v2.63.4 only auto-injects custom.css via branding (custom.js unsupported)
 * → injected via nginx sub_filter, same as the markserv viewer's __markwand.js.
 *
 * Behavior: on save in the editor (Ctrl+S / top save button) → filebrowser
 *   calls PUT /markwand/edit/api/resources/<path> → on 2xx success,
 *   navigate to that file's markserv viewer (/markwand/<path>).
 *   filebrowser mixes fetch and XHR for saving, so intercept both.
 *   Only .md files (markserv render targets) — leave other extensions unchanged.
 */
(function () {
  var EDIT_PREFIX = '/markwand/edit/files';   // editor file route
  var VIEW_PREFIX = '/markwand';               // markserv viewer prefix

  // /markwand/edit/files/foo/bar.md → /markwand/foo/bar.md (md only, else null)
  function viewerUrlFor(editorPath) {
    if (editorPath.indexOf(EDIT_PREFIX) !== 0) return null;
    var rel = editorPath.substring(EDIT_PREFIX.length);   // /foo/bar.md
    if (!/\.md$/i.test(rel)) return null;
    return VIEW_PREFIX + rel;
  }

  function goViewer() {
    var u = viewerUrlFor(location.pathname);
    if (u) location.assign(u);
  }

  function isSavePut(method, url) {
    return !!method && String(method).toUpperCase() === 'PUT'
        && /\/api\/resources\//.test(url || '');
  }

  // 1) fetch path
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input, init) {
      var url = (typeof input === 'string') ? input : (input && input.url) || '';
      var method = (init && init.method) || (input && input.method) || 'GET';
      var p = origFetch.apply(this, arguments);
      if (isSavePut(method, url)) {
        p.then(function (res) { if (res && res.ok) goViewer(); }, function () {});
      }
      return p;
    };
  }

  // 2) XHR path
  var XHR = window.XMLHttpRequest;
  if (XHR && XHR.prototype) {
    var open = XHR.prototype.open;
    var send = XHR.prototype.send;
    XHR.prototype.open = function (method, url) {
      this.__mwSave = isSavePut(method, url);
      return open.apply(this, arguments);
    };
    XHR.prototype.send = function () {
      if (this.__mwSave) {
        this.addEventListener('load', function () {
          if (this.status >= 200 && this.status < 300) goViewer();
        });
      }
      return send.apply(this, arguments);
    };
  }
})();
