// A chat's Farview tab (farview.ts) as one of the station's screens: people see and drive it from their app as they do
// a tab of Chrome. The host draws its pictures itself and serves them on its frame port, one connection a view:
// JSON lines each way, a picture's bytes right after the line that says it.
//
//   to the host:   {"size":{width,height,scale}}  the tab's viewport (CSS pixels; the last view's to say one wins)
//                  {"frame":{format:"jpeg",quality}}  a picture now, answered {"frame":{seq,width,height,format,bytes}}
//                  {"pointer":{type,x,y,button,buttons}} {"wheel":{x,y,dx,dy}} {"key":{type,key,code,mods}} {"text":…}
//                                                  a person's input (a pointer in the pictures' pixels, the rest
//                                                  in CSS pixels): it takes the tab from an agent
//   from the host: {"changed":seq}  the picture changed (asked for then: nothing is polled)
//                  {"page":{url,title}} {"size":{…}} {"taken":"agent"|"person"}
//                  {"copied":text}  what a person's copy or cut on that view took (its clipboard's text)
//                  {"openTab":url}  the page asked for a new tab (to every connection: heard on the watch's alone);
//                                   a window with a handle (window.open, an OAuth popup) says its own id as `window`,
//                                   this tab's as `opener` and the opener's origin as `origin` (the new tab's
//                                   FV_TAB_ID, FV_OPENER_ID and FV_OPENER_ORIGIN: the two tabs talk through the profile)
//                  {"closeTab":true}  the page closed its tab (window.close() in a window a page opened)
// A person's paste is text sent as typed ({"text":…}, where the focus is).
import { connect, type Socket } from "node:net";
import type { HelperApp } from "../helper/app.ts";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { type Clip, type ClipType, type Frame, type FrameConfig, type ScreenInput, type ScreenSource, type ScreenVideo, type ScreenView, type ViewOptions, CLIP_TEXT_MAX } from "../screens/source.ts";
import { chatDir } from "./farview.ts";
import { type BrowserVideoEncoder, type BrowserVideoEncoderFactory, createBrowserVideoEncoder } from "./video-encode.ts";

let defaultFarviewHelper: HelperApp | null = null;
export function setFarviewHelper(helper: HelperApp | null): void {
  defaultFarviewHelper = helper;
}

export type FramePage = { url: string; title: string };
/// What a page's new tab is to the tab that asked for it: the new window's id, the asking tab's, and its origin (none:
/// a tab of its own, no handle to it).
export type OpenTabMeta = { window?: string; opener?: string; origin?: string };

/// The new tab an `openTab` line asks for: its address and what links it to the tab that asked (null: no such line).
export function openTabOf(m: any): { url: string; meta: OpenTabMeta } | null {
  if (typeof m?.openTab !== "string" || m.openTab === "") return null;
  const meta: OpenTabMeta = {};
  for (const k of ["window", "opener", "origin"] as const) if (typeof m[k] === "string" && m[k] !== "") meta[k] = m[k];
  return { url: m.openTab, meta };
}
type Size = { width: number; height: number; scale: number };

/// The viewport a tab is laid out at with no view saying one (a desktop's window).
export const DEFAULT_SIZE: Size = { width: 1280, height: 800, scale: 1 };
/// JPEG quality of the frames asked for: 82 in JPEG fallback, 88 as H.264 source input.
const JPEG_QUALITY = 82;
const H264_JPEG_QUALITY = 88;

/// One connection to a host's frame port: its lines heard, a picture asked for and its bytes read.
export class FrameLink {
  readonly #socket: Socket;
  #buffer: Buffer = Buffer.alloc(0);
  /// The picture whose bytes come next, and who waits for it.
  #pending: { header: any; resolve: (f: { header: any; data: Buffer } | null) => void } | null = null;
  readonly #asked: ((f: { header: any; data: Buffer } | null) => void)[] = [];
  #closed = false;
  heard: (message: any) => void = () => {};
  ended: () => void = () => {};

  constructor(port: number) {
    this.#socket = connect({ host: "127.0.0.1", port });
    this.#socket.on("data", (chunk) => this.#data(chunk));
    this.#socket.once("close", () => this.#end());
    this.#socket.once("error", () => this.#end());
  }

