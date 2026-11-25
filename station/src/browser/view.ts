// A person's view of a tab of the station's browser: CDP's screencast for the frames (JPEG),
// Input.dispatch* for what they do, on a connection and a session of the view's own, so the agents' own sessions on
// the tab are left as they are.
//
// While a person drives it, its clipboard's text goes both ways: what the page copies (a copy or cut, as the page put it
// on the clipboard or as it was selected; what it writes with navigator.clipboard.writeText) is heard through a binding
// the view's session adds while it is watched (Chrome stops telling of it as the watch ends; a page open then keeps the
// function until it loads again, a page loaded after has none), and a paste is the text inserted where the focus is.
//
// Pull-driven: Chrome casts a frame only once those before it are acknowledged (it keeps at most two out), and a frame
// is acknowledged only when the one after it is asked for (`next`), so a slow viewer slows the casting rather than
// having frames pile up. Of two waiting, the newer is given and the older let go.
import { type Clip, type Frame, type FrameConfig, type LoginField, type LoginFill, type PasskeyAnswer, type PasskeyAsk, type ScreenInput, type ScreenMic, type ScreenVideo, type ScreenView, type ViewOptions, CLIP_TEXT_MAX, gamepadReleased } from "../screens/source.ts";
import type { HelperApp } from "../helper/app.ts";
import { wall } from "../ops/fibers.ts";
import type { Cdp, CdpEvent } from "./cdp.ts";
import { type BrowserMicController, attachBrowserMic } from "./mic.ts";
import { type BrowserVideoEncoder, type BrowserVideoEncoderFactory, createBrowserVideoEncoder } from "./video-encode.ts";
import { randomUUID } from "node:crypto";
import { sizeOf } from "../sessions/image-size.ts";

/// The page's viewport in CSS pixels, as Page.getLayoutMetrics says it (what the screencast's frames show); null when
/// it says none.
export function viewportOf(m: any): { width: number; height: number } | null {
  const v = m?.cssVisualViewport ?? m?.cssLayoutViewport ?? m?.layoutViewport;
  const width = Math.round(Number(v?.clientWidth)), height = Math.round(Number(v?.clientHeight));
  return width > 0 && height > 0 ? { width, height } : null;
}

/// Default (auto quality) JPEG screencast bounds cap: 1:1 with Chrome's 1280×900 CSS viewport instead of 2x Retina.
export const DEFAULT_MAX_WIDTH = 1280;
export const DEFAULT_MAX_HEIGHT = 900;
/// Smooth quality JPEG screencast bounds cap.
export const SMOOTH_MAX_WIDTH = 960;
export const SMOOTH_MAX_HEIGHT = 675;
/// H.264 mode source capture settings: crisp input quality and higher auto resolution cap.
export const H264_SOURCE_QUALITY = 88;
export const H264_AUTO_MAX_WIDTH = 2560;
export const H264_AUTO_MAX_HEIGHT = 1600;
export const H264_SMOOTH_MAX_WIDTH = 1280;
export const H264_SMOOTH_MAX_HEIGHT = 900;
/// JPEG quality of the cast frames: 82, as at 70 small text's edges rang (their colours bled round the strokes).
export const QUALITY = 82;
export const SMOOTH_QUALITY = 70;
/// Gentle JPEG fallback congestion guard: only step down quality to >= 72 after sustained severe congestion >= 5s,
/// with >= 8s cooldown and never shrinking resolution to 960×675.
export const JPEG_MIN_QUALITY = 72;
export const JPEG_CONGESTION_BPS = 600_000;
export const JPEG_RECOVER_BPS = 1_100_000;
export const JPEG_SUSTAINED_CONGESTION_MS = 5_000;
export const JPEG_RECAST_COOLDOWN_MS = 8_000;
/// The most pixels a CSS pixel is drawn with for a phone it is laid out for (`fit`): sharp on any phone, and frames a
/// third the size of a 3× phone's own.
const FIT_SCALE_MOST = 2;

/// Initial screencast bounds and JPEG quality for a browser view.
export function screencastBase(options: Pick<ViewOptions, "maxWidth" | "maxHeight" | "peek" | "fit" | "quality">, h264 = false): { bounds: { maxWidth: number; maxHeight: number }; quality: number } {
  if (!options.peek && options.fit) {
    const scale = Math.min(options.fit.scale, FIT_SCALE_MOST);
    return {
      bounds: { maxWidth: options.fit.width * scale, maxHeight: options.fit.height * scale },
      quality: h264 ? H264_SOURCE_QUALITY : options.quality === "smooth" ? SMOOTH_QUALITY : QUALITY,
    };
  }
  if (h264) {
    if (options.quality === "smooth") {
      return {
        bounds: { maxWidth: Math.min(options.maxWidth, H264_SMOOTH_MAX_WIDTH), maxHeight: Math.min(options.maxHeight, H264_SMOOTH_MAX_HEIGHT) },
        quality: H264_SOURCE_QUALITY,
      };
    }
    if (options.quality === undefined) {
      return {
        bounds: { maxWidth: Math.min(options.maxWidth, H264_AUTO_MAX_WIDTH), maxHeight: Math.min(options.maxHeight, H264_AUTO_MAX_HEIGHT) },
        quality: H264_SOURCE_QUALITY,
      };
    }
    return {
      bounds: { maxWidth: options.maxWidth, maxHeight: options.maxHeight },
      quality: H264_SOURCE_QUALITY,
    };
  }
  if (options.quality === "smooth") {
    return {
      bounds: { maxWidth: Math.min(options.maxWidth, SMOOTH_MAX_WIDTH), maxHeight: Math.min(options.maxHeight, SMOOTH_MAX_HEIGHT) },
      quality: SMOOTH_QUALITY,
    };
  }
  if (options.quality === undefined) {
    return {
      bounds: { maxWidth: Math.min(options.maxWidth, DEFAULT_MAX_WIDTH), maxHeight: Math.min(options.maxHeight, DEFAULT_MAX_HEIGHT) },
      quality: QUALITY,
    };
  }
  return {
    bounds: { maxWidth: options.maxWidth, maxHeight: options.maxHeight },
    quality: QUALITY,
  };
}

/// Smooth frame-rate pacing interval (ms) for JPEG fallback when network bandwidth drops.
export function jpegThrottleIntervalMs(bps: number): number {
  if (!Number.isFinite(bps) || bps >= 1_200_000) return 0;
  if (bps >= 800_000) return 50;
  if (bps >= 500_000) return 85;
  return 125;
}
/// At most this many frames are held unacknowledged (as Chrome sends at most).
const HELD = 2;
/// A press this soon after the last, this near it and of the same button, adds to its click count (a double click).
const CLICK_MS = 500;
const CLICK_PX = 4;

/// A JPEG's size, from its frame header (SOFn); null when there is none (or it is no JPEG). The media reader's
/// (sessions/image-size.ts).
export function jpegSize(data: Uint8Array): { width: number; height: number } | null {
  if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) return null;
  const size = sizeOf(data);
  return size && { width: size[0], height: size[1] };
}

/// A point given as 0..1 of the frame, in the page's CSS pixels (what Input.dispatchMouseEvent takes).
export function toViewport(x: number, y: number, viewport: { width: number; height: number }): { x: number; y: number } {
  const clamp = (v: number) => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0);
  return { x: clamp(x) * viewport.width, y: clamp(y) * viewport.height };
}

/// The mouse buttons as PointerEvent.buttons has them, by CDP's names.
const BUTTONS: [number, string][] = [
  [1, "left"],
  [2, "right"],
  [4, "middle"],
  [8, "back"],
  [16, "forward"],
];
const buttonOf = (bits: number): string => BUTTONS.find(([bit]) => (bits & bit) !== 0)?.[1] ?? "none";

