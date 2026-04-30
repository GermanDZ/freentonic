// Freentonic recording probe.
//
// Injected via CDP `Page.addScriptToEvaluateOnNewDocument` before any
// page script runs. Listens at document level with `capture: true` so
// it sees events even when the page intercepts them earlier in the
// bubble path. Each event is shipped out to the freentonic Ruby
// recorder via `console.info("__freentonic_rec__:" + JSON)` — that
// surfaces on the CDP `Runtime.consoleAPICalled` channel which the
// recorder drains every tick.
//
// Scope (v1):
//   - click, change, submit (capture phase)
//   - input[type=password] values are redacted server-side; the probe
//     just flags `mask: true` so the recorder can substitute
//     `secret(...)` if it knows the name
//   - shadow DOM and cross-origin iframes are out of scope. We log a
//     `kind: "skipped"` entry the first time we notice a closed shadow
//     boundary so the operator knows the trail goes cold there.
//
// All emitted output is JSON; the recorder ignores any console line
// that doesn't start with the magic prefix.
(function () {
  if (window.__freentonic_recorder_installed__) return;
  window.__freentonic_recorder_installed__ = true;

  var PREFIX = "__freentonic_rec__:";
  var MAX_TEXT_LEN = 80;

  function emit(payload) {
    try {
      payload.t = Date.now();
      console.info(PREFIX + JSON.stringify(payload));
    } catch (e) {
      // Don't ever throw from the probe — page CSP errors etc. are
      // swallowed; one bad event is better than killing the loop.
    }
  }

  function visibleText(el) {
    if (!el) return "";
    var text = (el.textContent || "").replace(/\s+/g, " ").trim();
    if (text.length > MAX_TEXT_LEN) text = text.slice(0, MAX_TEXT_LEN) + "…";
    return text;
  }

  // Derive a candidate CSS selector for an element. Returns
  // { css, strategy, needs_review }. `strategy` reports which heuristic
  // matched so the operator can spot fragile picks.
  function selectorFor(el) {
    if (!el || el.nodeType !== 1) return { css: "", strategy: "none", needs_review: true };

    var doc = el.ownerDocument || document;
    var tag = (el.tagName || "").toLowerCase();

    // 1. id, if unique and reasonably stable-looking
    var id = el.getAttribute && el.getAttribute("id");
    if (id && /^[A-Za-z][\w-]{0,79}$/.test(id)) {
      try {
        if (doc.querySelectorAll("#" + cssEscape(id)).length === 1) {
          return { css: "#" + cssEscape(id), strategy: "id", needs_review: false };
        }
      } catch (_) {}
    }

    // 2. data-testid (or any data-test-*)
    var testid = el.getAttribute && (el.getAttribute("data-testid") || el.getAttribute("data-test-id") || el.getAttribute("data-test"));
    if (testid) {
      var attr = el.getAttribute("data-testid") ? "data-testid"
              : el.getAttribute("data-test-id") ? "data-test-id"
              : "data-test";
      var sel = tag + "[" + attr + "='" + cssEscape(testid) + "']";
      try {
        if (doc.querySelectorAll(sel).length === 1) {
          return { css: sel, strategy: "testid", needs_review: false };
        }
      } catch (_) {}
    }

    // 3. name (typical for inputs)
    var name = el.getAttribute && el.getAttribute("name");
    if (name) {
      var nsel = tag + "[name='" + cssEscape(name) + "']";
      try {
        if (doc.querySelectorAll(nsel).length === 1) {
          return { css: nsel, strategy: "name", needs_review: false };
        }
      } catch (_) {}
    }

    // 4. aria-label
    var aria = el.getAttribute && el.getAttribute("aria-label");
    if (aria) {
      var asel = tag + "[aria-label='" + cssEscape(aria) + "']";
      try {
        if (doc.querySelectorAll(asel).length === 1) {
          return { css: asel, strategy: "aria-label", needs_review: false };
        }
      } catch (_) {}
    }

    // 5. nth-child path under nearest stable ancestor (id or data-testid).
    //    Always flagged needs_review — these break the moment a sibling
    //    is added.
    var path = nthChildPath(el);
    return { css: path, strategy: "nth-child", needs_review: true };
  }

  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === "function") {
      return window.CSS.escape(value);
    }
    return String(value).replace(/['"\\]/g, "\\$&");
  }

  function nthChildPath(el) {
    var parts = [];
    var node = el;
    var depth = 0;
    while (node && node.nodeType === 1 && depth < 8) {
      var seg = node.tagName.toLowerCase();
      var parent = node.parentElement;
      if (parent) {
        var idx = 1;
        var sib = node;
        while ((sib = sib.previousElementSibling)) {
          if (sib.tagName === node.tagName) idx++;
        }
        seg += ":nth-of-type(" + idx + ")";
      }
      parts.unshift(seg);
      // Stop at an ancestor with a stable hook
      if (parent) {
        var pid = parent.getAttribute && parent.getAttribute("id");
        if (pid && /^[A-Za-z][\w-]{0,79}$/.test(pid)) {
          parts.unshift("#" + cssEscape(pid));
          break;
        }
        var ptid = parent.getAttribute && parent.getAttribute("data-testid");
        if (ptid) {
          parts.unshift(parent.tagName.toLowerCase() + "[data-testid='" + cssEscape(ptid) + "']");
          break;
        }
      }
      node = parent;
      depth++;
    }
    return parts.join(" > ");
  }

  function describeInputValue(el) {
    if (!el) return { mask: false, value: "" };
    var type = (el.type || "").toLowerCase();
    var name = (el.name || "").toLowerCase();
    var ac = (el.autocomplete || "").toLowerCase();
    var sensitive =
      type === "password" ||
      ac === "current-password" ||
      ac === "new-password" ||
      ac === "one-time-code" ||
      /password|pwd|otp|sms|2fa|cvv|cvc|secret|token|pin/.test(name);
    if (sensitive) return { mask: true, value: "" };
    var v = el.value;
    if (typeof v !== "string") return { mask: false, value: "" };
    if (v.length > 200) v = v.slice(0, 200) + "…";
    return { mask: false, value: v };
  }

  function elementSummary(el) {
    if (!el) return null;
    var s = selectorFor(el);
    var summary = {
      tag: (el.tagName || "").toLowerCase(),
      selector: s.css,
      selector_strategy: s.strategy,
      needs_review: s.needs_review
    };
    var text = visibleText(el);
    if (text) summary.text = text;
    var role = el.getAttribute && el.getAttribute("role");
    if (role) summary.role = role;
    var href = el.getAttribute && el.getAttribute("href");
    if (href) summary.href = href;
    return summary;
  }

  // ---- Listeners -----------------------------------------------------

  document.addEventListener("click", function (ev) {
    var target = ev.target;
    // Walk up to the closest interactive element so a click on a span
    // inside a button reports the button.
    var hit = target;
    while (hit && hit !== document) {
      var t = (hit.tagName || "").toLowerCase();
      if (t === "button" || t === "a" || t === "input" ||
          (hit.getAttribute && hit.getAttribute("role") === "button")) {
        break;
      }
      hit = hit.parentElement;
    }
    var el = hit && hit !== document ? hit : target;
    var summary = elementSummary(el);
    if (!summary) return;
    summary.kind = "click";
    summary.url = location.href;
    emit(summary);
  }, true);

  document.addEventListener("change", function (ev) {
    var el = ev.target;
    if (!el || (el.tagName || "").toLowerCase() !== "input") return;
    var summary = elementSummary(el);
    if (!summary) return;
    var v = describeInputValue(el);
    summary.kind = "fill";
    summary.input_type = (el.type || "").toLowerCase();
    summary.url = location.href;
    if (v.mask) {
      summary.mask = true;
    } else {
      summary.value = v.value;
    }
    emit(summary);
  }, true);

  document.addEventListener("submit", function (ev) {
    var summary = elementSummary(ev.target);
    if (!summary) return;
    summary.kind = "submit";
    summary.url = location.href;
    emit(summary);
  }, true);

  emit({ kind: "probe_ready", url: location.href });
})();
