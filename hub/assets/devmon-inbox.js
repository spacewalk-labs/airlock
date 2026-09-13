/* Shared Dev Monitor inbox.  The three public consumers mount this module rather
 * than maintaining slightly different copies of the same message list. */
(function (root) {
  'use strict';

  function apiBase() {
    // Every consumer is served by the hub: the dashboard lives at /monitor/ and
    // the hub strip/widget iframe live at /.  The owner API, however, always lives
    // behind the monitor location.  Dropping that prefix on the dashboard made
    // nginx's SPA fallback return index.html to res.json(); Safari surfaced that as
    // the unhelpful "The string did not match the expected pattern" error.
    return '/monitor/api/owner';
  }
  function el(doc, tag, className, text) {
    var node = doc.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = String(text);
    return node;
  }
  function age(value) {
    var then = Date.parse(value);
    if (isNaN(then)) return '-';
    var seconds = Math.max(0, Math.floor((Date.now() - then) / 1000));
    if (seconds < 60) return seconds + 's';
    if (seconds < 3600) return Math.floor(seconds / 60) + 'm';
    if (seconds < 86400) return Math.floor(seconds / 3600) + 'h';
    return Math.floor(seconds / 86400) + 'd';
  }
  function isHeartbeat(card) {
    return card && (card.source === 'heartbeat' || card.group === 'heartbeat' ||
      String(card.card_id || '').indexOf('heartbeat:') === 0);
  }
  function mount(container, options) {
    options = options || {};
    var doc = container && container.ownerDocument || root.document;
    if (!container || !doc) throw new Error('DevmonInbox.mount needs a root element.');
    var mode = options.mode === 'strip' ? 'strip' : 'full';
    var ownerApi = options.apiBase || apiBase();
    var key = 'active';
    var payload = null;
    var nodes = {};
    var timer = null;
    var stopped = false;
    var notice = '';

    function request(path, opts) {
      opts = opts || {};
      opts.cache = 'no-store';
      if (opts.method === 'POST') {
        opts.headers = Object.assign({'content-type': 'application/json'}, opts.headers || {});
        if (opts.body == null) opts.body = '{}';
      }
      return root.fetch(ownerApi + path, opts);
    }
    function response(res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (!res.ok || !data.ok) throw new Error(data.error || 'Action returned ' + res.status + '.');
        return data;
      });
    }
    function notify(counts) {
      if (options.onCounts) options.onCounts(counts || {});
      if (root.CustomEvent && root.dispatchEvent) {
        root.dispatchEvent(new root.CustomEvent('devmon-inbox-counts', {detail: counts || {}}));
      }
    }
    function toast(message) {
      if (options.toast) options.toast(message);
      else if (root.console && root.console.warn) root.console.warn('[devmon-inbox] ' + message);
    }
    function devtermUrl(session) {
      return root.fetch('/__airlock.json', {cache: 'no-store'}).then(function (r) {
        return r.json();
      }).then(function (cfg) {
        var app = cfg && cfg.apps && cfg.apps.devterm;
        var host = cfg && cfg.fqdn && cfg.fqdn.indexOf('.') > 0 ? cfg.fqdn : root.location.hostname;
        return app && app.port && host
          ? 'https://' + host + ':' + app.port + '/?arg=' + encodeURIComponent(session) : '';
      });
    }
    var cardUI = root.DevmonCardUI.create({
      read: function (card) { return request('/messages/' + encodeURIComponent(card.card_id) + '/read', {method: 'POST'}).then(response); },
      archive: function (card) { return request('/messages/' + encodeURIComponent(card.card_id) + '/archive', {method: 'POST'}).then(response); },
      run: function (card, params, note) {
        if (card.run && card.run.template) {
          var templateBody = {template: card.run.template, week: card.run.week,
            action: card.run.action, note: note};
          if (card.run.url) templateBody.url = card.run.url;
          return request('/run/template', {method: 'POST', body: JSON.stringify(templateBody)}).then(response);
        }
        return request('/run', {method: 'POST', body: JSON.stringify({card_id: card.card_id, params: params, note: note})}).then(response);
      },
      selectWindow: function (card) {
        if (card.run && card.run.template) {
          return request('/run/template/window', {method: 'POST', body: JSON.stringify({
            template: card.run.template, week: card.run.week, action: card.run.action
          })}).then(response);
        }
        return request('/run/window', {method: 'POST', body: JSON.stringify({card_id: card.card_id})}).then(response);
      },
      devtermUrl: devtermUrl,
      changed: function (card, kind) {
        var record = nodes[card.card_id];
        if (kind === 'read' && record && !record.row.classList.contains('ms-read')) {
          record.row.classList.add('ms-read');
          if (payload && payload.counts) payload.counts.unread = Math.max(0, (payload.counts.unread || 0) - 1);
          if (payload && typeof payload.unread_count === 'number') payload.unread_count = Math.max(0, payload.unread_count - 1);
          notify(counts());
        } else if (kind === 'read-failed' && record && record.row.classList.contains('ms-read')) {
          record.row.classList.remove('ms-read');
          if (payload && payload.counts) payload.counts.unread = (payload.counts.unread || 0) + 1;
          if (payload && typeof payload.unread_count === 'number') payload.unread_count += 1;
          notify(counts());
        } else if (kind === 'ran') {
          render();
        }
      },
      removed: function (card) {
        if (!payload) return;
        ['messages', 'top'].forEach(function (name) {
          if (Array.isArray(payload[name])) payload[name] = payload[name].filter(function (item) { return item.card_id !== card.card_id; });
        });
        if (payload.counts) {
          payload.counts.active = Math.max(0, (payload.counts.active || 0) - 1);
          if (!card.read_at) payload.counts.unread = Math.max(0, (payload.counts.unread || 0) - 1);
          if (card.level === 'urgent') payload.counts.urgent = Math.max(0, (payload.counts.urgent || 0) - 1);
        }
        if (typeof payload.unread_count === 'number' && !card.read_at) payload.unread_count = Math.max(0, payload.unread_count - 1);
        render();
      },
      toast: toast
    });

    function counts() {
      if (!payload) return {};
      if (payload.counts) return payload.counts;
      return {unread: payload.unread_count || 0};
    }
    function actionRow(card, includeArchive) {
      var item = el(doc, 'div', 'ms-row' + (card.read_at ? ' ms-read' : ''));
      item.dataset.cardId = card.card_id;
      var mark = el(doc, 'span', 'ms-mark' + (card.level === 'urgent' ? ' ms-urgent' : (card.level === 'ok' ? ' ms-ok' : '')),
        card.level === 'urgent' ? '!' : (card.level === 'ok' ? '✓' : ''));
      var title = el(doc, 'button', 'ms-title', card.title || '');
      title.type = 'button';
      title.addEventListener('click', function () { cardUI.openTitle(card); });
      var meta = el(doc, 'span', 'ms-s', [card.source || '', card.count > 1 ? '×' + card.count : '', age(card.last_at)].filter(Boolean).join(' · '));
      var actions = cardUI.createActions(card, includeArchive);
      var children = Array.prototype.slice.call(actions.children || []);
      var archive = children.filter(function (node) { return node.textContent === 'Archive'; })[0];
      if (archive) {
        archive.textContent = '×'; archive.classList.add('ms-x'); archive.setAttribute('aria-label', 'Archive');
      }
      item.appendChild(mark); item.appendChild(title); item.appendChild(meta); item.appendChild(actions);
      nodes[card.card_id] = {row: item, actions: actions};
      return item;
    }
    function visibleStrip() {
      var seen = {};
      return (payload.top || []).concat(payload.messages || []).filter(function (card) {
        if (!card || !card.card_id || card.read_at || isHeartbeat(card) || seen[card.card_id]) return false;
        seen[card.card_id] = true;
        return true;
      }).slice(0, 3);
    }
    function filterButton(label, value, count) {
      var button = el(doc, 'button', 'dmi-filter', label + (count ? ' ' + count : ''));
      button.type = 'button'; button.dataset.key = value;
      button.setAttribute('aria-pressed', value === key ? 'true' : 'false');
      button.addEventListener('click', function () {
        if (key === value) return;
        key = value; refresh();
      });
      return button;
    }
    function fullCards() {
      var cards = payload.messages || [];
      if (key === 'unread') return cards.filter(function (card) { return !card.read_at; });
      if (key === 'urgent') return cards.filter(function (card) { return card.level === 'urgent'; });
      return cards;
    }
    function renderFull() {
      var data = counts();
      if (options.title !== false) {
        var head = el(doc, 'div', 'dmi-head');
        head.appendChild(el(doc, 'h2', 'dmi-title', 'Inbox'));
        if (data.unread) head.appendChild(el(doc, 'span', 'dmi-unread', data.unread + ' unread'));
        container.appendChild(head);
      }
      var filters = el(doc, 'div', 'dmi-filters');
      filters.setAttribute('role', 'group'); filters.setAttribute('aria-label', 'Message filter');
      [['All', 'active', data.active], ['Unread', 'unread', data.unread], ['Urgent', 'urgent', data.urgent], ['Archived', 'archived', data.archived]]
        .forEach(function (item) { filters.appendChild(filterButton(item[0], item[1], item[2] || 0)); });
      container.appendChild(filters);
      var feed = el(doc, 'div', 'dmi-feed');
      var cards = fullCards();
      if (!cards.length) feed.appendChild(el(doc, 'div', 'dmi-empty', key === 'archived' ? '보관된 메시지가 없습니다.' : '메시지가 없습니다.'));
      cards.forEach(function (card) { feed.appendChild(actionRow(card, key !== 'archived')); });
      container.appendChild(feed);
    }
    function renderStrip() {
      var cards = visibleStrip();
      var unread = payload.unread_count || 0;
      if (!unread) {
        container.appendChild(el(doc, 'div', 'dmi-quiet', '지금 하실 일이 없습니다.'));
        return;
      }
      var head = el(doc, 'div', 'dmi-strip-head');
      head.appendChild(el(doc, 'span', 'dmi-strip-title', 'Inbox · ' + unread + ' unread'));
      var open = el(doc, 'a', 'dmi-open', 'Dev Monitor 에서 보기 ↗');
      open.href = '/monitor/'; head.appendChild(open); container.appendChild(head);
      var feed = el(doc, 'div', 'dmi-feed');
      cards.forEach(function (card) { feed.appendChild(actionRow(card, true)); });
      var more = Math.max(0, unread - cards.length);
      if (more) feed.appendChild(el(doc, 'div', 'ms-more', more + ' more'));
      container.appendChild(feed);
    }
    function render() {
      if (!payload) return;
      nodes = {}; container.textContent = ''; container.hidden = false;
      if (mode === 'strip') renderStrip(); else renderFull();
      notify(counts());
    }
    function showNotice(message) {
      notice = message;
      payload = null;
      container.textContent = '';
      container.hidden = false;
      container.appendChild(el(doc, 'div', 'dmi-empty', message));
    }
    function openTemplate(input) {
      input = input || {};
      var query = ['template', 'week', 'action', 'url'].filter(function (key) {
        return typeof input[key] === 'string' && input[key] !== '';
      }).map(function (key) {
        return encodeURIComponent(key) + '=' + encodeURIComponent(input[key]);
      }).join('&');
      return request('/run/template?' + query).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          if (res.status === 404) {
            showNotice('이 박스는 실행 콘솔이 꺼져 있습니다');
            return null;
          }
          if (!res.ok || !data.ok || !data.run) {
            throw new Error(data.error || 'Template returned ' + res.status + '.');
          }
          notice = '';
          var card = {title: data.title || input.template, level: 'normal', run: data.run};
          cardUI.openRun(card);
          return card;
        });
      }).catch(function (error) {
        toast('Template did not open (' + error.message + ').');
        return null;
      });
    }
    function refresh() {
      if (stopped) return Promise.resolve();
      var path = mode === 'strip' ? '/messages/preview' : '/messages?scope=' + (key === 'archived' ? 'archived' : 'active');
      return request(path).then(function (res) {
        if (res.status === 403 || res.status === 404) {
          if (notice) showNotice(notice);
          else { container.textContent = ''; container.hidden = true; payload = null; }
          notify({unread: 0}); return null;
        }
        if (!res.ok) throw new Error('Message feed returned ' + res.status + '.');
        return res.json().then(function (data) {
          if (!data || !Array.isArray(data.messages)) throw new Error('Message feed response is incomplete.');
          payload = data; render(); return payload;
        });
      }).catch(function (error) {
        if (!payload) {
          container.textContent = ''; container.hidden = false;
          container.appendChild(el(doc, 'div', 'dmi-empty dmi-error', '메시지를 불러올 수 없습니다: ' + error.message));
        } else toast('Message feed did not refresh (' + error.message + '); showing the last known state.');
      });
    }
    refresh();
    timer = root.setInterval(refresh, mode === 'strip' ? 30000 : 8000);
    return {refresh: refresh, openTemplate: openTemplate,
      destroy: function () { stopped = true; if (timer) root.clearInterval(timer); container.textContent = ''; }};
  }
  root.DevmonInbox = {mount: mount};
})(typeof window === 'undefined' ? globalThis : window);