/// Windows' virtual key codes of the keys that are no character (Chrome acts on them by these), and of the
/// punctuation keys by their code.
const NAMED_KEYS: Record<string, number> = {
  Backspace: 8, Tab: 9, Enter: 13, Shift: 16, Control: 17, Alt: 18, Pause: 19, CapsLock: 20, Escape: 27, " ": 32,
  PageUp: 33, PageDown: 34, End: 35, Home: 36, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Insert: 45,
  Delete: 46, Meta: 91, ContextMenu: 93,
};
const CODES: Record<string, number> = {
  Space: 32, Semicolon: 186, Equal: 187, Comma: 188, Minus: 189, Period: 190, Slash: 191, Backquote: 192,
  BracketLeft: 219, Backslash: 220, BracketRight: 221, Quote: 222,
};

export function keyCode(key: string, code: string): number {
  const named = NAMED_KEYS[key];
  if (named !== undefined) return named;
  const f = /^F([1-9]|1[0-9]|2[0-4])$/.exec(key);
  if (f) return 111 + Number(f[1]);
  if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3);
  if (/^Digit[0-9]$/.test(code)) return code.charCodeAt(5);
  if (/^Numpad[0-9]$/.test(code)) return 96 + Number(code.slice(6));
  if (CODES[code] !== undefined) return CODES[code]!;
  if (/^[a-z]$/i.test(key)) return key.toUpperCase().charCodeAt(0);
  if (/^[0-9]$/.test(key)) return key.charCodeAt(0);
  return 0;
}

const ALT = 1;
const CTRL = 2;
const META = 4;
const SHIFT = 8;

/// Editing shortcuts as macOS's Chrome takes them from CDP (as commands; elsewhere the key with its modifiers does).
const COMMANDS: Record<string, string> = { a: "selectAll", c: "copy", x: "cut", v: "paste", z: "undo" };

/// A key press or release as Input.dispatchKeyEvent takes it.
export function keyEvent(e: Extract<ScreenInput, { t: "key" }>): Record<string, unknown> {
  const modifiers = e.mods & (ALT | CTRL | META | SHIFT);
  const base = { key: e.key, code: e.code, modifiers, windowsVirtualKeyCode: keyCode(e.key, e.code), nativeVirtualKeyCode: keyCode(e.key, e.code) };
  if (e.kind === "up") return { type: "keyUp", ...base };
  const shortcut = (modifiers & (CTRL | META)) !== 0;
  // What a key types: its character, or Enter's; not with a shortcut's modifier held.
  const text = e.key === "Enter" ? "\r" : [...e.key].length === 1 && !shortcut ? e.key : undefined;
  if (text !== undefined) return { type: "keyDown", ...base, text, unmodifiedText: text };
  const command = shortcut ? COMMANDS[e.key.toLowerCase()] : undefined;
  const commands = command === undefined ? undefined : command === "undo" && (modifiers & SHIFT) !== 0 ? ["redo"] : [command];
  return { type: "rawKeyDown", ...base, ...(commands ? { commands } : {}) };
}

/// The binding a tab's copies call while a person driving it watches its clipboard.
export const COPY_BINDING = "__stillfailCopied";

/// What a tab's pages are given as the person's game controllers (`{t: "gamepad"}`): navigator.getGamepads as the W3C
/// Standard Gamepad says one (an Xbox 360 controller's 17 buttons and 4 axes, mapping "standard"), with its
/// gamepadconnected and gamepaddisconnected events, so a cloud game, a WebGL or HTML5 game takes it as one plugged in.
/// Put in once a view first drives a controller (every page after it too); `window.__stillfailPad(state)` says a state.
export const GAMEPAD_HOOK = `(() => {
  if (typeof window.__stillfailPad === "function") return;
  const pads = [null, null, null, null];
  const made = (s, at) => {
    const buttons = [];
    for (let i = 0; i < 17; i++) {
      const bit = (s.buttons & (1 << i)) !== 0;
      const value = i === 6 ? Math.max(s.lt, bit ? 1 : 0) : i === 7 ? Math.max(s.rt, bit ? 1 : 0) : bit ? 1 : 0;
      buttons.push(Object.freeze({ pressed: bit || value > 0.5, touched: bit || value > 0, value }));
    }
    return Object.freeze({ id: "Xbox 360 Controller (Standard Gamepad)", index: s.index, connected: true, mapping: "standard", timestamp: at, axes: Object.freeze([s.lx, s.ly, s.rx, s.ry]), buttons: Object.freeze(buttons), vibrationActuator: null, hapticActuators: Object.freeze([]) });
  };
  const told = (type, pad) => {
    const e = new Event(type);
    Object.defineProperty(e, "gamepad", { value: pad });
    window.dispatchEvent(e);
  };
  Object.defineProperty(Navigator.prototype, "getGamepads", { configurable: true, value: function getGamepads() { return pads.slice(); } });
  Object.defineProperty(window, "__stillfailPad", { value: (s) => {
    const i = s && s.index;
    if (!(i >= 0 && i < 4)) return;
    const was = pads[i];
    if (s.connected === false) {
      if (was === null) return;
      pads[i] = null;
      told("gamepaddisconnected", Object.freeze({ ...was, connected: false }));
      return;
    }
    pads[i] = made(s, performance.now());
    if (was === null) told("gamepadconnected", pads[i]);
  } });
})();`;
/// What hears a page's copies, run in it (and in each document it opens while watched): a copy's or a cut's text, as
/// the page set it (read as the event reaches the window) or as it was selected (a field's selection, else the
/// page's), and what it writes with navigator.clipboard.writeText. Once a page; it says nothing once the binding went.
export const COPY_HOOK = `(() => {
  if (window.__stillfailCopyHook) return;
  window.__stillfailCopyHook = true;
  const say = (text) => { try { if (typeof text === "string" && text !== "" && typeof window.${COPY_BINDING} === "function") window.${COPY_BINDING}(text.slice(0, ${CLIP_TEXT_MAX / 4})); } catch {} };
  const selected = () => {
    const el = document.activeElement;
    if (el && (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && /^(text|search|url|tel|email|number)$/i.test(el.type || "text")))) {
      try { if (el.selectionStart !== el.selectionEnd) return el.value.slice(el.selectionStart, el.selectionEnd); } catch {}
      return "";
    }
    return String(window.getSelection() || "");
  };
  // What was selected, said once the copy's dispatch is over (a message to itself: a task after it) unless the page
  // set its own by then.
  let pending = null;
  const after = new MessageChannel();
  after.port1.onmessage = () => { if (pending) say(pending); pending = null; };
  const started = () => {
    pending = selected();
    after.port2.postMessage(0);
  };
  const reached = (e) => {
    let set = "";
    try { set = e.clipboardData ? e.clipboardData.getData("text/plain") : ""; } catch {}
    if (set) { pending = null; say(set); }
  };
  for (const type of ["copy", "cut"]) { window.addEventListener(type, started, true); window.addEventListener(type, reached); }
  const board = navigator.clipboard;
  if (board && typeof board.writeText === "function") {
    const write = board.writeText.bind(board);
    board.writeText = (text) => { say(String(text)); return write(text); };
  }
})()`;

