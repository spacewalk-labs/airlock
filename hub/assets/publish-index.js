(function () {
  "use strict";

  var source = document.querySelector("body > pre");
  if (!source) return;

  function parseRows(html) {
    return html.split("\n").map(function (line) {
      var holder = document.createElement("div");
      holder.innerHTML = line;
      var anchor = holder.querySelector("a");
      if (!anchor) return null;
      var href = anchor.getAttribute("href") || "";
      if (!href || href === "../" || href.charAt(0) === "?") return null;
      var tail = holder.textContent.slice(anchor.textContent.length);
      var match = tail.match(/(\d{2}-[A-Za-z]{3}-\d{4})\s+(\d{2}:\d{2})\s+(\d+|-)/);
      var clean = href.split("?")[0].split("#")[0];
      var name;
      try { name = decodeURIComponent(clean.replace(/\/$/, "").split("/").pop()); }
      catch (_) { name = anchor.textContent.replace(/\/$/, ""); }
      return {
        href: href,
        name: name || anchor.textContent.replace(/\/$/, ""),
        folder: /\/$/.test(clean),
        date: match ? match[1] + " " + match[2] : "",
        stamp: match ? Date.parse(match[1] + " " + match[2]) || 0 : 0
      };
    }).filter(Boolean).filter(function (row) {
      return row.href !== "/airlock-index.css" && row.href !== "/airlock-index.js";
    });
  }

  var rows = parseRows(source.innerHTML);
  var documents = rows.filter(function (row) { return !row.folder && /\.html?$/i.test(row.name); });
  var files = rows.filter(function (row) { return !row.folder && !/\.html?$/i.test(row.name); });
  var folders = rows.filter(function (row) { return row.folder; });
  documents.sort(function (a, b) { return b.stamp - a.stamp || a.name.localeCompare(b.name); });
  files.sort(function (a, b) { return b.stamp - a.stamp || a.name.localeCompare(b.name); });
  folders.sort(function (a, b) { return a.name.localeCompare(b.name); });

  function icon(folder) {
    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "publish-icon"); svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    var path = document.createElementNS(svg.namespaceURI, "path");
    path.setAttribute("fill", "currentColor");
    path.setAttribute("d", folder
      ? "M3 6.5a2 2 0 0 1 2-2h4l2 2H19a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"
      : "M6 2.75h8l4 4V21H6Zm8 1.8v3.2h3.2M8.5 12h7M8.5 15.5h7");
    svg.appendChild(path); return svg;
  }

  function section(title, items) {
    var wrap = document.createElement("section"); wrap.className = "publish-section";
    var heading = document.createElement("h2"); heading.className = "publish-section-title";
    heading.textContent = title; wrap.appendChild(heading);
    var list = document.createElement("ul"); list.className = "publish-list";
    items.forEach(function (row) {
      var item = document.createElement("li"); item.className = "publish-item";
      item.dataset.search = row.name.toLocaleLowerCase();
      var link = document.createElement("a"); link.className = "publish-link"; link.href = row.href;
      var main = document.createElement("span"); main.className = "publish-main"; main.appendChild(icon(row.folder));
      var name = document.createElement("span"); name.className = "publish-name"; name.textContent = row.name;
      main.appendChild(name); link.appendChild(main);
      var meta = document.createElement("span"); meta.className = "publish-meta";
      meta.textContent = row.date || (row.folder ? "Folder" : "Document"); link.appendChild(meta);
      item.appendChild(link); list.appendChild(item);
    });
    wrap.appendChild(list); return wrap;
  }

  var app = document.createElement("main"); app.className = "publish-index";
  var head = document.createElement("header"); head.className = "publish-head";
  var titles = document.createElement("div");
  var h1 = document.createElement("h1"); h1.className = "publish-title"; h1.textContent = "Shared documents";
  var sub = document.createElement("p"); sub.className = "publish-subtitle"; sub.textContent = "Files published from this Airlock";
  titles.appendChild(h1); titles.appendChild(sub); head.appendChild(titles);
  var count = document.createElement("span"); count.className = "publish-count";
  count.textContent = documents.length + " documents"; head.appendChild(count); app.appendChild(head);

  var search = document.createElement("div"); search.className = "publish-search";
  search.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m21 21-4.35-4.35m2.35-5.15a7.5 7.5 0 1 1-15 0 7.5 7.5 0 0 1 15 0Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
  var input = document.createElement("input"); input.type = "search"; input.placeholder = "Search documents and folders";
  input.setAttribute("aria-label", "Search documents and folders"); search.appendChild(input); app.appendChild(search);
  if (documents.length) app.appendChild(section("Documents", documents));
  if (files.length) app.appendChild(section("Files", files));
  if (folders.length) app.appendChild(section("Folders", folders));
  var empty = document.createElement("p"); empty.className = "publish-empty"; empty.hidden = rows.length !== 0;
  empty.textContent = "No matching documents or folders."; app.appendChild(empty);

  document.body.insertBefore(app, document.body.firstChild);
  Array.prototype.forEach.call(document.body.children, function (child) {
    if (child !== app && child.tagName !== "SCRIPT") child.hidden = true;
  });
  input.addEventListener("input", function () {
    var query = input.value.trim().toLocaleLowerCase(); var visible = 0;
    app.querySelectorAll(".publish-item").forEach(function (item) {
      item.hidden = query && item.dataset.search.indexOf(query) === -1;
      if (!item.hidden) visible += 1;
    });
    app.querySelectorAll(".publish-section").forEach(function (part) {
      part.hidden = !part.querySelector(".publish-item:not([hidden])");
    });
    empty.hidden = visible !== 0;
  });
})();
