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
//   visibleText, selectorRoot, looksRandomToken, looksGeneratedId,
//   selectorFor, cssEscape, nthChildPath, describeInputValue, elementSummary
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

// A label that names one digit: "7", "Digit 7", "Tecla 7", "Número 7".
var KEYPAD_LABEL = /^(?:(?:digit|d[ií]gito|key|tecla|number|n[uú]mero|num)\s*)?\d$/i;
// A selector that carries one digit after a key-ish word: #key7,
// .btn-7, [data-testid='digit-7'], [data-key='7'].
var KEYPAD_SELECTOR = /(?:key|digit|tecla|pin|num|btn|button)[-_='"\s]*\d(?!\d)/i;

// Is `el` a single-digit key of a PIN keypad? Checked on every place a key
// shows or names its digit — its text, an <input type=button>'s value,
// aria-label, title, alt (its own or an image inside it), and the selector
// we'd record for it — since any one of them would leak the digit.
function isKeypadKey(el) {
  if (!el) return false;
  var attr = function (node, n) { return (node && node.getAttribute && node.getAttribute(n)) || ""; };
  var img = el.querySelector ? el.querySelector("img") : null;
  var tag = (el.tagName || "").toLowerCase();
  var labels = [
    visibleText(el),
    tag === "input" ? (el.value || "") : "",
    attr(el, "aria-label"), attr(el, "title"), attr(el, "alt"), attr(img, "alt")
  ];
  for (var i = 0; i < labels.length; i++) {
    if (KEYPAD_LABEL.test(String(labels[i]).trim())) return true;
  }
  return KEYPAD_SELECTOR.test(selectorFor(el).css || "");
}

// Derive a candidate CSS selector for an element. Returns
// { css, strategy, needs_review }. `strategy` reports which heuristic
// matched so the operator can spot fragile picks.
//
// Uniqueness is checked against the element's ROOT NODE — the ShadowRoot
// for an element inside one, the document otherwise. That scope matches
// how the runner replays selectors: DEEP_QUERY_FN evaluates the selector
// inside the document and then inside every open shadow root, so a
// selector unique within its own root is the replayable unit. Checking
// against ownerDocument (the old behavior) can't see into shadow roots
// at all — every in-shadow uniqueness probe returned 0 matches and even
// elements with a perfectly stable id fell through to the fragile
// nth-child path.
function selectorRoot(el) {
  if (el && typeof el.getRootNode === "function") {
    var root = el.getRootNode();
    if (root && root.querySelectorAll) return root;
  }
  return (el && el.ownerDocument) || document;
}

// Does an id segment look machine-generated (a per-render random token)
// rather than an authored, stable identifier? Some component frameworks emit
// ids of the form `<prefix>-<random>` whose suffix regenerates on every page
// load — using them as selectors is a trap (they look precise, break next
// visit). We flag a token as random when it interleaves digits with letters
// in a non-"word+number" way, or packs a run of consonants no real word
// would. Deliberately conservative: a false positive only means we prefer a
// stable attribute (name/placeholder/aria) or flag the id, while a false
// negative silently ships a volatile selector.
function looksRandomToken(seg) {
  if (!seg || seg.length < 6) return false;
  // 6+ consecutive consonants (vowels a/e/i/o/u AND y break the run) —
  // catches all-consonant random tokens that dodge the digit test.
  if (/[bcdfghjklmnpqrstvwxz]{6,}/i.test(seg)) return true;
  var hasDigit = /\d/.test(seg);
  var hasAlpha = /[a-z]/i.test(seg);
  if (hasDigit && hasAlpha) {
    // "password0", "heading2", "md5" — a word with a trailing/leading
    // counter is a legitimate, stable id. Not random.
    if (/^[a-z]+\d+$/i.test(seg)) return false;
    if (/^\d+[a-z]+$/i.test(seg)) return false;
    // Digits interleaved through the token (e.g. "a1b2c3d4e5").
    return true;
  }
  return false;
}

function looksGeneratedId(id) {
  var segs = String(id).split(/[-_]/);
  for (var i = 0; i < segs.length; i++) {
    if (looksRandomToken(segs[i])) return true;
  }
  return false;
}

function selectorFor(el) {
  if (!el || el.nodeType !== 1) return { css: "", strategy: "none", needs_review: true };

  var doc = selectorRoot(el);
  var tag = (el.tagName || "").toLowerCase();

  var id = el.getAttribute && el.getAttribute("id");
  var idOk = id && /^[A-Za-z][\w-]{0,79}$/.test(id);

  // 1. id, if unique and NOT machine-generated. A generated id is skipped
  //    here so the stable attributes below win; it returns (flagged) only as
  //    a last resort at step 6.
  if (idOk && !looksGeneratedId(id)) {
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

  // 4. placeholder (inputs with no id/name but a stable placeholder — e.g.
  //    date-part fields whose only durable hook is `placeholder="DD"`).
  var ph = el.getAttribute && el.getAttribute("placeholder");
  if (ph) {
    var psel = tag + "[placeholder='" + cssEscape(ph) + "']";
    try {
      if (doc.querySelectorAll(psel).length === 1) {
        return { css: psel, strategy: "placeholder", needs_review: false };
      }
    } catch (_) {}
  }

  // 5. aria-label
  var aria = el.getAttribute && el.getAttribute("aria-label");
  if (aria) {
    var asel = tag + "[aria-label='" + cssEscape(aria) + "']";
    try {
      if (doc.querySelectorAll(asel).length === 1) {
        return { css: asel, strategy: "aria-label", needs_review: false };
      }
    } catch (_) {}
  }

  // 6. a unique-but-machine-generated id. Better than an nth-child path for
  //    THIS recording (it pins the exact element, so a reviewer can grep the
  //    DOM snapshot for it), but flagged: the suffix regenerates next load.
  //    strategy "id-volatile" so the compiler warns to swap in a stable attr.
  if (idOk) {
    try {
      if (doc.querySelectorAll("#" + cssEscape(id)).length === 1) {
        return { css: "#" + cssEscape(id), strategy: "id-volatile", needs_review: true };
      }
    } catch (_) {}
  }

  // 7. nth-child path under nearest stable ancestor (id or data-testid).
  //    Always flagged needs_review — these break the moment a sibling
  //    is added. Inside a shadow root the walk stops at the root
  //    boundary, so the path stays root-scoped (replayable by
  //    DEEP_QUERY_FN within that root).
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
    // Stop at an ancestor with a stable hook — but not a machine-generated
    // id, which would just anchor the path on another volatile token.
    if (parent) {
      var pid = parent.getAttribute && parent.getAttribute("id");
      if (pid && /^[A-Za-z][\w-]{0,79}$/.test(pid) && !looksGeneratedId(pid)) {
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

// Field hints that make a value a credential or PII: passwords, OTP and
// verification codes, payment cards (PAN/expiry/CVC), account/IBAN
// numbers, national-ID / document numbers (dni/nif/nie/document) and login
// identifiers (user, usuario, clave). Short words only need a leading
// boundary, so compounds still match (dni_number, documentnumber,
// user_dni); over-masking costs a REVIEW edit in the draft, under-masking
// leaks a value into recording.jsonl.
var SENSITIVE_HINT = /password|passwd|pwd|passcode|contrase|clave|otp|sms|2fa|cvv|cvc|secret|token|pin|card.?num|iban|account.?num|expir|verification|usuario|user.?name|user.?id|login|(^|[^a-z])(pan|code|dni|nif|nie|document)/;

function describeInputValue(el) {
  if (!el) return { mask: false, value: "" };
  var type = (el.type || "").toLowerCase();
  var ac = (el.autocomplete || "").toLowerCase();
  var attr = function (n) { return (el.getAttribute && el.getAttribute(n)) || ""; };
  // Masking is the ONLY barrier keeping a recorded credential out of
  // recording.jsonl and the compiled draft YAML, so err toward masking, and
  // read every attribute a page names a field by — not just name.
  var hints = [el.name || "", el.id || "", attr("placeholder"), attr("aria-label"), ac]
    .join(" ").toLowerCase();
  var sensitive =
    type === "password" ||
    ac === "current-password" ||
    ac === "new-password" ||
    ac === "one-time-code" ||
    ac.indexOf("cc-") === 0 ||
    SENSITIVE_HINT.test(hints);
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
  // Flag elements that live inside a shadow root: their selector is
  // root-scoped (a plain document.querySelector won't reach them — the
  // runner's deepQuery will). Lets a reviewer/authoring agent know why a
  // selector might not match in the browser console.
  if (typeof el.getRootNode === "function") {
    var rn = el.getRootNode();
    if (rn && rn.host) summary.shadow = true;
  }
  var text = visibleText(el);
  if (text) summary.text = text;
  var role = el.getAttribute && el.getAttribute("role");
  if (role) summary.role = role;
  var href = el.getAttribute && el.getAttribute("href");
  if (href) summary.href = href;
  return summary;
}