/// The binding a tab's login fields call while a person driving it is offered to fill them.
export const LOGIN_BINDING = "__stillfailLogin";
/// What tells of the login field in focus, run in a page's top document (and each one it opens while watched): a
/// password field, or one an account goes in (marked so, or a text field of a form with a password field, or named
/// so), said as `{"field": …, "filled": true}` (or without `filled` while empty) as the focus comes to one or its value
/// changes and `null` as it leaves; only when it changed. What it says is only a hint: the site is the station's to say
/// (the tab's address), and the page may call the binding as it likes.
export const LOGIN_HOOK = `(() => {
  if (window !== window.top) return;
  if (typeof window.__stillfailLoginTell === "function") {
    window.__stillfailLoginTell();
    return;
  }
  const deep = (root) => { let el = root.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; return el; };
  const kind = (el) => {
    if (!el || el.tagName !== "INPUT" || el.disabled || el.readOnly) return null;
    const type = (el.type || "text").toLowerCase();
    const auto = (el.autocomplete || "").toLowerCase();
    if (type === "password") return "password";
    if (!/^(text|email|tel)$/.test(type)) return null;
    if (/username|email|webauthn/.test(auto)) return "username";
    if (el.form && el.form.querySelector("input[type=password]")) return "username";
    return /user|email|login|account|identifier/i.test((el.name || "") + " " + (el.id || "")) ? "username" : null;
  };
  const focused = (e) => (e && e.composedPath ? e.composedPath()[0] : deep(document));
  let said = "";
  const say = (el) => {
    const field = kind(el);
    const now = field ? JSON.stringify(el.value ? { field, filled: true } : { field }) : "null";
    if (now === said) return;
    said = now;
    try { if (typeof window.${LOGIN_BINDING} === "function") window.${LOGIN_BINDING}(now); } catch {}
  };
  window.__stillfailLoginTell = () => {
    said = "";
    say(deep(document));
  };
  document.addEventListener("focusin", (e) => say(focused(e)), true);
  // (where the focus goes: none, or one a focusin then says itself)
  document.addEventListener("focusout", (e) => say(e.relatedTarget), true);
  document.addEventListener("input", () => say(deep(document)), true);
  document.addEventListener("change", () => say(deep(document)), true);
  say(deep(document));
})()`;

/// Fills the login form the focus is in (or the page's first, where the focus is in none): its account field and its
/// password field, as typing would leave them (the value set as the field's own setter does, then input and change
/// told), the first of them focused. Run in a world of its own, so the page's scripts do not change how it goes. What
/// was filled.
export const fillScript = (username: string | undefined, password: string | undefined) => `((username, password) => {
  const visible = (el) => !!el && !el.disabled && !el.readOnly && el.getClientRects().length > 0;
  const deep = (root) => { let el = root.activeElement; while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement; return el; };
  const active = deep(document);
  const scope = (active && active.form) || (active && active.getRootNode && active.getRootNode()) || document;
  const all = [...scope.querySelectorAll("input")].filter(visible);
  const pass = all.find((el) => (el.type || "").toLowerCase() === "password");
  const account = all.find((el) => el !== pass && /^(text|email|tel)$/.test((el.type || "text").toLowerCase())
    && (/username|email|webauthn/.test((el.autocomplete || "").toLowerCase()) || /user|email|login|account|identifier/i.test((el.name || "") + " " + (el.id || "")) || (pass && el.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING)));
  const set = (el, value) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  const did = { username: false, password: false };
  if (typeof username === "string" && account) { set(account, username); did.username = true; }
  if (typeof password === "string" && pass) { set(pass, password); did.password = true; }
  const first = did.username ? account : did.password ? pass : null;
  if (first) first.focus();
  return did;
})(${JSON.stringify(username ?? null)}, ${JSON.stringify(password ?? null)})`;

