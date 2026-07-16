// Freentonic recording probe.
//
// Injected via CDP `Page.addScriptToEvaluateOnNewDocument` before any
// page script runs. Listens at document level with `capture: true` so
// it sees events even when the page intercepts them earlier in the
// bubble path.
//
// Exfiltration uses a CDP `Runtime.addBinding` channel (registered by
// the Ruby recorder before any document loads): Chrome auto-exposes
// the binding as a global function on every new document; the probe
// captures the reference into a closure and deletes the global
// immediately so page scripts that enumerate `window` or hook
// `console.*` can't see it. Events surface server-side as
// `Runtime.bindingCalled` frames — invisible to the page either way.
//
// Scope (v1):
//   - click, change, submit (capture phase)
//   - input[type=password] values are redacted server-side; the probe
//     just flags `mask: true` so the recorder can substitute
//     `secret(...)` if it knows the name
//   - shadow DOM and cross-origin iframes are out of scope. We log a
//     `kind: "skipped"` entry the first time we notice a closed shadow
//     boundary so the operator knows the trail goes cold there.
(function () {
  // Capture the binding reference into a closure, then remove the
  // global so it's not enumerable on `window`. Idempotency across
  // re-runs in the same document is handled at the Ruby layer
  // (Recorder#install only calls Page.addScriptToEvaluateOnNewDocument
  // once per session) so we don't need a window-side install guard.
  var send = window.__freentonic_rec_send__;
  if (typeof send !== "function") return;
  try { delete window.__freentonic_rec_send__; } catch (_) {}

  // The shared selector heuristics — visibleText, selectorFor, cssEscape,
  // nthChildPath, describeInputValue, elementSummary (plus MAX_TEXT_LEN) —
  // are concatenated in here by Freentonic::Recorder from
  // recorder/selectors.js. Keeping them inside this IIFE (rather than
  // concatenated in front of it) preserves the probe's original scoping:
  // nothing new leaks onto `window`. The page observer concatenates the
  // exact same source, so recorded and observed selectors stay identical.
  // __FREENTONIC_SHARED_SELECTORS__

  function emit(payload) {
    try {
      payload.t = Date.now();
      send(JSON.stringify(payload));
    } catch (e) {
      // Don't ever throw from the probe — page CSP errors etc. are
      // swallowed; one bad event is better than killing the loop.
    }
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
