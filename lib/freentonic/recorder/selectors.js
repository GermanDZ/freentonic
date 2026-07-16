// Freentonic shared selector heuristics.
//
// Pure functions of an element / owner document with no dependency on
// any recorder binding or observer state. This source is concatenated
// verbatim into BOTH the recording probe (recorder/probe.js) and the
// page observer (page_observer/observe.js) so the selector a run
// *records* and the selector a run can later *act on* are derived by
// exactly the same code. Keep these behavior-preserving: the probe's
// recording tests lean on this having been a byte-identical extraction.
//
// Exposed (as scoped functions once concatenated inside a wrapper):
//   visibleText, selectorFor, cssEscape, nthChildPath,
//   describeInputValue, elementSummary
//
// SECURITY: describeInputValue can return a raw non-sensitive input
// value — the observer deliberately reads only its `mask` flag and
// NEVER surfaces the `value`.

var MAX_TEXT_LEN = 80;

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
  // Masking is the ONLY barrier keeping a recorded credential out of
  // recording.jsonl and the compiled draft YAML, so err toward masking:
  // cover payment-card fields (PAN/expiry/CVC), account/IBAN numbers, and
  // generic OTP/verification fields in addition to passwords.
  var sensitive =
    type === "password" ||
    ac === "current-password" ||
    ac === "new-password" ||
    ac === "one-time-code" ||
    ac.indexOf("cc-") === 0 ||
    /password|pwd|otp|sms|2fa|cvv|cvc|secret|token|pin|card.?num|cardnumber|\bpan\b|iban|account.?num|expir|verification|\bcode\b/.test(name);
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