/// The binding a tab's passkey sign-ins call while a person driving it signs them from their own device.
export const PASSKEY_BINDING = "__stillfailPasskey";
const passkeyBinding = (owner: string): string => `${PASSKEY_BINDING}_${owner.replaceAll("-", "")}`;
/// What takes a page's passkey sign-in (navigator.credentials.get with `publicKey`) to the person driving it, run in a
/// page's top document and its same-origin iframes before their own scripts (and each one it opens while watched): the
/// ask said through the binding as `{"owner", "id", "rpId", "challenge", "allow", "userVerification"}` (base64url),
/// `{"id", "gone": true}` as the page gives it up (its signal), and answered by the station with
/// `__stillfailPasskeyReply(owner, id, answer)`: a credential made as the browser makes it, or the error the browser
/// would give. The platform is said to have an authenticator, so that sites offer passkeys. Anything else (a password
/// asked, a passkey made) goes to the browser as before.
export const passkeyHook = (owner: string, device = true): string => `(() => {
  if (!navigator.credentials) return;
  const owner = ${JSON.stringify(owner)};
  const device = ${device ? "true" : "false"};
  const sameAncestors = (w) => {
    try {
      let cur = w;
      const topOrigin = window.top.location && window.top.location.origin;
      while (cur !== window.top) {
        const p = cur.parent;
        if (!p || p === cur) return false;
        if (p.location.origin !== topOrigin) return false;
        const o = cur.location && cur.location.origin;
        if (o && o !== "null" && topOrigin && o !== topOrigin) return false;
        cur = p;
      }
      return true;
    } catch {
      return false;
    }
  };
  if (window !== window.top) {
    if (!sameAncestors(window)) return;
    try { if (typeof window.top.__stillfailPasskeyFrame === "function") window.top.__stillfailPasskeyFrame(window); } catch {}
    return;
  }
  if (window.__stillfailPasskeyWatch) return window.__stillfailPasskeyWatch(owner, true, device);
  // A page kept across a station update may still have the old, unowned hook. Its get falls through while off.
  if (window.__stillfailPasskeyOff) window.__stillfailPasskeyOff(true);
  const owners = new Map();
  let active = null;
  let activeDevice = false;
  const bytes = (v) => {
    if (!v || typeof v !== "object") return null;
    if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    if (v instanceof ArrayBuffer || Object.prototype.toString.call(v) === "[object ArrayBuffer]") return new Uint8Array(v);
    return null;
  };
  const b64 = (v) => { const u = bytes(v); if (!u) return null; let s = ""; for (const b of u) s += String.fromCharCode(b); return btoa(s).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, ""); };
  const buf = (w, s) => { const t = atob(s.replace(/-/g, "+").replace(/_/g, "/")); const U8 = (w && w.Uint8Array) || Uint8Array; const u = new U8(t.length); for (let i = 0; i < t.length; i++) u[i] = t.charCodeAt(i); return u.buffer; };
  const domErr = (w, msg, name) => { const DE = (w && w.DOMException) || DOMException; return new DE(msg, name); };
  const waiting = new Map();
  const uvpaWaiting = new Map();
  const attached = new WeakSet();
  let next = 0;
  const said = (v) => { try { window[${JSON.stringify(PASSKEY_BINDING)} + "_" + active.replaceAll("-", "")](JSON.stringify({ ...v, owner: active })); return true; } catch { return false; } };
  const attach = (w) => {
    if (!w || attached.has(w) || !sameAncestors(w)) return;
    let creds;
    try { creds = w.navigator && w.navigator.credentials; } catch { return; }
    if (!creds || typeof creds.get !== "function") return;
    attached.add(w);
    const P = (w && w.Promise) || Promise;
    const get = creds.get.bind(creds);
    creds.get = function (options) {
      const pk = options && options.publicKey;
      const ch = pk && b64(pk.challenge);
      if (active === null || !pk || options.mediation === "conditional" || !ch || ch.length > 32768 || !sameAncestors(w)) return get(options);
      const id = String(++next);
      const allow = Array.isArray(pk.allowCredentials) ? pk.allowCredentials.map((c) => b64(c && c.id)).filter((x) => x) : [];
      const host = (w.location && w.location.hostname) || (window.location && window.location.hostname) || "";
      const ask = { id, rpId: typeof pk.rpId === "string" && pk.rpId !== "" ? pk.rpId : host, challenge: ch, allow, userVerification: pk.userVerification || "preferred" };
      return new P((yes, no) => {
        const signal = options.signal;
        if (signal && signal.aborted) return no(signal.reason !== undefined ? signal.reason : domErr(w, "The operation was aborted.", "AbortError"));
        waiting.set(id, { yes, no, options, ask, get, win: w });
        if (signal) signal.addEventListener("abort", () => {
          if (!waiting.delete(id)) return;
          said({ id, gone: true });
          no(signal.reason !== undefined ? signal.reason : domErr(w, "The operation was aborted.", "AbortError"));
        });
        if (!said(ask)) { waiting.delete(id); get(options).then(yes, no); }
      });
    };
    // (a frame left takes what it asked with it)
    w.addEventListener("pagehide", () => {
      for (const [id, entry] of [...waiting.entries()]) {
        if (w === window || entry.win === w) {
          waiting.delete(id);
          said({ id, gone: true });
        }
      }
      for (const [id, entry] of [...uvpaWaiting.entries()]) {
        if (w === window || entry.win === w) uvpaWaiting.delete(id);
      }
    });
    if (w.PublicKeyCredential) {
      const PK = w.PublicKeyCredential;
      const uvpa = typeof PK.isUserVerifyingPlatformAuthenticatorAvailable === "function" ? PK.isUserVerifyingPlatformAuthenticatorAvailable.bind(PK) : () => P.resolve(false);
      PK.isUserVerifyingPlatformAuthenticatorAvailable = () => {
        if (active === null || !sameAncestors(w)) return uvpa();
        if (activeDevice) return P.resolve(true);
        const id = "u" + (++next);
        const host = String((w.location && w.location.hostname) || (window.location && window.location.hostname) || "");
        return new P((res) => {
          uvpaWaiting.set(id, { host, res, win: w });
          if (!said({ id, uvpa: host })) { uvpaWaiting.delete(id); res(false); }
        });
      };
      PK.isConditionalMediationAvailable = () => P.resolve(false);
    }
  };
  const scan = (w, seen = new Set()) => {
    if (!w || seen.has(w)) return;
    seen.add(w);
    attach(w);
    let len = 0;
    try { len = w.frames ? w.frames.length : 0; } catch { return; }
    for (let i = 0; i < len; i++) {
      try {
        const child = w.frames[i];
        if (child && child !== w) scan(child, seen);
      } catch {}
    }
  };
  Object.defineProperty(window, "__stillfailPasskeyFrame", { value: (w) => scan(w) });
  // New and old screen streams overlap on a resize. Only the active owner answers; an old stream ending cannot
  // switch off its replacement or reject a request it handed over. Pending requests follow an active stream whose
  // device signs passkeys, and settle as NotAllowedError when none does.
  Object.defineProperty(window, "__stillfailPasskeyWatch", { value: (id, on, dev = true) => {
    const useDevice = Boolean(dev);
    if (on) scan(window);
    if (on ? owners.has(id) && owners.get(id) === useDevice : !owners.has(id)) return;
    if (on) owners.set(id, useDevice); else owners.delete(id);
    const last = [...owners.entries()].at(-1);
    const nextOwner = last ? last[0] : null;
    const nextDevice = last ? last[1] : false;
    if (nextOwner === active && nextDevice === activeDevice) return;
    if (active !== null && activeDevice) { for (const wid of waiting.keys()) said({ id: wid, gone: true }); }
    active = nextOwner;
    activeDevice = nextDevice;
    if (active !== null && activeDevice) { for (const w of waiting.values()) said(w.ask); }
    else {
      for (const w of waiting.values()) w.no(domErr(w.win, "The operation either timed out or was not allowed.", "NotAllowedError"));
      waiting.clear();
    }
    if (active === null || activeDevice) {
      for (const u of uvpaWaiting.values()) u.res(Boolean(activeDevice));
      uvpaWaiting.clear();
    } else {
      for (const [uid, u] of uvpaWaiting) { if (!said({ id: uid, uvpa: u.host })) { uvpaWaiting.delete(uid); u.res(false); } }
    }
  } });
  window.__stillfailPasskeyWatch(owner, true, device);
  Object.defineProperty(window, "__stillfailPasskeyReply", { value: (owner, id, a) => {
    if (owner !== active) return;
    const u = uvpaWaiting.get(id);
    if (u) { uvpaWaiting.delete(id); return u.res(a.available === true); }
    const w = waiting.get(id);
    if (!w) return;
    waiting.delete(id);
    // (one of the vault's: the browser signs it, with the tab's own authenticator)
    if (a.browser) return w.get(w.options).then(w.yes, w.no);
    if (a.error) return w.no(domErr(w.win, a.error === "NotAllowedError" ? "The operation either timed out or was not allowed." : String(a.error), a.error === "NotAllowedError" ? "NotAllowedError" : "UnknownError"));
    const W = w.win;
    const response = { clientDataJSON: buf(W, a.clientData), authenticatorData: buf(W, a.authenticatorData), signature: buf(W, a.signature), userHandle: a.userHandle ? buf(W, a.userHandle) : null };
    const credential = { id: a.credential, rawId: buf(W, a.credential), type: "public-key", authenticatorAttachment: "platform", response,
      getClientExtensionResults: () => ({}),
      toJSON: () => ({ id: a.credential, rawId: a.credential, type: "public-key", authenticatorAttachment: "platform", clientExtensionResults: {},
        response: { clientDataJSON: b64(response.clientDataJSON), authenticatorData: a.authenticatorData, signature: a.signature, userHandle: a.userHandle || null } }) };
    try { Object.setPrototypeOf(response, ((W && W.AuthenticatorAssertionResponse) || AuthenticatorAssertionResponse).prototype); Object.setPrototypeOf(credential, ((W && W.PublicKeyCredential) || PublicKeyCredential).prototype); } catch {}
    w.yes(credential);
  } });
})()`;

/// Whether the client data a device made of the station's (`theirs`, JSON) says what the station's says: the same type,
/// challenge and origin, not across origins.
export function sameClientData(theirs: string, ours: string): boolean {
  try {
    const a = JSON.parse(theirs);
    const b = JSON.parse(ours);
    return a?.type === b.type && a?.challenge === b.challenge && a?.origin === b.origin && a?.crossOrigin !== true;
  } catch {
    return false;
  }
}

/// Whether a page on `host` may ask for a passkey of relying party `rpId`: the host itself, or a domain it is under
/// that is more than one label (as browsers take it, short of the public suffix list: a site's own passkeys are kept
/// for its own domain, and a device has none for a bare suffix).
export function rpFor(rpId: string, host: string): boolean {
  const rp = rpId.toLowerCase().replace(/\.$/, "");
  return rp !== "" && (rp === host || (rp.includes(".") && host.endsWith("." + rp)));
}

/// The host of an address (lower case, no trailing dot); "" for one with none (about:blank).
export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.toLowerCase().replace(/\.$/, "");
  } catch {
    return "";
  }
}

type Cast = { ack: number; data: Uint8Array; meta: any };

