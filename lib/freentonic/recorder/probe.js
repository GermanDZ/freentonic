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
// Scope:
//   - click, change, submit (capture phase)
//   - input[type=password] values are redacted server-side; the probe
//     just flags `mask: true` so the recorder can substitute
//     `secret(...)` if it knows the name
//   - OPEN shadow DOM is in scope: events from inside an open shadow
//     root are retargeted to the host by the time they reach this
//     document-level listener, so the true origin is recovered via
//     ev.composedPath()[0] (some sites render form controls inside web
//     components — without this, every in-component click records as a
//     click on the host and fills are dropped).
//   - CLOSED shadow roots and cross-origin iframes remain out of scope:
//     composedPath() is trimmed at a closed boundary, so those events
//     degrade to the retargeted host element (visible in the recording
//     as a host-tag click).
//     `submit` and `change` are composed:false — they never cross a
//     shadow boundary at all. In-component logins are captured via their
//     button clicks; fills are captured via composed events instead —
//     `input` marks a field dirty, `focusout`/Enter emits its final value,
//     and `focusout` also emits any text-like input that just HOLDS a
//     value, so form-associated custom elements that manage the value
//     programmatically (and never fire a composed `input`) are still
//     captured (see "Fill capture" below).
//   - When DOM recording is enabled (RECORD_DOM, spliced at the marker by
//     the recorder) each interaction event carries a serialized deep DOM
//     (light + open shadow roots, attributes allowlisted) that the recorder
//     offloads to dom/<session>/NNNN.html for offline field-selector mining.
(function () {
  // Capture the binding reference into a closure, then remove the
  // global so it's not enumerable on `window`. Idempotency across
  // re-runs in the same document is handled at the Ruby layer
  // (Recorder#install only calls Page.addScriptToEvaluateOnNewDocument
  // once per session) so we don't need a window-side install guard.
  var send = window.__freentonic_rec_send__;
  if (typeof send !== "function") return;
  try { delete window.__freentonic_rec_send__; } catch (_) {}

  // Per-step DOM snapshots. The recorder splices in `true`/`false` at this
  // marker (Recorder::RECORD_DOM_MARKER). When on, each interaction event
  // carries a serialized deep DOM the recorder offloads to dom/<session>/NNNN.html.
  var RECORD_DOM = __FREENTONIC_RECORD_DOM__;

  // The shared selector heuristics — visibleText, selectorFor, cssEscape,
  // nthChildPath, describeInputValue, elementSummary (plus MAX_TEXT_LEN) —
  // are concatenated in here by Freentonic::Recorder from
  // recorder/selectors.js. Keeping them inside this IIFE (rather than
  // concatenated in front of it) preserves the probe's original scoping:
  // nothing new leaks onto `window`. The page observer concatenates the
  // exact same source, so recorded and observed selectors stay identical.
  // __FREENTONIC_SHARED_SELECTORS__

  // Serialize the deep DOM (light + OPEN shadow roots) to an HTML string,
  // capturing page STRUCTURE for offline field-selector mining. Open shadow
  // roots are emitted as declarative `<template shadowrootmode="open">` so a
  // downstream parser reconstructs the tree. Attributes pass through an
  // ALLOWLIST (SNAPSHOT_ATTRS) on every element — not a strip-list on native
  // controls — and the live `.value` property is never read. A
  // form-associated custom element may reflect a typed value onto its own
  // host (`value=`, `aria-valuetext`, a `data-*` attribute), which a
  // control-only strip-list misses; with an allowlist an unknown attribute
  // simply never lands in the file. `href` keeps its path only (query and
  // fragment can carry session tokens). Best-effort and size-capped; never
  // throws.
  var DOM_CHAR_CAP = 3 * 1024 * 1024;
  var VOID_TAGS = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
  var SKIP_TAGS = { script: 1, style: 1, noscript: 1, template: 1 };
  // Everything the shared selector heuristics read, plus the structural
  // hooks a human mines a stable selector from. Nothing value-bearing.
  var SNAPSHOT_ATTRS = {
    id: 1, name: 1, "class": 1, type: 1, role: 1, placeholder: 1,
    "aria-label": 1, "aria-labelledby": 1, "aria-describedby": 1,
    "data-testid": 1, "data-test-id": 1, "data-test": 1,
    "for": 1, href: 1, title: 1, alt: 1, autocomplete: 1, inputmode: 1,
    slot: 1, part: 1
  };

  function serializeDeep(root) {
    var out = [];
    var size = 0;

    function push(s) {
      if (size > DOM_CHAR_CAP) return;
      out.push(s);
      size += s.length;
    }
    function escText(s) {
      return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function escAttr(s) {
      return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;");
    }
    function serializeAttrs(el) {
      var s = "";
      var attrs = el.attributes || [];
      for (var i = 0; i < attrs.length; i++) {
        var name = String(attrs[i].name).toLowerCase();
        if (!SNAPSHOT_ATTRS.hasOwnProperty(name)) continue;
        var value = attrs[i].value;
        if (name === "href") value = String(value).split(/[?#]/)[0];
        s += " " + name + '="' + escAttr(value) + '"';
      }
      return s;
    }
    function serializeChildren(node) {
      var kids = node.childNodes || [];
      for (var i = 0; i < kids.length && size <= DOM_CHAR_CAP; i++) serializeNode(kids[i]);
    }
    function serializeNode(node) {
      if (size > DOM_CHAR_CAP) return;
      if (node.nodeType === 3) {
        var t = node.nodeValue;
        if (t && t.replace(/\s+/g, " ").trim()) push(escText(t));
        return;
      }
      if (node.nodeType !== 1) return;
      var tag = (node.tagName || "").toLowerCase();
      if (SKIP_TAGS[tag]) return;
      push("<" + tag + serializeAttrs(node) + ">");
      if (VOID_TAGS[tag]) return;
      if (node.shadowRoot) {
        push('<template shadowrootmode="open">');
        serializeChildren(node.shadowRoot);
        push("</template>");
      }
      serializeChildren(node);
      push("</" + tag + ">");
    }

    try { serializeNode(root); } catch (_) {}
    return out.join("");
  }

  var DOM_KINDS = { click: 1, fill: 1, submit: 1 };

  function emit(payload) {
    try {
      payload.t = Date.now();
      if (RECORD_DOM && DOM_KINDS[payload.kind] && !payload.keypad_digit) {
        try { payload.dom = serializeDeep(document.documentElement); } catch (_) {}
      }
      send(JSON.stringify(payload));
    } catch (e) {
      // Don't ever throw from the probe — page CSP errors etc. are
      // swallowed; one bad event is better than killing the loop.
    }
  }

  // ---- Listeners -----------------------------------------------------

  // The true event origin. Events from inside an OPEN shadow root are
  // retargeted to the host element by the time they surface at this
  // document-level listener; composedPath()[0] recovers the real target
  // (composedPath is trimmed at closed roots, so those degrade to the
  // retargeted host — same as the pre-shadow-aware behavior).
  function deepTarget(ev) {
    if (typeof ev.composedPath === "function") {
      var path = ev.composedPath();
      if (path && path.length && path[0] && path[0].nodeType === 1) return path[0];
    }
    return ev.target;
  }

  function isInteractiveNode(node) {
    if (!node || node.nodeType !== 1) return false;
    var t = (node.tagName || "").toLowerCase();
    return t === "button" || t === "a" || t === "input" ||
      (node.getAttribute && node.getAttribute("role") === "button");
  }

  document.addEventListener("click", function (ev) {
    // Walk up to the closest interactive element so a click on a span
    // inside a button reports the button. Prefer walking composedPath():
    // it is the full ancestor chain ACROSS shadow boundaries, so a click
    // on a decorative node inside a component still finds the component's
    // button even when they sit in different roots.
    var hit = null;
    if (typeof ev.composedPath === "function") {
      var path = ev.composedPath() || [];
      for (var i = 0; i < path.length; i++) {
        if (isInteractiveNode(path[i])) { hit = path[i]; break; }
      }
    } else {
      var node = ev.target;
      while (node && node !== document) {
        if (isInteractiveNode(node)) { hit = node; break; }
        node = node.parentElement;
      }
    }
    var el = hit || deepTarget(ev);
    // A single-digit key (a PIN keypad) records only THAT a key was
    // pressed: its text, label and selector (aria-label='7', .key-7)
    // would each put the digit in recording.jsonl, and no DOM snapshot is
    // taken since the pad's display may echo it. The compiler turns a run
    // of these into an enter_pin_pad scaffold.
    var keyLabel = visibleText(el) ||
      ((el && el.getAttribute && el.getAttribute("aria-label")) || "").trim();
    if (/^\d$/.test(keyLabel)) {
      emit({ kind: "click", keypad_digit: true, url: location.href });
      return;
    }
    var summary = elementSummary(el);
    if (!summary) return;
    summary.kind = "click";
    // Record the input type on clicks too, so the compiler can tell a
    // text field (which may be a managed input the user typed into but whose
    // value we couldn't capture) from a checkbox/radio/button.
    if ((el.tagName || "").toLowerCase() === "input") {
      summary.input_type = (el.type || "").toLowerCase();
    }
    summary.url = location.href;
    emit(summary);
  }, true);

  // ---- Fill capture ---------------------------------------------------
  //
  // `change` is composed:false — fired inside a shadow root it never
  // crosses the boundary, so a document-level listener NEVER sees it. `input`
  // and `focusout` ARE composed, so the strategy is: `input` marks the field
  // dirty (no emission — one event per keystroke would spray partial values),
  // and `focusout`/Enter emits the field's final value once.
  //
  // Some form-associated custom elements set the value programmatically or
  // swallow the native `input` event, so `dirty` is never set. So
  // `focusout`/Enter ALSO emit a text-like input that simply HOLDS a value —
  // dirty OR non-empty. A per-field `emitted` guard (reset when the user
  // edits again) dedupes the change+focusout pair and the dirty+has-value
  // overlap. Fills are restricted to text-entry controls (fillableControl):
  // radio/checkbox/button are click-driven, never filled.
  //
  // NOTE: a field whose value a component keeps ONLY in ElementInternals /
  // JS state (not on the inner <input>.value) still can't be captured — the
  // value isn't observable from outside. Such a field records a click but no
  // fill, so it's a one-line hand-add (`fill … value: secret(...)`) with the
  // selector inspect_page / the DOM snapshot surfaces. Chasing per-component
  // internals isn't worth it.
  var dirtyFills = new WeakSet();
  var emittedFills = new WeakSet();

  // Types whose value is text the user entered (vs. checkbox/radio/button
  // whose "value" is a fixed attribute — those are captured by click/change,
  // not by the has-value focusout path, which would fire on every blur).
  var TEXTLIKE_TYPES = {
    "": 1, text: 1, email: 1, tel: 1, number: 1, password: 1, search: 1,
    url: 1, date: 1, "datetime-local": 1, month: 1, week: 1, time: 1
  };

  // A control whose value is text the user typed — a text-like <input> or a
  // <textarea>. Radio/checkbox/button/submit carry a FIXED `value` attribute
  // and are captured by click, never as a fill: a fill on a radio is noise,
  // and a radio whose name matches a sensitive-field pattern would even mask
  // as a bogus secret. Only these controls ever produce a fill event.
  function fillableControl(el) {
    if (!el) return false;
    var tag = (el.tagName || "").toLowerCase();
    if (tag === "textarea") return true;
    if (tag !== "input") return false;
    return !!TEXTLIKE_TYPES[(el.type || "").toLowerCase()];
  }

  function holdsEnteredValue(el) {
    try {
      if (!fillableControl(el)) return false;
      return typeof el.value === "string" && el.value.length > 0;
    } catch (_) {
      return false;
    }
  }

  function emitFill(el) {
    if (!fillableControl(el)) return;
    if (emittedFills.has(el)) return; // already recorded this edit
    dirtyFills.delete(el);
    emittedFills.add(el);
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
  }

  document.addEventListener("input", function (ev) {
    var el = deepTarget(ev);
    if (fillableControl(el)) {
      dirtyFills.add(el);
      emittedFills.delete(el); // a fresh edit may re-emit with the new value
    }
  }, true);

  document.addEventListener("change", function (ev) {
    emitFill(deepTarget(ev));
  }, true);

  document.addEventListener("focusout", function (ev) {
    var el = deepTarget(ev);
    if (el && (dirtyFills.has(el) || holdsEnteredValue(el))) emitFill(el);
  }, true);

  // Enter can submit-and-navigate before any focusout fires; flush the
  // field being edited so the last fill isn't lost to the unload.
  document.addEventListener("keydown", function (ev) {
    if (ev.key !== "Enter") return;
    var el = deepTarget(ev);
    if (el && (dirtyFills.has(el) || holdsEnteredValue(el))) emitFill(el);
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
