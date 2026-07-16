// Freentonic page observer.
//
// Evaluated on-demand by Freentonic::PageObserver (NOT injected as a
// persistent document script). Concatenated after DEEP_QUERY_FN and the
// shared selector heuristics (recorder/selectors.js), then returned as a
// JSON string so Ruby can JSON.parse it.
//
// Walks the visible interactive elements — a, button, input, select,
// [role=button] — piercing shadow roots and same-origin iframes the same
// way DEEP_QUERY_FN does, runs the shared elementSummary on each, and for
// inputs adds `type`, `label`, and a `masked` flag (derived from
// describeInputValue).
//
// SECURITY: an element's *value* is NEVER included. Only its selector,
// label, and the boolean `masked` flag leave the page. This is what lets
// the inventory (and failures.ndjson) be persisted next to run logs.
(() => {
  var MAX_ELEMENTS = 500;

  function isVisible(el) {
    if (!el || el.nodeType !== 1) return false;
    var rect;
    try { rect = el.getBoundingClientRect(); } catch (_) { return false; }
    if (!rect) return false;
    if (rect.width === 0 && rect.height === 0) return false;
    var view = (el.ownerDocument && el.ownerDocument.defaultView) || window;
    var style = null;
    try { style = view.getComputedStyle(el); } catch (_) { style = null; }
    if (style && (style.visibility === "hidden" || style.display === "none")) return false;
    return true;
  }

  function isInteractive(el) {
    var tag = (el.tagName || "").toLowerCase();
    if (tag === "a" || tag === "button" || tag === "input" || tag === "select") return true;
    var role = el.getAttribute && el.getAttribute("role");
    return role === "button";
  }

  function inputLabel(el) {
    var aria = el.getAttribute && el.getAttribute("aria-label");
    if (aria && aria.trim()) return aria.trim();
    var id = el.getAttribute && el.getAttribute("id");
    if (id) {
      try {
        var lbl = (el.ownerDocument || document).querySelector("label[for='" + cssEscape(id) + "']");
        if (lbl) { var t = visibleText(lbl); if (t) return t; }
      } catch (_) {}
    }
    var ph = el.getAttribute && el.getAttribute("placeholder");
    if (ph && ph.trim()) return ph.trim();
    var name = el.getAttribute && el.getAttribute("name");
    if (name && name.trim()) return name.trim();
    return "";
  }

  var results = [];

  function collect(root) {
    if (!root || results.length >= MAX_ELEMENTS) return;
    var all;
    try { all = root.querySelectorAll ? root.querySelectorAll("*") : []; } catch (_) { all = []; }
    for (var i = 0; i < all.length; i++) {
      if (results.length >= MAX_ELEMENTS) return;
      var el = all[i];
      if (isInteractive(el) && isVisible(el)) {
        var summary = elementSummary(el);
        if (summary) {
          var tag = (el.tagName || "").toLowerCase();
          if (tag === "input" || tag === "select") {
            summary.type = (el.type || tag).toLowerCase();
            var label = inputLabel(el);
            if (label) summary.label = label;
            // Read ONLY the mask flag — never describeInputValue().value.
            summary.masked = !!describeInputValue(el).mask;
          }
          results.push(summary);
        }
      }
      // Pierce shadow roots and same-origin iframes (mirrors DEEP_QUERY_FN).
      if (el.shadowRoot) collect(el.shadowRoot);
      if (el.tagName === "IFRAME" || el.tagName === "FRAME") {
        var doc = null;
        try { doc = el.contentDocument; } catch (_) { doc = null; }
        if (doc) collect(doc);
      }
    }
  }

  collect(document);

  return JSON.stringify({
    url: location.href,
    title: document.title || "",
    interactive: results
  });
})()