export type ViewParts = {
  /// The view's own connection, and its session on the tab.
  cdp: Cdp;
  session: string;
  targetId: string;
  /// Milliseconds, for telling a double click.
  now: () => number;
  /// The tab's viewport (CSS pixels), as the frames say it.
  sized?: (size: { width: number; height: number }) => void;
  used?: () => void;
  /// When the view ends.
  ended?: () => void;
  /// Whether the tab's context has a passkey of relying party `rpId` its own authenticator signs (passkeys.ts): a
  /// page's sign-in for it is the browser's, not the person's device's.
  ownPasskey?: (rpId: string) => boolean;
  /// macOS still.fail Helper for hardware VideoToolbox H.264 encoding (frames.encode).
  helper?: HelperApp | null;
  /// Optional H.264 encoder factory override for tests.
  createEncoder?: BrowserVideoEncoderFactory;
  /// Optional one-shot timer override for deterministic JPEG throttle tests (defaults to `wall.after`).
  later?: (ms: number, f: () => void) => () => void;
};

export class TabView implements ScreenView {
  watchChild?: (heard: (screenId: string) => void) => () => void;
  readonly #p: ViewParts;
  #received: Cast[] = [];
  #waiter: ((frame: Frame | null) => void) | null = null;
  #ended = false;
  /// The passkey sign-in a page asked last and not yet answered: its id, the origin it was asked on, the client data
  /// made of it.
  #asked: { id: string; origin: string; clientData: string } | null = null;
  /// Who hears the passkey sign-ins (watchPasskey), told as the one asked is answered.
  #passkeyHeard: ((ask: PasskeyAsk | null) => void) | null = null;
  #passkeyOwner = "";
  #keyframe = false;
  #last: { data: Uint8Array; config: FrameConfig } | null = null;
  #config: FrameConfig | null = null;
  #ts = 0;
  #viewport = { width: 0, height: 0 };
  #buttons = 0;
  #click = { count: 0, at: -Infinity, x: 0, y: 0, button: "none" };
  /// The controllers' hook put in its pages (GAMEPAD_HOOK), once a controller first came.
  #padHook: Promise<void> | null = null;
  /// The slots its pages were told a controller is in: let go of as the view ends (the tab stays open).
  readonly #padSlots = new Set<number>();
  #unlisten: () => void;
  /// A preview's (ViewOptions.peek): the tab is not brought forward for it, so what is behind another casts nothing.
  #peek = false;
  /// Laid out for the viewer's phone (ViewOptions.fit) until it ends.
  #fitted = false;
  /// Whether the driving viewer's host signs arbitrary-site passkeys (`ViewOptions.passkeys !== false`).
  #devicePasskeys = true;
  /// Active H.264 encoder when `!peek && codecs.includes("h264")` and an encoder backend is available; null -> JPEG.
  #encoder: BrowserVideoEncoder | null = null;
  /// Whether the client accepts JPEG fallback if the H.264 encoder closes unexpectedly mid-stream.
  #allowJpeg = true;
  /// Gentle JPEG fallback rate adaptation state (only used when `#encoder === null`).
  #started = false;
  #quality: ViewOptions["quality"];
  #baseBounds = { maxWidth: DEFAULT_MAX_WIDTH, maxHeight: DEFAULT_MAX_HEIGHT };
  #baseQuality = QUALITY;
  #tier: 0 | 1 = 0;
  #congestedSince: number | null = null;
  #lastRecast = -Infinity;
  #jpegMinIntervalMs = 0;
  #lastJpegDeliveredAt = -Infinity;
  #jpegThrottleTimer: (() => void) | null = null;
  /// The tab's virtual microphone (mic.ts) while its driver watches it.
  #mic: BrowserMicController | null = null;

  /// Chrome's screencast, either encoded as H.264 or falling back to JPEG.
  video(): ScreenVideo {
    if (this.#encoder !== null) {
      const info = this.#encoder.info();
      return { capture: "Chrome screencast", encoder: info.encoder, hardware: info.hardware };
    }
    return { capture: "Chrome screencast", encoder: "JPEG" };
  }

  constructor(p: ViewParts) {
    this.#p = p;
    this.#unlisten = p.cdp.on((e) => this.#heard(e));
    void p.cdp.closed.then(() => this.#end());
  }

  /// Starts casting; `viewport`: the page's size before the first frame says it. Laid out for the viewer's phone
  /// (`fit`): its size and scale, and a phone's ways (Chrome's device emulation on the view's own session, which goes
  /// with it), and cast as large as that.
  async start(options: ViewOptions, viewport?: { width: number; height: number }) {
    if (viewport) this.#viewport = viewport;
    this.#peek = options.peek === true;
    this.#quality = options.quality;
    this.#devicePasskeys = options.passkeys !== false;
    const { cdp, session } = this.#p;
    await cdp.send("Page.enable", {}, session);
    const fit = options.fit && !this.#peek ? options.fit : undefined;
    if (fit) {
      const scale = Math.min(fit.scale, FIT_SCALE_MOST);
      await cdp.send("Emulation.setDeviceMetricsOverride", { width: fit.width, height: fit.height, deviceScaleFactor: scale, mobile: true }, session);
      this.#viewport = { width: fit.width, height: fit.height };
      this.#fitted = true;
    } else if (!viewport) {
      const v = viewportOf(await cdp.send("Page.getLayoutMetrics", {}, session).catch(() => null));
      // The tab's size is its viewport's: told now, not only when a frame says another.
      if (v) {
        this.#viewport = v;
        this.#p.sized?.(v);
      }
    }
    if (!this.#peek && options.codecs.includes("h264")) {
      const h264Bounds = screencastBase(options, true).bounds;
      this.#encoder = await createBrowserVideoEncoder({
        helper: this.#p.helper,
        width: this.#viewport.width > 0 ? Math.min(this.#viewport.width, h264Bounds.maxWidth) : h264Bounds.maxWidth,
        height: this.#viewport.height > 0 ? Math.min(this.#viewport.height, h264Bounds.maxHeight) : h264Bounds.maxHeight,
        bitrate: options.bitrate,
        fps: options.fps,
        now: this.#p.now,
        factory: this.#p.createEncoder,
      });
    }
    this.#allowJpeg = options.codecs.includes("jpeg");
    if (this.#encoder === null && !this.#allowJpeg) {
      throw new Error("A tab of the station's browser needs H.264 or JPEG, and no H.264 encoder is available.");
    }
    const base = screencastBase(options, this.#encoder !== null);
    this.#baseBounds = base.bounds;
    this.#baseQuality = base.quality;
    this.#tier = 0;
    this.#congestedSince = null;
    this.#jpegMinIntervalMs = 0;
    this.#lastJpegDeliveredAt = -Infinity;
    await cdp.send(
      "Page.startScreencast",
      { format: "jpeg", quality: base.quality, maxWidth: Math.max(1, Math.round(base.bounds.maxWidth)), maxHeight: Math.max(1, Math.round(base.bounds.maxHeight)), everyNthFrame: 1 },
      session,
    );
    this.#started = true;
    this.#lastRecast = -Infinity;
  }