  send(message: object) {
    if (!this.#closed) this.#socket.write(`${JSON.stringify(message)}\n`);
  }

  /// A picture of the tab now; null when the connection ended first.
  picture(format: "jpeg" = "jpeg", quality: number = JPEG_QUALITY): Promise<{ header: any; data: Buffer } | null> {
    if (this.#closed) return Promise.resolve(null);
    return new Promise((resolve) => {
      this.#asked.push(resolve);
      this.send({ frame: { format, quality } });
    });
  }

  #data(chunk: Buffer) {
    this.#buffer = this.#buffer.length === 0 ? chunk : Buffer.concat([this.#buffer, chunk]);
    for (;;) {
      if (this.#pending !== null) {
        const n = Number(this.#pending.header.bytes);
        if (this.#buffer.length < n) return;
        const data = this.#buffer.subarray(0, n);
        this.#buffer = this.#buffer.subarray(n);
        const { header, resolve } = this.#pending;
        this.#pending = null;
        resolve({ header, data: Buffer.from(data) });
        continue;
      }
      const nl = this.#buffer.indexOf(10);
      if (nl < 0) return;
      const line = this.#buffer.subarray(0, nl).toString("utf8");
      this.#buffer = this.#buffer.subarray(nl + 1);
      let message: any;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      if (message?.frame && typeof message.frame === "object") {
        const resolve = this.#asked.shift();
        const header = message.frame;
        if (!(Number(header.bytes) >= 0)) {
          resolve?.(null);
          continue;
        }
        this.#pending = { header, resolve: resolve ?? (() => {}) };
        continue;
      }
      this.heard(message);
    }
  }

  #end() {
    if (this.#closed) return;
    this.#closed = true;
    this.#pending?.resolve(null);
    this.#pending = null;
    for (const resolve of this.#asked.splice(0)) resolve(null);
    this.ended();
  }

  close() {
    this.#socket.destroy();
    this.#end();
  }
}

/// A person's input as the host takes it: the view's 0..1 of the screen made the pictures' pixels (W·S × H·S) for a
/// pointer, CSS pixels of the viewport for a wheel.
export function inputOf(e: ScreenInput, size: Size): object | null {
  const r = (n: number) => Math.round(n * 100) / 100;
  switch (e.t) {
    case "pointer":
      return { pointer: { type: e.kind, x: r(e.x * size.width * size.scale), y: r(e.y * size.height * size.scale), button: 0, buttons: e.buttons } };
    case "wheel":
      return { wheel: { x: r(e.x * size.width), y: r(e.y * size.height), dx: e.dx, dy: e.dy } };
    case "key":
      return { key: { type: e.kind, key: e.key, code: e.code, mods: e.mods } };
    case "text":
      return { text: e.text };
    default:
      return null;
  }
}

/// The viewport a view asks for: its viewer's own screen where it says one (a phone), else what fits its bounds.
export function sizeFor(o: ViewOptions): Size {
  if (o.fit !== undefined && o.fit.width > 0 && o.fit.height > 0) return { width: Math.round(o.fit.width), height: Math.round(o.fit.height), scale: o.fit.scale > 0 ? o.fit.scale : 1 };
  const k = Math.min(1, o.maxWidth / DEFAULT_SIZE.width, o.maxHeight / DEFAULT_SIZE.height);
  return k >= 1 || !(k > 0) ? DEFAULT_SIZE : { width: DEFAULT_SIZE.width, height: DEFAULT_SIZE.height, scale: k };
}

export class FarviewScreen implements ScreenSource {
  readonly id: string;
  readonly kind = "browser" as const;
  readonly peek = true;
  readonly farview = true;
  readonly #session: string;
  readonly #port: number;
  readonly #helper: HelperApp | null | undefined;
  readonly #createEncoder: BrowserVideoEncoderFactory | undefined;
  #page: FramePage = { url: "", title: "" };
  #size: Size = DEFAULT_SIZE;
  #watch: FrameLink | null = null;
  readonly #views = new Set<FarviewView>();
  #closed = false;
  changed: () => void = () => {};
  /// Hears each new tab the page asks for, by its address and what links it to this tab.
  opened: (url: string, meta: OpenTabMeta) => void = () => {};
  /// Hears the page close its tab (window.close() in a window a page opened).
  closedByPage: () => void = () => {};

  /// `n`: which of its chat's tabs (0 its first, whose id is the chat's alone).
  constructor(o: { session: string; port: number; n?: number; helper?: HelperApp | null; createEncoder?: BrowserVideoEncoderFactory }) {
    this.#session = o.session;
    this.#port = o.port;
    this.#helper = o.helper;
    this.#createEncoder = o.createEncoder;
    this.id = `browser:fv_${chatDir(o.session)}${o.n ? `_${o.n}` : ""}`;
  }

  /// Hears the tab's page and size on a connection of its own while the host runs.
  watch() {
    if (this.#closed || this.#watch !== null) return;
    const link = new FrameLink(this.#port);
    link.heard = (m) => {
      this.heard(m);
      const open = openTabOf(m);
      if (open !== null) this.opened(open.url, open.meta);
      if (m?.closeTab === true) this.closedByPage();
    };
    link.ended = () => {
      if (this.#watch === link) this.#watch = null;
    };
    this.#watch = link;
  }

  heard(m: any) {
    if (m?.page && typeof m.page === "object") {
      const page = { url: String(m.page.url ?? ""), title: String(m.page.title ?? "") };
      if (page.url !== this.#page.url || page.title !== this.#page.title) {
        this.#page = page;
        this.changed();
      }
    }
    if (m?.size && typeof m.size === "object" && m.size.width > 0 && m.size.height > 0) this.#size = { width: m.size.width, height: m.size.height, scale: m.size.scale > 0 ? m.size.scale : this.#size.scale };
  }

  page(): FramePage {
    return this.#page;
  }

  title(): string {
    return this.#page.title || this.#page.url || "Farview";
  }

  size() {
    return { width: Math.round(this.#size.width * this.#size.scale), height: Math.round(this.#size.height * this.#size.scale) };
  }

  openedBy() {
    return this.#session;
  }

  /// Text both ways: what a person copies on the tab reaches their clipboard, what they paste is put where its focus is.
  clipboard(): ClipType[] {
    return ["text"];
  }

  site() {
    try {
      return new URL(this.#page.url).host || undefined;
    } catch {
      return undefined;
    }
  }

  address() {
    return this.#page.url || "about:blank";
  }

  viewing(): number {
    return [...this.#views].filter((v) => !v.peek).length;
  }

  async open(options: ViewOptions): Promise<ScreenView> {
    if (this.#closed) throw new Error("This chat's browser was closed.");
    if (!options.codecs.includes("jpeg") && !options.codecs.includes("h264")) throw new Error("This tab is sent as H.264 or JPEG, which this app does not take.");
    let encoder: BrowserVideoEncoder | null = null;
    if (!options.peek && options.codecs.includes("h264")) {
      const sz = sizeFor(options);
      encoder = await createBrowserVideoEncoder({
        helper: this.#helper !== undefined ? this.#helper : defaultFarviewHelper,
        width: Math.round(sz.width * sz.scale),
        height: Math.round(sz.height * sz.scale),
        bitrate: options.bitrate,
        fps: options.fps,
        factory: this.#createEncoder,
      });
    }
    if (encoder === null && !options.codecs.includes("jpeg")) {
      throw new Error("This tab needs H.264 or JPEG, and no H.264 encoder is available.");
    }
    const view = new FarviewView(this, new FrameLink(this.#port), options, encoder, () => this.#views.delete(view));
    this.#views.add(view);
    return view;
  }

  close() {
    this.#closed = true;
    this.#watch?.close();
    for (const v of [...this.#views]) v.close();
  }
}

class FarviewView implements ScreenView {
  readonly peek: boolean;
  readonly #link: FrameLink;
  readonly #screen: FarviewScreen;
  readonly #gone: () => void;
  readonly #encoder: BrowserVideoEncoder | null;
  #size: Size;
  /// Who hears what this view's person copies on the tab.
  #copied: ((clip: Clip) => void) | null = null;
  /// The newest picture the host said it has, and the one last sent.
  #seq = 1;
  #sent = 0;
  #config: FrameConfig | null = null;
  #wake: (() => void) | null = null;
  #closed = false;
  #ts = 0;

  constructor(screen: FarviewScreen, link: FrameLink, o: ViewOptions, encoder: BrowserVideoEncoder | null, gone: () => void) {
    this.#screen = screen;
    this.#link = link;
    this.#encoder = encoder;
    this.#gone = gone;
    this.peek = o.peek === true;
    this.#size = sizeFor(o);
    link.heard = (m) => {
      screen.heard(m);
      if (typeof m?.copied === "string" && m.copied !== "" && Buffer.byteLength(m.copied, "utf8") <= CLIP_TEXT_MAX) this.#copied?.({ type: "text", text: m.copied });
      if (typeof m?.changed === "number" && m.changed > this.#seq) this.#seq = m.changed;
      // (the host tells the tab's viewport, never this view's scale: its pictures stay at the scale it asked, and a
      // person's pointer is of them. Taken as 1, every tap of a 2x view landed at half its place)
      if (m?.size && typeof m.size === "object" && m.size.width > 0 && m.size.height > 0) this.#size = { width: m.size.width, height: m.size.height, scale: this.#size.scale };
      this.#poke();
    };
    link.ended = () => this.close();
    // A preview looks at the tab as it is laid out; a view lays it out for its viewer.
    if (!this.peek) link.send({ size: this.#size });
    if (this.#encoder !== null) void this.#pumpH264();
  }

  #poke() {
    const wake = this.#wake;
    this.#wake = null;
    wake?.();
  }

  async #pumpH264() {
    const encoder = this.#encoder;
    if (encoder === null) return;
    try {
      while (!this.#closed) {
        while (!this.#closed && this.#seq <= this.#sent) await new Promise<void>((resolve) => (this.#wake = resolve));
        if (this.#closed) break;
        const asked = this.#seq;
        const got = await this.#link.picture("jpeg", H264_JPEG_QUALITY);
        if (got === null || this.#closed) break;
        this.#sent = Math.max(asked, Number(got.header.seq) || asked);
        this.#ts = Math.max(this.#ts + 1, Math.round(wall.now() * 1000));
        encoder.pushJpeg(got.data, this.#ts);
      }
    } catch {}
    if (!this.#closed) this.close();
  }

  async next(): Promise<Frame | null> {
    if (this.#encoder !== null) return this.#encoder.next();
    while (!this.#closed && this.#seq <= this.#sent) await new Promise<void>((resolve) => (this.#wake = resolve));
    if (this.#closed) return null;
    const asked = this.#seq;
    const got = await this.#link.picture();
    if (got === null) return null;
    this.#sent = Math.max(asked, Number(got.header.seq) || asked);
    const width = Number(got.header.width) || 0, height = Number(got.header.height) || 0;
    let config: FrameConfig | undefined;
    if (this.#config === null || this.#config.width !== width || this.#config.height !== height) {
      config = this.#config = { codec: "jpeg", width, height };
    }
    // ts in microseconds, rising: the order pictures were taken in is all a JPEG view goes by.
    this.#ts += 1;
    return { ...(config ? { config } : {}), key: true, ts: this.#ts, data: got.data };
  }

  rate(bps: number) {
    if (!this.#closed && this.#encoder !== null) this.#encoder.setBitrate(bps);
  }

  keyframe() {
    if (this.#encoder !== null) {
      this.#encoder.requestKeyframe();
      return;
    }
    if (this.#sent >= this.#seq) this.#sent = this.#seq - 1;
    this.#poke();
  }

  async input(event: ScreenInput): Promise<void> {
    const m = inputOf(event, this.#size);
    if (m !== null) this.#link.send(m);
  }

  /// A paste: the text put where the tab's focus is, as typed (the host has no clipboard of its own).
  async setClipboard(clip: Clip, paste: boolean): Promise<void> {
    if (clip.type === "text" && paste && clip.text !== "") this.#link.send({ text: clip.text });
  }

  watchClipboard(heard: (clip: Clip) => void): () => void {
    this.#copied = heard;
    return () => {
      if (this.#copied === heard) this.#copied = null;
    };
  }

  bounds(maxWidth: number, maxHeight: number) {
    if (this.peek) return;
    const size = sizeFor({ maxWidth, maxHeight, codecs: this.#encoder ? ["h264", "jpeg"] : ["jpeg"] });
    if (size.width === this.#size.width && size.height === this.#size.height && size.scale === this.#size.scale) return;
    this.#size = size;
    this.#link.send({ size });
  }

  video(): ScreenVideo {
    if (this.#encoder !== null) {
      const info = this.#encoder.info();
      return { capture: "Farview", encoder: info.encoder, hardware: info.hardware };
    }
    return { capture: "Farview" };
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#encoder?.close();
    this.#link.close();
    this.#gone();
    this.#poke();
    log.info("browser", "a view of a chat's Farview ended", { screen: this.#screen.id });
  }
}
