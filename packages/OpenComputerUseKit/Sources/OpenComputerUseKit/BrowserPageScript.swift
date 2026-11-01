/// Installed into a page once per document. Refs stay stable for an element's
/// lifetime in that document, so a later snapshot can be diffed against an earlier one.
let browserPageScript = #"""
(() => {
  if (window.__ocu && window.__ocu.v === 1) return;
  const refs = new Map();
  const ids = new WeakMap();
  let next = 1;
  const refOf = (el) => {
    let ref = ids.get(el);
    if (!ref) { ref = next++; ids.set(el, ref); refs.set(ref, new WeakRef(el)); }
    return ref;
  };
  const clean = (s, n = 80) => {
    s = String(s ?? "").replace(/\s+/g, " ").trim();
    return s.length > n ? s.slice(0, n - 1) + "…" : s;
  };
  const quote = (s) => JSON.stringify(s);
  const STRONG = new Set(["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "SUMMARY"]);
  const ROLES = new Set(["button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "option", "combobox", "textbox", "searchbox", "slider", "spinbutton", "listbox", "treeitem", "gridcell"]);
  const INPUT_ROLES = { checkbox: "checkbox", radio: "radio", range: "slider", button: "button", submit: "button",
    reset: "button", image: "button", file: "file", search: "searchbox", number: "spinbutton" };
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK", "SVG", "svg", "PATH", "path"]);

  const deepActive = () => {
    let el = document.activeElement;
    while (el) {
      const inner = el.shadowRoot?.activeElement ?? (el.tagName === "IFRAME" ? safeDoc(el)?.activeElement : null);
      if (!inner) break;
      el = inner;
    }
    return el;
  };
  const safeDoc = (frame) => { try { return frame.contentDocument; } catch { return null; } };
  const shown = (el) => {
    // Styled controls often draw an opacity-0 input over a picture of themselves.
    const opacity = !(el.tagName === "INPUT" || el.tagName === "SELECT");
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: opacity, visibilityProperty: true })) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 || r.height > 0;
  };
  const roleOf = (el) => {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit.split(" ")[0];
    const tag = el.tagName;
    if (tag === "A") return el.hasAttribute("href") ? "link" : null;
    if (tag === "BUTTON" || tag === "SUMMARY") return "button";
    if (tag === "SELECT") return el.multiple ? "listbox" : "combobox";
    if (tag === "TEXTAREA") return "textbox";
    if (tag === "INPUT") {
      const type = (el.type || "text").toLowerCase();
      if (type === "hidden") return null;
      return type in INPUT_ROLES ? INPUT_ROLES[type] : "textbox";
    }
    if (el.isContentEditable && !el.parentElement?.isContentEditable) return "textbox";
    if (/^H[1-6]$/.test(tag)) return "heading";
    return null;
  };
  const nameOf = (el, role, ownTextOnly) => {
    const aria = el.getAttribute("aria-label");
    if (aria) return clean(aria);
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const text = by.split(/\s+/).map((id) => el.ownerDocument.getElementById(id)?.innerText ?? "").join(" ");
      if (text.trim()) return clean(text);
    }
    if (el.labels?.length) return clean(el.labels[0].innerText);
    if (["textbox", "searchbox", "spinbutton", "combobox"].includes(role) && (el.tagName === "INPUT" || el.tagName === "TEXTAREA"))
      return clean(el.placeholder || el.title || el.name || "");
    if (el.tagName === "INPUT" && /^(submit|button|reset)$/.test(el.type)) return clean(el.value);
    if (el.tagName === "IMG") return clean(el.alt);
    if (ownTextOnly) return clean([...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join(" ")) || clean(el.title);
    return clean(el.innerText || el.title || el.querySelector?.("img[alt]")?.alt || el.getAttribute("value") || "");
  };
  const stateOf = (el, role, input) => {
    const bits = [];
    const field = input ?? el;
    if (field.tagName === "INPUT" || field.tagName === "TEXTAREA") {
      const type = (field.type || "").toLowerCase();
      if (type === "password") { if (field.value) bits.push("value=•••"); }
      else if (type === "file") { if (field.files?.length) bits.push("files=" + quote([...field.files].map((f) => f.name).join(","))); }
      else if (!["checkbox", "radio", "button", "submit", "reset", "image"].includes(type) && field.value) bits.push("value=" + quote(clean(field.value, 60)));
    } else if (field.tagName === "SELECT") {
      const chosen = field.selectedOptions?.[0];
      if (chosen) bits.push("value=" + quote(clean(chosen.text, 40)));
      const options = [...field.options].slice(0, 12).map((o) => clean(o.text, 30));
      bits.push("options=" + quote(options.join(" | ") + (field.options.length > 12 ? " | …" : "")));
    } else if (role === "textbox" && el.isContentEditable) {
      const text = clean(el.innerText, 60);
      if (text) bits.push("value=" + quote(text));
    }
    if (field.checked === true || el.getAttribute("aria-checked") === "true") bits.push("checked");
    if (field.disabled || el.getAttribute("aria-disabled") === "true") bits.push("disabled");
    const expanded = el.getAttribute("aria-expanded");
    if (expanded) bits.push(expanded === "true" ? "expanded" : "collapsed");
    if (el.getAttribute("aria-selected") === "true") bits.push("selected");
    if (field === deepActive()) bits.push("focused");
    if (el.getAttribute("draggable") === "true") bits.push("draggable");
    if (role === "heading") bits.unshift("h" + (el.tagName.match(/\d/)?.[0] ?? el.getAttribute("aria-level") ?? ""));
    return bits.join(" ");
  };
  const clickableByStyle = (el, style) => {
    if (el.hasAttribute("onclick") || el.getAttribute("draggable") === "true") return true;
    const tabindex = el.getAttribute("tabindex");
    if (tabindex !== null && Number(tabindex) >= 0) return true;
    if (style.cursor !== "pointer") return false;
    const parent = el.parentElement;
    return !parent || getComputedStyle(parent).cursor !== "pointer";
  };
  const hasInteractiveInside = (el) => !!el.querySelector?.("a[href],button,input,select,textarea,[role=button],[role=link],[role=checkbox],[role=option],[role=menuitem],[role=tab]");

  function snapshot(maxChars) {
    const lines = [];
    let buffer = "";
    let used = 0;
    let truncated = 0;
    const push = (line) => {
      if (used + line.length > maxChars) { truncated++; return; }
      if (lines[lines.length - 1] === line) return;
      lines.push(line);
      used += line.length + 1;
    };
    const flush = () => {
      const text = clean(buffer, 300);
      buffer = "";
      if (text) push(text);
    };
    const emit = (el, role, input, ownTextOnly) => {
      flush();
      const name = role === "heading" ? clean(el.innerText, 120) : nameOf(input ?? el, role, ownTextOnly) || (input ? clean(el.innerText) : "");
      const state = stateOf(el, role, input);
      if (role === "heading") { push(`[${refOf(el)}] heading ${quote(name)}${state ? " " + state : ""}`); return; }
      push(`[${refOf(el)}] ${role}${name ? " " + quote(name) : ""}${state ? " " + state : ""}`);
    };
    const walk = (node) => {
      if (node.nodeType === 3) { buffer += " " + node.textContent; return; }
      if (node.nodeType !== 1 && node.nodeType !== 11) return;
      if (node.nodeType === 11) { for (const child of node.childNodes) walk(child); return; }
      const el = node;
      if (SKIP.has(el.tagName)) return;
      if (el.tagName === "SLOT") { for (const child of el.assignedNodes()) walk(child); return; }
      if (!shown(el)) return;
      const style = getComputedStyle(el);
      const block = !style.display.startsWith("inline") && style.display !== "contents";
      if (block) flush();
      if (el.tagName === "IFRAME") {
        const doc = safeDoc(el);
        if (doc?.body) walk(doc.body);
        if (block) flush();
        return;
      }
      // Custom checkboxes and radios hide the input and draw the label instead.
      if (el.tagName === "LABEL" && el.control && (el.control.type === "checkbox" || el.control.type === "radio") && !el.contains(el.control)) {
        if (!shown(el.control)) emit(el, INPUT_ROLES[el.control.type], el.control);
        if (block) flush();
        return;
      }
      const role = roleOf(el);
      const strong = STRONG.has(el.tagName) || (role && ROLES.has(role)) || role === "heading";
      if (strong && role) {
        const nested = el.tagName !== "SELECT" && hasInteractiveInside(el);
        emit(el, role, null, nested);
        if (!nested) { if (block) flush(); return; }
      } else if (clickableByStyle(el, style)) {
        const nested = hasInteractiveInside(el);
        emit(el, "clickable", null, nested);
        if (!nested) { if (block) flush(); return; }
      }
      const root = el.shadowRoot ?? el;
      for (const child of root.childNodes) walk(child);
      if (block) flush();
    };
    if (document.body) walk(document.body);
    flush();
    const doc = document.scrollingElement ?? document.documentElement;
    return {
      title: document.title,
      url: location.href,
      scroll: `${Math.round(doc.scrollTop)}/${Math.max(0, Math.round(doc.scrollHeight - innerHeight))}`,
      lines,
      truncated
    };
  }

  const deepQueryAll = (selector, root = document) => {
    const found = [...root.querySelectorAll(selector)];
    for (const el of root.querySelectorAll("*")) {
      if (el.shadowRoot) found.push(...deepQueryAll(selector, el.shadowRoot));
      if (el.tagName === "IFRAME") { const doc = safeDoc(el); if (doc) found.push(...deepQueryAll(selector, doc)); }
    }
    return found;
  };
  function resolve(target) {
    if (target.ref != null) {
      const el = refs.get(Number(target.ref))?.deref();
      if (!el || !el.isConnected) throw new Error(`ref ${target.ref} is no longer on the page; take a new snapshot`);
      return el;
    }
    if (target.selector) {
      const matches = deepQueryAll(target.selector);
      const el = matches.find(shown) ?? matches[0];
      if (!el) throw new Error(`no element matches ${target.selector}`);
      return el;
    }
    if (target.name) {
      const wanted = clean(target.name).toLowerCase();
      const all = deepQueryAll("a,button,input,select,textarea,summary,label,[role],[tabindex],[onclick],h1,h2,h3,h4,h5,h6,li,td,span,div,p,img");
      const candidates = all.filter((el) => shown(el));
      const nameMatch = (el) => nameOf(el, roleOf(el) ?? "", false).toLowerCase();
      const exact = candidates.filter((el) => nameMatch(el) === wanted);
      const loose = exact.length ? exact : candidates.filter((el) => nameMatch(el).includes(wanted));
      const ranked = loose.sort((a, b) => (roleOf(b) ? 1 : 0) - (roleOf(a) ? 1 : 0) || a.querySelectorAll("*").length - b.querySelectorAll("*").length);
      if (!ranked.length) throw new Error(`nothing visible is named ${quote(target.name)}`);
      return ranked[0];
    }
    throw new Error("pass ref, selector, name or x/y");
  }
  const frameOffset = (el) => {
    let x = 0, y = 0;
    let win = el.ownerDocument.defaultView;
    while (win && win.frameElement) {
      const frame = win.frameElement;
      const rect = frame.getBoundingClientRect();
      x += rect.left + frame.clientLeft;
      y += rect.top + frame.clientTop;
      win = win.parent;
    }
    return { x, y };
  };
  const describe = (el) => {
    const id = el.id ? "#" + el.id : "";
    const cls = typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".") : "";
    const text = clean(el.innerText, 40);
    return `${el.tagName.toLowerCase()}${id}${cls}${text ? " " + quote(text) : ""}`;
  };
  function point(target, scroll = true) {
    const el = resolve(target);
    if (scroll) el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) throw new Error(`${describe(el)} is not visible; hover or open its container first`);
    const offset = frameOffset(el);
    const x = offset.x + rect.left + rect.width / 2;
    const y = offset.y + rect.top + rect.height / 2;
    const hitDoc = el.ownerDocument;
    const hit = hitDoc.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
    let deepHit = hit;
    while (deepHit?.shadowRoot) {
      const inner = deepHit.shadowRoot.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (!inner || inner === deepHit) break;
      deepHit = inner;
    }
    const related = !deepHit || el.contains(deepHit) || deepHit.contains(el) || deepHit.control === el || el.getRootNode()?.host?.contains?.(deepHit);
    return { x, y, covered: related ? null : describe(deepHit), tag: el.tagName, type: el.type ?? null,
             draggable: !!el.closest?.("[draggable=true]") };
  }
  function focus(target, clear) {
    const el = resolve(target);
    el.scrollIntoView({ block: "center", behavior: "instant" });
    el.focus({ preventScroll: true });
    if (clear) {
      if (typeof el.select === "function" && (el.tagName === "INPUT" || el.tagName === "TEXTAREA")) el.select();
      else if (el.isContentEditable) {
        const range = el.ownerDocument.createRange();
        range.selectNodeContents(el);
        const selection = el.ownerDocument.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }
    }
    return deepActive() === el || el.contains(deepActive());
  }
  function selectOption(target, wanted) {
    const el = resolve(target);
    if (el.tagName !== "SELECT") throw new Error("select works on a native <select>; click custom dropdowns instead");
    const option = [...el.options].find((o) => o.text.trim() === wanted || o.value === wanted) ??
                   [...el.options].find((o) => o.text.toLowerCase().includes(wanted.toLowerCase()));
    if (!option) throw new Error(`no option ${quote(wanted)}; options are ${[...el.options].map((o) => o.text.trim()).join(", ")}`);
    el.value = option.value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return option.text.trim();
  }
  function scrollTarget(target) {
    if (!target) return document.scrollingElement ?? document.documentElement;
    let el = resolve(target);
    while (el && el !== document.body) {
      const style = getComputedStyle(el);
      if (/(auto|scroll)/.test(style.overflowY + style.overflowX) && (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) return el;
      el = el.parentElement;
    }
    return document.scrollingElement ?? document.documentElement;
  }
  function scrollPosition(target) {
    const el = scrollTarget(target);
    return [el.scrollLeft, el.scrollTop];
  }
  function scrollBy(target, dx, dy) {
    scrollTarget(target).scrollBy({ left: dx, top: dy, behavior: "instant" });
  }
  // Synthetic HTML5 drag for pages that ignore the trusted drag CDP can start.
  function syntheticDrag(from, to) {
    const source = resolve(from);
    const target = resolve(to);
    const data = new DataTransfer();
    const at = (el) => { const r = el.getBoundingClientRect(); return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }; };
    const fire = (el, type) => el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data, ...at(el) }));
    fire(source, "dragstart");
    fire(target, "dragenter");
    fire(target, "dragover");
    fire(target, "drop");
    fire(source, "dragend");
    return true;
  }
  // Rich editors take HTML from a paste event; returns false when nothing handled it.
  function pasteRich(html, text) {
    const el = deepActive();
    if (!el) return false;
    const data = new DataTransfer();
    data.setData("text/html", html);
    data.setData("text/plain", text);
    return !el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  }
  function textState(text) {
    return (document.body?.innerText ?? "").toLowerCase().includes(text.toLowerCase());
  }
  function signature() {
    return `${location.href}|${document.readyState}|${document.getElementsByTagName("*").length}|${document.body?.innerText.length ?? 0}`;
  }
  Object.defineProperty(window, "__ocu", {
    value: { v: 1, snapshot, resolve, point, focus, selectOption, pasteRich, scrollPosition, scrollBy, syntheticDrag, textState, signature,
             fileInput: (target) => { const el = resolve(target); return el.tagName === "INPUT" && el.type === "file" ? el : null; } },
    enumerable: false,
    configurable: true
  });
})()
"""#