  rate(bps: number) {
    if (this.#ended || !this.#started || !Number.isFinite(bps)) return;
    if (this.#encoder !== null) {
      this.#encoder.setBitrate(bps);
      return;
    }
    if (this.#peek || this.#quality === "original") return;
    this.#jpegMinIntervalMs = jpegThrottleIntervalMs(bps);
    const now = this.#p.now();
    if (this.#tier === 0) {
      if (bps < JPEG_CONGESTION_BPS) {
        this.#congestedSince ??= now;
        if (now - this.#congestedSince >= JPEG_SUSTAINED_CONGESTION_MS && now - this.#lastRecast >= JPEG_RECAST_COOLDOWN_MS) {
          this.#tier = 1;
          this.#lastRecast = now;
          this.#congestedSince = null;
          const quality = Math.max(JPEG_MIN_QUALITY, Math.min(this.#baseQuality, JPEG_MIN_QUALITY));
          void this.#p.cdp
            .send(
              "Page.startScreencast",
              { format: "jpeg", quality, maxWidth: Math.max(1, Math.round(this.#baseBounds.maxWidth)), maxHeight: Math.max(1, Math.round(this.#baseBounds.maxHeight)), everyNthFrame: 1 },
              this.#p.session,
            )
            .catch(() => {});
        }
      } else if (bps >= JPEG_RECOVER_BPS) {
        this.#congestedSince = null;
      }
    } else {
      if (bps >= JPEG_RECOVER_BPS && now - this.#lastRecast >= JPEG_RECAST_COOLDOWN_MS) {
        this.#tier = 0;
        this.#lastRecast = now;
        this.#congestedSince = null;
        void this.#p.cdp
          .send(
            "Page.startScreencast",
            { format: "jpeg", quality: this.#baseQuality, maxWidth: Math.max(1, Math.round(this.#baseBounds.maxWidth)), maxHeight: Math.max(1, Math.round(this.#baseBounds.maxHeight)), everyNthFrame: 1 },
            this.#p.session,
          )
          .catch(() => {});
      }
    }
  }

  async next(): Promise<Frame | null> {
    if (this.#ended) return null;
    if (this.#encoder !== null) {
      const frame = await this.#encoder.next();
      if (frame !== null || this.#ended || !this.#allowJpeg) return frame;
      // Encoder died unexpectedly mid-stream while CDP screencast is still alive: fall back to JPEG seamlessly.
      this.#encoder = null;
      this.#config = null;
      if (this.#last) {
        this.#keyframe = true;
        return this.#again();
      }
    }
    if (this.#keyframe && this.#last) {
      this.#clearThrottleTimer();
      return this.#again();
    }
    if (this.#received.length > 0) {
      const elapsed = this.#p.now() - this.#lastJpegDeliveredAt;
      if (this.#jpegMinIntervalMs <= 0 || elapsed >= this.#jpegMinIntervalMs) {
        this.#clearThrottleTimer();
        const frame = this.#take();
        if (frame) return frame;
      } else {
        return new Promise((resolve) => {
          this.#waiter = resolve;
          this.#scheduleThrottleFlush(this.#jpegMinIntervalMs - elapsed);
        });
      }
    }
    return new Promise((resolve) => (this.#waiter = resolve));
  }

  keyframe() {
    if (this.#ended) return;
    if (this.#encoder !== null) {
      this.#encoder.requestKeyframe();
      return;
    }
    this.#keyframe = true;
    if (this.#waiter && this.#last) {
      this.#clearThrottleTimer();
      const w = this.#waiter;
      this.#waiter = null;
      w(this.#again());
    }
  }

  async input(event: ScreenInput) {
    if (this.#ended) return;
    if (event.t !== "pointer" || event.kind !== "move") this.#p.used?.();
    const { cdp, session } = this.#p;
    switch (event.t) {
      case "pointer": {
        const at = toViewport(event.x, event.y, this.#viewport);
        const before = this.#buttons;
        this.#buttons = event.buttons;
        if (event.kind === "move") {
          await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...at, button: buttonOf(event.buttons), buttons: event.buttons }, session);
          return;
        }
        if (event.kind === "down") {
          const button = buttonOf(event.buttons & ~before) === "none" ? "left" : buttonOf(event.buttons & ~before);
          const now = this.#p.now();
          const c = this.#click;
          const again = c.button === button && now - c.at <= CLICK_MS && Math.abs(at.x - c.x) <= CLICK_PX && Math.abs(at.y - c.y) <= CLICK_PX;
          this.#click = { count: again ? c.count + 1 : 1, at: now, x: at.x, y: at.y, button };
          await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...at, button, buttons: event.buttons, clickCount: this.#click.count }, session);
          return;
        }
        const released = buttonOf(before & ~event.buttons);
        const button = released === "none" ? this.#click.button : released;
        await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...at, button, buttons: event.buttons, clickCount: Math.max(1, this.#click.count) }, session);
        return;
      }
      case "wheel": {
        const at = toViewport(event.x, event.y, this.#viewport);
        await cdp.send("Input.dispatchMouseEvent", { type: "mouseWheel", ...at, deltaX: event.dx, deltaY: event.dy, button: "none", buttons: this.#buttons }, session);
        return;
      }
      case "key":
        await cdp.send("Input.dispatchKeyEvent", keyEvent(event), session);
        return;
      case "text":
        if (event.text !== "") await cdp.send("Input.insertText", { text: event.text }, session);
        return;
      case "gamepad": {
        this.#padHook ??= (async () => {
          await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: GAMEPAD_HOOK }, session);
          await cdp.send("Runtime.evaluate", { expression: GAMEPAD_HOOK }, session);
        })();
        await this.#padHook;
        if (event.connected) this.#padSlots.add(event.index);
        else this.#padSlots.delete(event.index);
        const { t: _, ...state } = event;
        await cdp.send("Runtime.evaluate", { expression: `window.__stillfailPad && window.__stillfailPad(${JSON.stringify(state)})` }, session);
        return;
      }
    }
  }

  /// A paste: the text inserted where the tab's focus is (Chrome's own clipboard is the machine's, left as it is).
  async setClipboard(clip: Clip, paste: boolean): Promise<void> {
    if (this.#ended || clip.type !== "text" || !paste) return;
    await this.#p.cdp.send("Input.insertText", { text: clip.text }, this.#p.session);
  }

  watchClipboard(heard: (clip: Clip) => void): () => void {
    const { cdp, session } = this.#p;
    let on = true;
    let script: string | null = null;
    const unlisten = cdp.on((e) => {
      if (on && e.method === "Runtime.bindingCalled" && e.sessionId === session && e.params?.name === COPY_BINDING && typeof e.params.payload === "string" && e.params.payload !== "") {
        heard({ type: "text", text: e.params.payload });
      }
    });
    const undo = () => {
      if (this.#ended) return;
      void cdp.send("Runtime.removeBinding", { name: COPY_BINDING }, session).catch(() => {});
      if (script !== null) void cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: script }, session).catch(() => {});
    };
    void (async () => {
      try {
        // The binding needs no Runtime.enable (which a page could tell).
        await cdp.send("Runtime.addBinding", { name: COPY_BINDING }, session);
        script = (await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: COPY_HOOK }, session))?.identifier ?? null;
        await cdp.send("Runtime.evaluate", { expression: COPY_HOOK }, session);
        if (!on) undo();
      } catch {}
    })();
    return () => {
      if (!on) return;
      on = false;
      unlisten();
      undo();
    };
  }

  /// The login field in focus, as the page's hook says it, with the tab's host as the browser has its address (asked
  /// each time: the page may have gone elsewhere), until the returned function.
  watchLogin(heard: (login: LoginField | null) => void): () => void {
    const { cdp, session, targetId } = this.#p;
    let on = true;
    let script: string | null = null;
    const unlisten = cdp.on((e) => {
      if (!on || e.method !== "Runtime.bindingCalled" || e.sessionId !== session || e.params?.name !== LOGIN_BINDING) return;
      let said: any = null;
      try {
        said = JSON.parse(String(e.params.payload));
      } catch {}
      const field = said?.field === "username" || said?.field === "password" ? (said.field as LoginField["field"]) : null;
      if (field === null) return heard(null);
      const filled = said?.filled === true;
      void this.#host(targetId).then((host) => on && heard(host === "" ? null : { host, field, ...(filled ? { filled: true } : {}) }));
    });
    const undo = () => {
      if (this.#ended) return;
      void cdp.send("Runtime.removeBinding", { name: LOGIN_BINDING }, session).catch(() => {});
      if (script !== null) void cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: script }, session).catch(() => {});
    };
    void (async () => {
      try {
        await cdp.send("Runtime.addBinding", { name: LOGIN_BINDING }, session);
        script = (await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: LOGIN_HOOK }, session))?.identifier ?? null;
        await cdp.send("Runtime.evaluate", { expression: LOGIN_HOOK }, session);
        if (!on) undo();
      } catch {}
    })();
    return () => {
      if (!on) return;
      on = false;
      unlisten();
      undo();
    };
  }

  /// Fills the login form in focus with what the person's app gave, only while the tab is on `f.host`, in a world of
  /// the page's top frame of its own (nothing of it logged).
  async fill(f: LoginFill): Promise<void> {
    if (this.#ended) return;
    const { cdp, session, targetId } = this.#p;
    if ((await this.#host(targetId)) !== f.host.toLowerCase()) return;
    const { frameTree } = await cdp.send("Page.getFrameTree", {}, session);
    const frameId = frameTree?.frame?.id;
    if (typeof frameId !== "string") return;
    const { executionContextId } = await cdp.send("Page.createIsolatedWorld", { frameId, worldName: "stillfail-fill" }, session);
    await cdp.send("Runtime.evaluate", { expression: fillScript(f.username, f.password), contextId: executionContextId, returnByValue: true }, session);
  }

  /// A page's passkey sign-ins, as its hook asks them, each checked against the tab's address as the browser has it
  /// (its origin, its host for the relying party) and made into the client data the device is to sign; null as the
  /// one asked goes. Until the returned function, which answers what is still asked as the browser would with none.
  watchPasskey(heard: (ask: PasskeyAsk | null) => void): () => void {
    const { cdp, session, targetId } = this.#p;
    const owner = randomUUID();
    // Each viewer owns its binding as well as its subscription: page requests go to just that viewer, and an old
    // session removes only its own name on cleanup.
    const binding = passkeyBinding(owner);
    const hook = passkeyHook(owner, this.#devicePasskeys);
    this.#passkeyOwner = owner;
    let on = true;
    let script: string | null = null;
    this.#passkeyHeard = heard;
    const pending = new Map<string, object>();
    const unlisten = cdp.on((e) => {
      if (!on || e.method !== "Runtime.bindingCalled" || e.sessionId !== session || e.params?.name !== binding) return;
      let said: any = null;
      try {
        said = JSON.parse(String(e.params.payload));
      } catch {}
      if (said?.owner !== owner || typeof said?.id !== "string" || said.id === "" || said.id.length > 32) return;
      const id: string = said.id;
      if (said.gone === true) {
        pending.delete(id);
        if (this.#asked?.id === id) {
          this.#asked = null;
          heard(null);
        }
        return;
      }
      if (typeof said.uvpa === "string" && said.uvpa.length <= 253) {
        const h = said.uvpa.toLowerCase().replace(/\.$/, "");
        let available = false;
        if (this.#p.ownPasskey && h !== "") {
          const parts = h.split(".");
          for (let i = 0; i < parts.length; i++) {
            const rp = parts.slice(i).join(".");
            if ((i === 0 || rp.includes(".")) && this.#p.ownPasskey(rp)) {
              available = true;
              break;
            }
          }
        }
        void this.#answer({ id, available });
        return;
      }
      const b64 = (v: unknown, most: number): v is string => typeof v === "string" && v !== "" && v.length <= most && /^[A-Za-z0-9_-]+$/.test(v);
      const allow: unknown[] = Array.isArray(said.allow) ? said.allow.slice(0, 64) : [];
      if (typeof said.rpId !== "string" || !b64(said.challenge, 32768) || !allow.every((a) => b64(a, 1366))) return;
      const userVerification = ["required", "preferred", "discouraged"].includes(said.userVerification) ? said.userVerification : "preferred";
      const request = {};
      pending.set(id, request);
      void this.#url(targetId).then((url) => {
        if (!on || pending.get(id) !== request) return;
        pending.delete(id);
        let origin = "";
        try {
          const u = new URL(url);
          // (a secure context only, as WebAuthn takes: https, or this machine's own)
          if (u.protocol === "https:" || (u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1"))) origin = u.origin;
        } catch {}
        const host = hostOf(url);
        if (origin === "" || !rpFor(said.rpId, host)) {
          void this.#answer({ id, error: "NotAllowedError" });
          return;
        }
        // A passkey of the vault's in the tab's context: its own authenticator signs it, no device asked.
        if (this.#p.ownPasskey?.(said.rpId) === true) {
          void this.#answer({ id, browser: true });
          return;
        }
        // A viewer without host passkeys never invokes headful Chrome's OS WebAuthn dialog (hidden outside screencast).
        if (!this.#devicePasskeys) {
          void this.#answer({ id, error: "NotAllowedError" });
          return;
        }
        const clientData = JSON.stringify({ type: "webauthn.get", challenge: said.challenge, origin, crossOrigin: false });
        // (one asked at a time, the latest: one before it is answered as given up)
        if (this.#asked !== null) void this.#answer({ id: this.#asked.id, error: "NotAllowedError" });
        this.#asked = { id, origin, clientData };
        heard({ id, host, rpId: said.rpId.toLowerCase().replace(/\.$/, ""), clientData, allow: allow as string[], userVerification });
      });
    });
    const undo = () => {
      if (this.#passkeyHeard === heard) this.#passkeyHeard = null;
      if (this.#ended) return;
      this.#asked = null;
      // The page transfers pending requests to another viewer, or refuses them if nobody is left.
      void cdp.send("Runtime.evaluate", { expression: `window.__stillfailPasskeyWatch && window.__stillfailPasskeyWatch(${JSON.stringify(owner)}, false)` }, session).catch(() => {});
      void cdp.send("Runtime.removeBinding", { name: binding }, session).catch(() => {});
      if (script !== null) void cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: script }, session).catch(() => {});
    };
    void (async () => {
      try {
        await cdp.send("Runtime.addBinding", { name: binding }, session);
        // With Runtime disabled Chrome installs the binding in the current document but not the next one.
        // Keep it enabled on this view's session so the new-document hook can reach the binding after navigation.
        await cdp.send("Runtime.enable", {}, session);
        script = (await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: hook }, session))?.identifier ?? null;
        await cdp.send("Runtime.evaluate", { expression: hook }, session);
        if (!on) undo();
      } catch {}
    })();
    return () => {
      if (!on) return;
      on = false;
      unlisten();
      undo();
    };
  }

  /// Answers the page's passkey sign-in with what the person's app signed, only the one asked last, while the tab is
  /// still on the origin it was asked on: its client data the station's own as it was signed, or the device's where it
  /// made its own of it (macOS), only if that says what the station's said (its type, challenge and origin).
  async passkey(a: PasskeyAnswer): Promise<void> {
    const asked = this.#asked;
    if (this.#ended || asked === null || asked.id !== a.id) return;
    this.#asked = null;
    this.#passkeyHeard?.(null);
    let origin = "";
    try {
      origin = new URL(await this.#url(this.#p.targetId)).origin;
    } catch {}
    if (origin !== asked.origin) return;
    if ("error" in a) return this.#answer(a);
    let clientData = Buffer.from(asked.clientData).toString("base64url");
    if (a.clientData !== undefined) {
      if (!sameClientData(Buffer.from(a.clientData, "base64url").toString("utf8"), asked.clientData)) return this.#answer({ id: a.id, error: "NotAllowedError" });
      clientData = a.clientData;
    }
    await this.#answer({ ...a, clientData });
  }

  /// The page's hook told how its ask `a.id` went.
  async #answer(a: { id: string } & Record<string, unknown>): Promise<void> {
    await this.#p.cdp.send("Runtime.evaluate", { expression: `window.__stillfailPasskeyReply && window.__stillfailPasskeyReply(${JSON.stringify(this.#passkeyOwner)}, ${JSON.stringify(a.id)}, ${JSON.stringify(a)})` }, this.#p.session).catch(() => {});
  }

  /// The address of tab `targetId` as the browser has it now ("" for none).
  async #url(targetId: string): Promise<string> {
    const { targetInfo } = await this.#p.cdp.send("Target.getTargetInfo", { targetId }).catch(() => ({ targetInfo: null }));
    return String(targetInfo?.url ?? "");
  }

  /// The host of tab `targetId` as the browser has its address now ("" for none).
  async #host(targetId: string): Promise<string> {
    return hostOf(await this.#url(targetId));
  }

  /// The tab's virtual microphone: always there to feed, recorded only while its page records it.
  watchMic(heard: (mic: ScreenMic) => void): () => void {
    this.#micOff();
    if (this.#ended) return () => {};
    const mic = attachBrowserMic(this.#p.cdp, this.#p.session, { onDemand: (d) => heard({ available: true, active: d.active, epoch: d.epoch >>> 0 }) });
    this.#mic = mic;
    heard({ available: true, active: false, epoch: 0 });
    return () => {
      if (this.#mic === mic) this.#micOff();
    };
  }

  feedMic(pcm16le: Uint8Array, epoch: number) {
    const mic = this.#mic;
    if (mic !== null && mic.demand.active && mic.demand.epoch >>> 0 === epoch) mic.feedPcm16(pcm16le);
  }

  #micOff() {
    const mic = this.#mic;
    this.#mic = null;
    mic?.close();
  }

  close() {
    if (this.#ended) return;
    const { cdp, session } = this.#p;
    // (its page's virtual tracks ended and its hook taken out, before its session goes)
    this.#micOff();
    void cdp.send("Page.stopScreencast", {}, session).catch(() => {});
    // As it was laid out before (its session going takes it away too; said, for a Chrome that would keep it).
    if (this.#fitted) void cdp.send("Emulation.clearDeviceMetricsOverride", {}, session).catch(() => {});
    // Its controllers let go of in its pages, before its session goes (else navigator.getGamepads keeps them).
    for (const index of this.#padSlots) {
      const { t: _, ...state } = gamepadReleased(index);
      void cdp.send("Runtime.evaluate", { expression: `window.__stillfailPad && window.__stillfailPad(${JSON.stringify(state)})` }, session).catch(() => {});
    }
    this.#padSlots.clear();
    void cdp.send("Target.detachFromTarget", { sessionId: session }).catch(() => {}).finally(() => cdp.close());
    this.#end();
  }

  /// The tab's viewport as last cast (CSS pixels).
  viewport() {
    return this.#viewport;
  }

  #heard(e: CdpEvent) {
    const { session } = this.#p;
    if (e.method === "Page.screencastFrame" && e.sessionId === session) {
      if (this.#ended) return;
      const ack = e.params.sessionId;
      // Pipeline CDP ack immediately on receipt so Chrome can capture the next frame without waiting 1 RTT.
      this.#ack(ack);
      const data = Buffer.from(String(e.params.data ?? ""), "base64");
      const meta = e.params.metadata ?? {};
      if (meta.deviceWidth > 0 && meta.deviceHeight > 0 && (meta.deviceWidth !== this.#viewport.width || meta.deviceHeight !== this.#viewport.height)) {
        this.#viewport = { width: meta.deviceWidth, height: meta.deviceHeight };
        this.#p.sized?.(this.#viewport);
      }
      if (this.#encoder !== null) {
        const stamp = typeof meta.timestamp === "number" ? Math.round(meta.timestamp * 1e6) : this.#p.now() * 1000;
        this.#ts = Math.max(this.#ts + 1, stamp);
        const size = jpegSize(data) ?? this.#viewport;
        this.#last = { data, config: { codec: "jpeg", width: Math.max(1, size.width), height: Math.max(1, size.height) } };
        this.#encoder.pushJpeg(data, this.#ts);
        return;
      }
      this.#received.push({ ack, data, meta });
      while (this.#received.length > HELD) this.#received.shift();
      if (this.#waiter) {
        const now = this.#p.now();
        const elapsed = now - this.#lastJpegDeliveredAt;
        if (this.#jpegMinIntervalMs <= 0 || elapsed >= this.#jpegMinIntervalMs) {
          this.#clearThrottleTimer();
          const w = this.#waiter;
          this.#waiter = null;
          w(this.#take());
        } else {
          this.#scheduleThrottleFlush(this.#jpegMinIntervalMs - elapsed);
        }
      }
    } else if ((e.method === "Target.detachedFromTarget" && e.params.sessionId === session) || (e.method === "Inspector.detached" && e.sessionId === session)) {
      this.#end();
    }
  }

  #clearThrottleTimer() {
    this.#jpegThrottleTimer?.();
    this.#jpegThrottleTimer = null;
  }

  #scheduleThrottleFlush(remainingMs: number) {
    if (this.#jpegThrottleTimer !== null) return;
    const delay = Math.max(1, Math.ceil(remainingMs));
    // timer: burst debouncing to deliver the final throttled JPEG frame once the pacing interval elapses
    this.#jpegThrottleTimer = (this.#p.later ?? wall.after)(delay, () => {
      this.#jpegThrottleTimer = null;
      if (this.#ended || this.#waiter === null || this.#received.length === 0) return;
      const w = this.#waiter;
      this.#waiter = null;
      w(this.#take());
    });
  }

  /// The newest frame received, the older let go; null when none came.
  #take(): Frame | null {
    const newest = this.#received.pop();
    if (newest === undefined) return null;
    this.#received.length = 0;
    this.#lastJpegDeliveredAt = this.#p.now();
    const meta = newest.meta;
    const size = jpegSize(newest.data) ?? (this.#config ? { width: this.#config.width, height: this.#config.height } : { width: this.#viewport.width, height: this.#viewport.height });
    const config: FrameConfig = { codec: "jpeg", width: size.width, height: size.height };
    const changed = this.#config === null || this.#config.width !== config.width || this.#config.height !== config.height || this.#keyframe;
    this.#keyframe = false;
    this.#config = config;
    this.#last = { data: newest.data, config };
    const stamp = typeof meta.timestamp === "number" ? Math.round(meta.timestamp * 1e6) : this.#p.now() * 1000;
    this.#ts = Math.max(this.#ts + 1, stamp);
    return { ...(changed ? { config } : {}), key: true, ts: this.#ts, data: newest.data };
  }

  /// The last frame again, for a viewer that lost its decoder's state.
  #again(): Frame {
    this.#keyframe = false;
    const last = this.#last!;
    this.#ts += 1;
    return { config: last.config, key: true, ts: this.#ts, data: last.data };
  }

  #ack(ack: number) {
    const { cdp, session } = this.#p;
    void cdp.send("Page.screencastFrameAck", { sessionId: ack }, session).catch(() => {});
  }

  #end() {
    if (this.#ended) return;
    this.#ended = true;
    this.#clearThrottleTimer();
    this.#micOff();
    this.#unlisten();
    this.#encoder?.close();
    this.#encoder = null;
    const w = this.#waiter;
    this.#waiter = null;
    w?.(null);
    this.#p.ended?.();
  }
}
