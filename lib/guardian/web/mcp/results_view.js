(function () {
  "use strict";

  // The query results view's only script. Guardian renders each result's table as
  // HTML on the server and sends it in the tool result's _meta; this script talks to
  // the host over postMessage (MCP Apps, JSON-RPC 2.0) and swaps that HTML in. It
  // makes no network requests and calls no tools.
  var HTML_KEY = "guardian/html";
  var target = document.getElementById("results");
  var host = window.parent;
  var nextId = 1;
  var pending = {};
  var initialized = false;
  var lastWidth = 0;
  var lastHeight = 0;
  var sizeScheduled = false;

  function send(message) {
    host.postMessage(message, "*");
  }

  function request(method, params) {
    var id = nextId++;
    send({ jsonrpc: "2.0", id: id, method: method, params: params });
    return new Promise(function (resolve, reject) {
      pending[id] = { resolve: resolve, reject: reject };
    });
  }

  function notify(method, params) {
    send({ jsonrpc: "2.0", method: method, params: params });
  }

  function showText(text) {
    var p = document.createElement("p");
    p.className = "note";
    p.textContent = text;
    target.replaceChildren(p);
  }

  // Host styling: the theme sets the color scheme, and the standard CSS variables
  // override the stylesheet's fallbacks. Host CSS blocks and fonts are not applied.
  function applyHostContext(context) {
    if (!context || typeof context !== "object") return;
    var root = document.documentElement;
    if (context.theme === "light" || context.theme === "dark") {
      root.style.colorScheme = context.theme;
    }
    var variables = context.styles && context.styles.variables;
    if (variables && typeof variables === "object") {
      Object.keys(variables).forEach(function (name) {
        var value = variables[name];
        if (name.indexOf("--") === 0 && typeof value === "string") {
          root.style.setProperty(name, value);
        }
      });
    }
  }

  function showResult(result) {
    var html = result && result._meta && result._meta[HTML_KEY];
    if (typeof html === "string") {
      // Guardian escapes every value; the page's CSP also refuses any script but
      // this one, so markup can't run code.
      target.innerHTML = html;
    } else {
      showText("This result has no table view.");
    }
  }


  // Sizes go to the host only after the handshake.
  function reportSize() {
    if (!initialized || sizeScheduled) return;
    sizeScheduled = true;
    // A timer rather than requestAnimationFrame, which hosts may not run for a
    // frame that is offscreen or not yet visible.
    setTimeout(function () {
      sizeScheduled = false;
      var root = document.documentElement;
      var original = root.style.height;
      root.style.height = "max-content";
      var height = Math.ceil(root.getBoundingClientRect().height);
      root.style.height = original;
      var width = Math.ceil(window.innerWidth);
      if (width !== lastWidth || height !== lastHeight) {
        lastWidth = width;
        lastHeight = height;
        notify("ui/notifications/size-changed", { width: width, height: height });
      }
    }, 0);
  }

  window.addEventListener("message", function (event) {
    if (event.source !== host) return;
    var message = event.data;
    if (!message || message.jsonrpc !== "2.0") return;

    if (message.method === undefined && message.id !== undefined) {
      var waiter = pending[message.id];
      if (!waiter) return;
      delete pending[message.id];
      if (message.error) waiter.reject(message.error);
      else waiter.resolve(message.result);
      return;
    }

    var params = message.params || {};

    if (message.id !== undefined) {
      // Requests from the host: answer the ones the view supports, refuse the rest.
      if (message.method === "ping" || message.method === "ui/resource-teardown") {
        send({ jsonrpc: "2.0", id: message.id, result: {} });
      } else {
        send({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32601, message: "Method not found" },
        });
      }
      return;
    }

    switch (message.method) {
      case "ui/notifications/tool-result":
        showResult(params);
        reportSize();
        break;
      case "ui/notifications/tool-cancelled":
        showText("The query was cancelled.");
        reportSize();
        break;
      case "ui/notifications/host-context-changed":
        applyHostContext(params);
        reportSize();
        break;
    }
  });

  if (typeof ResizeObserver === "function") {
    var observer = new ResizeObserver(reportSize);
    observer.observe(document.documentElement);
    observer.observe(document.body);
  }

  request("ui/initialize", {
    appInfo: { name: "guardian-query-results", version: "1" },
    appCapabilities: {},
    protocolVersion: "2026-01-26",
  }).then(
    function (result) {
      applyHostContext(result && result.hostContext);
      notify("ui/notifications/initialized", {});
      initialized = true;
      reportSize();
    },
    function () {
      showText("The host did not accept this view.");
    }
  );
})();
