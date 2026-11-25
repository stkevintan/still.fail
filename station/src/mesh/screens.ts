// A view of one of the station's screens over a member's link ("Wire"): a stream whose head
// line has a `screen` object, answered 200 `application/x-stillfail-screen`, then frames both ways, each a kind byte,
// its payload's length (4 bytes, big-endian) and the payload. Station → client: `config`, `video`, `state`, and
// `cursor` to a client that asked for it (`binaryCursor`: the pointer in a few bytes, cursorPayload, never a state's
// JSON), `cursorImage` to one that asked `customCursor` (a pointer of an app's own, before the first `cursor` or state
// naming it "custom:<id>": source.ts `cursorImageShape`; to one that did not, such a shape is "default"); client →
// station: `input`, `ack`, `keyframe`, `sound` (1 byte: 0 the client muted the sound, none goes; 1 on again), `micOn`
// (1 byte: 1 the person shares their microphone into the screen's virtual one, 0 no more; a driver's alone), `mic` (a
// packet of it: flags, the recording's epoch u32 big-endian, 48 kHz mono s16le; taken only while an app there records
// it in that epoch, said to the client as the state's `mic`), `look`
// (the part of the screen it shows, zoomed in: its frames are then of that part, as large as the client shows it, each
// config saying which part); and the screen's clipboard both ways (`clipboard`), for a view that drives it
// (the station sends it as it changes, the client to set it and paste; a copy an app marked private, a password
// manager's, goes as `privateClipboard` to a client that asked `privateClip`, its mark first, and as `clipboard` to
// one before it, whose reader takes no other first byte than the type's; the client's own mark rides in its flags). The source is asked for a frame only while the
// `Pacer` lets one go: as many as the link holds (a far one holds several), none while the oldest not acknowledged
// waits longer than the link takes with no queue; and the source is asked for the bit rate the link carries
// (screen-pace.ts). So a slow link lowers the bit rate, then the frame rate, rather than queueing frames.
//
// A read-only member views, their input is dropped. The view ends when the client finishes its side (`ended:
// "finished"`), the source goes (`"gone"`, also when it has no more frames), the station stops (`"stopping"`), or the
// stream or its connection breaks (nothing more is written then); its source's capture stops with it.
import { type Clock, Duration, Effect } from "effect";
import { langOfCore } from "../api/request.ts";
import { liveClock } from "../ops/fibers.ts";
import { type Lang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { type AccessShown, type ScreenHub, ScreenRefused, accessShown, addressShown } from "../screens/hub.ts";
import { type Clip, type ClipType, type Codec, type Frame, type FrameConfig, type LoginFill, type PasskeyAnswer, type Region, type ScreenCursor, type ScreenInput, type ScreenMic, type ScreenSource, type ScreenView, type ViewFit, CLIP_PNG_MAX, CURSOR_IMAGES_MOST, GAMEPAD_BUTTONS, GAMEPADS_MOST, PRIVACY_CODE, clipFits, gamepadReleased, MIC_PCM_MAX, privacyOf, regionOf } from "../screens/source.ts";
import { type Viewer, readOnly } from "./credential.ts";
import type { Connection } from "./endpoint.ts";
import type { Stream } from "./native.ts";
import { type Fps, FrameLatency, LOSS_EVERY_MS, LinkLoss, Pacer, QUALITIES, type Quality, STILL_MS, START_RATE, Sharpener, Sizer, isFps, loopStall, ownRate, rateCeiling, startRate } from "./screen-pace.ts";
import { writeLine } from "./serve.ts";

export const SCREEN_TYPE = "application/x-stillfail-screen";
/// Ceiling bit rate for JPEG views that support dynamic rate degradation (e.g. Chrome screencast), allowing Pacer to
/// climb back up after congestion clears.
export const JPEG_RATE_CEILING = 4_000_000;
/// The header of a view's reply that says its frames go as datagrams, with the client's token.
export const DGRAM_HEADER = "x-screen-dgram";
export const KIND = { config: 1, video: 2, state: 3, clipboard: 4, audioConfig: 5, audio: 6, cursor: 7, cursorImage: 8, privateClipboard: 9, input: 16, ack: 17, keyframe: 18, setClipboard: 19, look: 20, sound: 21, micOn: 22, mic: 23 } as const;
/// A client's frame is an input event at most: one larger ends the view.
export const MAX_IN = 64 * 1024;
/// A client's `clipboard` frame is its flags, its type and a picture at most.
export const MAX_CLIP_IN = 2 + CLIP_PNG_MAX;
/// How large a client's frame of a kind may be.
export const limitIn = (kind: number) => (kind === KIND.setClipboard ? MAX_CLIP_IN : MAX_IN);
/// A clip's type byte on the wire.
const CLIP_BYTE: Record<ClipType, number> = { text: 1, png: 2 };
const CODECS: Codec[] = ["h265", "h264", "jpeg"];
const PATH = /^\/admin\/api\/screens\/([^/?]+)\/view$/;

export function frame(kind: number, payload: Buffer): Buffer {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

export function configPayload(c: FrameConfig): Buffer {
  return Buffer.from(JSON.stringify({ codec: c.codec, width: c.width, height: c.height, ...(c.description ? { description: Buffer.from(c.description).toString("base64") } : {}), ...(c.region ? { region: c.region } : {}) }));
}

export function videoPayload(f: Frame): Buffer {
  const head = Buffer.alloc(9);
  head[0] = f.key ? 1 : 0;
  head.writeBigUInt64BE(BigInt(Math.max(0, Math.floor(f.ts))), 1);
  return Buffer.concat([head, f.data]);
}

/// The most of a pointer's shape a `cursor` frame carries (its UTF-8): a longer one goes without it.
export const CURSOR_SHAPE_MAX = 64;

/// A `cursor` frame's payload: none for no pointer shown; else x and y (0..1 of the screen, each in 16 bits,
/// big-endian, of 65535) and the shape's UTF-8 (none: no shape said).
export function cursorPayload(cursor: { x: number; y: number; shape?: string } | null): Buffer {
  if (cursor === null) return Buffer.alloc(0);
  const shape = typeof cursor.shape === "string" ? Buffer.from(cursor.shape, "utf8") : Buffer.alloc(0);
  const out = Buffer.alloc(4 + (shape.length <= CURSOR_SHAPE_MAX ? shape.length : 0));
  out.writeUInt16BE(Math.round(unit(num(cursor.x) ? cursor.x : 0) * 65535), 0);
  out.writeUInt16BE(Math.round(unit(num(cursor.y) ? cursor.y : 0) * 65535), 2);
  if (out.length > 4) shape.copy(out, 4);
  return out;
}

/// A clip as a `clipboard` frame's payload has it after its flags (station → client: none): its type byte, its bytes.
export function clipPayload(clip: Clip, flags?: number): Buffer {
  const body = clip.type === "text" ? Buffer.from(clip.text, "utf8") : Buffer.from(clip.data);
  return Buffer.concat([Buffer.from(flags === undefined ? [CLIP_BYTE[clip.type]] : [flags, CLIP_BYTE[clip.type]]), body]);
}

/// A `privateClipboard` frame's payload: the clip's mark (1 concealed, 2 transient, 3 auto), its type byte, its bytes.
export function privateClipPayload(clip: Clip & { privacy: NonNullable<Clip["privacy"]> }): Buffer {
  return clipPayload(clip, PRIVACY_CODE[clip.privacy]);
}

/// A client's `clipboard` frame: the clip (within its bounds, with the mark its flags' bits 1..2 say) and whether to
/// paste it (bit 0); null when it is none.
export function parseClip(payload: Buffer): { clip: Clip; paste: boolean } | null {
  if (payload.length < 3) return null;
  const paste = (payload[0]! & 1) === 1;
  const privacy = privacyOf((payload[0]! >> 1) & 3);
  const body = payload.subarray(2);
  const clip: Clip | null = payload[1] === CLIP_BYTE.text ? { type: "text", text: body.toString("utf8") } : payload[1] === CLIP_BYTE.png ? { type: "png", data: new Uint8Array(body) } : null;
  return clip !== null && clipFits(clip) ? { clip: privacy ? { ...clip, privacy } : clip, paste } : null;
}

/// What a client's input frame asks of the display's scale (`{t: "scale", percent}`): the percent, or null when it is
/// not that.
export function parseScale(v: any): number | null {
  return v !== null && typeof v === "object" && v.t === "scale" && Number.isInteger(v.percent) && v.percent >= 100 && v.percent <= 500 ? v.percent : null;
}

/// What a client's input frame asks of the display's resolution (`{t: "resolution", width, height}`): the size, or null
/// when it is not that.
export function parseResolution(v: any): { width: number; height: number } | null {
  const n = (x: unknown) => Number.isInteger(x) && (x as number) >= 640 && (x as number) <= 16384;
  return v !== null && typeof v === "object" && v.t === "resolution" && n(v.width) && n(v.height) ? { width: v.width, height: v.height } : null;
}

/// What a client's input frame asks of the device's media volume (`{t: "volume"}` to read it again, `{t: "volume",
/// level}` to set it): the level (null: read it), or undefined when it is not that.
export function parseVolume(v: any): number | null | undefined {
  if (v === null || typeof v !== "object" || v.t !== "volume") return undefined;
  if (v.level === undefined) return null;
  return Number.isInteger(v.level) && v.level >= 0 && v.level <= 1000 ? v.level : undefined;
}

/// What a client's input frame asks of the file manager (`{t: "reveal", path}`): the path, or null when it is not that.
export function parseReveal(v: any): string | null {
  return v !== null && typeof v === "object" && v.t === "reveal" && typeof v.path === "string" && v.path !== "" && v.path.length <= 4096 ? v.path : null;
}

/// What a client's input frame fills a login form with (`{t: "fill", host, username?, password?}`: from the person's own
/// password manager, for the site the view's state said): null when it is not that. Each word is a field's: 1024
/// characters at most.
export function parseFill(v: any): LoginFill | null {
  if (v === null || typeof v !== "object" || v.t !== "fill" || typeof v.host !== "string" || v.host === "" || v.host.length > 253) return null;
  const word = (x: unknown) => typeof x === "string" && x.length <= 1024;
  if ((v.username !== undefined && !word(v.username)) || (v.password !== undefined && !word(v.password)) || (v.username === undefined && v.password === undefined)) return null;
  return { host: v.host, ...(v.username !== undefined ? { username: v.username } : {}), ...(v.password !== undefined ? { password: v.password } : {}) };
}

/// What a client's input frame answers a page's passkey sign-in with (`{t: "passkey", id, credential, authenticatorData,
/// signature, userHandle?, clientData?}`, base64url, signed by the person's own device; or `{t: "passkey", id, error}`): null when it
/// is not that.
export function parsePasskey(v: any): PasskeyAnswer | null {
  if (v === null || typeof v !== "object" || v.t !== "passkey" || typeof v.id !== "string" || v.id === "" || v.id.length > 32) return null;
  if (v.error !== undefined) return typeof v.error === "string" && /^[A-Za-z]{1,40}$/.test(v.error) ? { id: v.id, error: v.error } : null;
  const b64 = (x: unknown, most = 8192): x is string => typeof x === "string" && x !== "" && x.length <= most && /^[A-Za-z0-9_-]+$/.test(x);
  if (!b64(v.credential) || !b64(v.authenticatorData) || !b64(v.signature) || (v.userHandle !== undefined && !b64(v.userHandle)) || (v.clientData !== undefined && !b64(v.clientData, 49152))) return null;
  return { id: v.id, credential: v.credential, authenticatorData: v.authenticatorData, signature: v.signature, ...(v.userHandle !== undefined ? { userHandle: v.userHandle } : {}), ...(v.clientData !== undefined ? { clientData: v.clientData } : {}) };
}

/// A client's `look` frame (JSON `{region, maxWidth, maxHeight}`): the part of the screen it shows (null: the whole) and
/// the bounds its pictures are to fit in (the view's own when not said, or for the whole); null when it is none.
/// A client's `mic` frame: flags (bit 0 clear: 48 kHz mono `pcm_s16le`, the only one there is), the recording's epoch
/// (u32, big-endian), then the samples, an even number of bytes, none and at most `MIC_PCM_MAX`; else null.
export function parseMic(payload: Buffer): { epoch: number; pcm: Uint8Array } | null {
  if (payload.length < 7 || payload.length > 5 + MIC_PCM_MAX || (payload[0]! & 1) !== 0) return null;
  const pcm = payload.subarray(5);
  if (pcm.length % 2 !== 0) return null;
  return { epoch: payload.readUInt32BE(1), pcm: new Uint8Array(pcm) };
}

export function parseLook(payload: Buffer, own: { maxWidth: number; maxHeight: number }): { region: Region | null; maxWidth: number; maxHeight: number } | null {
  let v: any;
  try {
    v = JSON.parse(payload.toString("utf8"));
  } catch {
    return null;
  }
  if (v === null || typeof v !== "object") return null;
  const region = regionOf(v.region);
  if (region === null) return { region: null, ...own };
  const bound = (n: unknown, otherwise: number) => (num(n) ? Math.min(8192, Math.max(16, Math.round(n))) : otherwise);
  return { region, maxWidth: bound(v.maxWidth, own.maxWidth), maxHeight: bound(v.maxHeight, own.maxHeight) };
}

/// Frames from a stream, after what came with its head line.
export class FrameIn {
  #carry: Buffer;
  readonly #stream: Stream;
  readonly #limit: (kind: number) => number;
  /// `limit`: the largest frame taken, or by its kind (the station takes a client's input frames and its clipboard;
  /// a client reads video frames).
  constructor(stream: Stream, carry: Buffer = Buffer.alloc(0), limit: number | ((kind: number) => number) = limitIn) {
    this.#stream = stream;
    this.#carry = carry;
    this.#limit = typeof limit === "number" ? () => limit : limit;
  }

  /// The next frame, or null where the stream finished between frames; throws where it ended inside one, or one is
  /// larger than its limit.
  async next(): Promise<{ kind: number; payload: Buffer } | null> {
    for (;;) {
      if (this.#carry.length >= 5) {
        const length = this.#carry.readUInt32BE(1);
        if (length > this.#limit(this.#carry[0]!)) throw new Error("screen frame too large");
        if (this.#carry.length >= 5 + length) {
          const kind = this.#carry[0]!;
          const payload = this.#carry.subarray(5, 5 + length);
          this.#carry = this.#carry.subarray(5 + length);
          return { kind, payload };
        }
      }
      const more = await this.#stream.read();
      if (more === null) {
        if (this.#carry.length === 0) return null;
        throw new Error("stream ended inside a screen frame");
      }
      this.#carry = this.#carry.length === 0 ? more : Buffer.concat([this.#carry, more]);
    }
  }
}

const num = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const unit = (v: number) => Math.min(1, Math.max(0, v));

/// A view's pick of one of a desktop's windows (`{t: "window", id}`: its id, or none for the whole display): undefined
/// when it is not one.
export function parseWindowPick(v: any): number | null | undefined {
  if (v === null || typeof v !== "object" || v.t !== "window") return undefined;
  if (v.id === undefined || v.id === null) return null;
  return Number.isInteger(v.id) && v.id > 0 && v.id < 2 ** 32 ? v.id : undefined;
}

/// A client's input event, checked: null when it is not one.
export function parseInput(v: any): ScreenInput | null {
  if (v === null || typeof v !== "object") return null;
  switch (v.t) {
    case "pointer": {
      if (!["down", "up", "move"].includes(v.kind) || !num(v.x) || !num(v.y)) return null;
      const e: Extract<ScreenInput, { t: "pointer" }> = { t: "pointer", kind: v.kind, x: unit(v.x), y: unit(v.y), buttons: num(v.buttons) ? v.buttons & 7 : 0 };
      // How far the person's pointer moved, in the screen's pixels: a move's alone; posted as only that (`relative`)
      // where it says so, and a button pressed or let go of where the pointer is (an app holds it: never put back at x, y).
      const relative = v.relative === true ? { relative: true } : {};
      if (v.kind !== "move") return { ...e, ...relative };
      if (!num(v.dx) || !num(v.dy)) return e;
      const d = (n: number) => Math.max(-10_000, Math.min(10_000, n));
      return { ...e, dx: d(v.dx), dy: d(v.dy), ...relative };
    }
    case "wheel":
      if (!num(v.x) || !num(v.y) || !num(v.dx) || !num(v.dy)) return null;
      return { t: "wheel", x: unit(v.x), y: unit(v.y), dx: Math.max(-10_000, Math.min(10_000, v.dx)), dy: Math.max(-10_000, Math.min(10_000, v.dy)) };
    case "key":
      if (!["down", "up"].includes(v.kind) || typeof v.key !== "string" || typeof v.code !== "string" || v.key.length > 64 || v.code.length > 64) return null;
      return { t: "key", kind: v.kind, key: v.key, code: v.code, mods: num(v.mods) ? v.mods & 15 : 0 };
    case "text":
      if (typeof v.text !== "string" || v.text.length === 0 || v.text.length > 4096) return null;
      return { t: "text", text: v.text };
    case "pose":
      return v.name === "closed" || v.name === "book" || v.name === "open" ? { t: "pose", name: v.name } : null;
    case "device":
      return v.name === "volume_up" || v.name === "volume_down" || v.name === "memory_warning" || v.name === "rotate" ? { t: "device", name: v.name } : null;
    case "button":
      return Number.isInteger(v.page) && Number.isInteger(v.usage) && v.page > 0 && v.page < 0x10000 && v.usage > 0 && v.usage < 0x10000 && typeof v.down === "boolean" ? { t: "button", page: v.page, usage: v.usage, down: v.down } : null;
    case "gamepad": {
      if (!Number.isInteger(v.index) || v.index < 0 || v.index >= GAMEPADS_MOST) return null;
      if (v.connected === false) return gamepadReleased(v.index);
      if (!Number.isInteger(v.buttons) || ![v.lx, v.ly, v.rx, v.ry, v.lt, v.rt].every(num)) return null;
      const axis = (n: number) => Math.max(-1, Math.min(1, n));
      const trigger = (n: number) => Math.max(0, Math.min(1, n));
      return { t: "gamepad", index: v.index, connected: true, buttons: v.buttons & GAMEPAD_BUTTONS, lx: axis(v.lx), ly: axis(v.ly), rx: axis(v.rx), ry: axis(v.ry), lt: trigger(v.lt), rt: trigger(v.rt) };
    }
    default:
      return null;
  }
}

/// Digital silence: a source from before that sends it (an older still.fail Helper, stillfail-screen) sends 1.5 Mbit/s
/// of zeros while nothing plays; from QUIET packets of it in a row (200 ms) it is left out, the client's player waiting
/// for sound as after any gap; shorter (between two sounds) it goes. Opus's is the sources' own to leave out (none from
/// before sends Opus).
const silent = (pcm: Uint8Array) => pcm.every((b) => b === 0);
const QUIET = 10;

/// What a view's ask says: its bounds (16..8192, 1920×1080 when not said), the codecs it takes (ours only), the 画质
/// chosen (`quality`: the most its bit rate goes to; none for 自动 and from a client before it), the 帧率 chosen (`fps`:
/// 120, 90, 60, 30 or 15, the most frames a second; none for 自动 and from a client before it), and the phone it is
/// laid out for (`fit`: 200..2000 CSS pixels a side, scale 1..4; only a view that drives it); `gamut: "p3"`: the client
/// shows a video tagged Display P3 as such (none: sRGB's colours); `client` and `app`: the app's own name and kind, to tell
/// its people which device a view is on; `audio: "pcm_s16le"` the computer's sound, with `opus` where the client
/// decodes Opus too (a station from before sends PCM to it); `self`: the device's main id, for it to know its own views; `taken`: its person
/// asked to drive it (控制, 接管): it takes it from whoever else drives it, and over having been made to only look (hub.ts `drive`);
/// `binaryCursor`: the client reads the pointer as `cursor` frames (none from a client before them, nor for a preview);
/// `customCursor`: it draws the pointers of apps' own from their `cursorImage` frames (none from a client before them,
/// nor for a preview);
/// `datagrams`: the token the client takes the video and audio frames under as datagrams (client/shell screen_dgram.rs;
/// none for a preview); `privateClip`: it reads `privateClipboard` frames (none for a preview); `chroma444`: it decodes
/// full-chroma video and wants text sharp (taken with 画质 原画 alone).
export function asked(screen: any): { maxWidth: number; maxHeight: number; codecs: Codec[]; control: boolean; peek: boolean; audio?: boolean; opus?: boolean; quality?: Quality; fps?: Fps; fit?: ViewFit; gamut?: "p3"; passkeys?: boolean; client?: string; app?: string; self?: string; taken?: boolean; binaryCursor?: boolean; customCursor?: boolean; datagrams?: number; privateClip?: boolean; chroma444?: boolean } {
  const bound = (v: unknown, otherwise: number) => (num(v) ? Math.min(8192, Math.max(16, Math.round(v))) : otherwise);
  const codecs = Array.isArray(screen.codecs) ? CODECS.filter((c) => screen.codecs.includes(c)) : [];
  // A preview (`peek`, a link's card in a chat) only looks.
  const peek = screen.peek === true;
  const control = screen.control === true && !peek;
  const f = screen.fit;
  const side = (v: unknown) => num(v) && v >= 200 && v <= 2000;
  const fit = control && f && side(f.width) && side(f.height) && num(f.scale) && f.scale >= 1 && f.scale <= 4 ? { width: Math.round(f.width), height: Math.round(f.height), scale: f.scale } : undefined;
  const quality: Quality | undefined = (QUALITIES as readonly unknown[]).includes(screen.quality) && !peek ? screen.quality : undefined;
  const fps: Fps | undefined = isFps(screen.fps) && !peek ? screen.fps : undefined;
  return { maxWidth: bound(screen.maxWidth, 1920), maxHeight: bound(screen.maxHeight, 1080), codecs, control, peek, ...(screen.audio === "pcm_s16le" && !peek ? { audio: true, ...(screen.opus === true ? { opus: true } : {}) } : {}), ...(quality ? { quality } : {}), ...(fps ? { fps } : {}), ...(fit ? { fit } : {}), ...(screen.gamut === "p3" ? { gamut: "p3" as const } : {}), ...(typeof screen.passkeys === "boolean" && !peek ? { passkeys: screen.passkeys } : {}), ...said("client", screen.client, 80), ...said("app", screen.app, 16), ...said("self", screen.self, 64), ...(screen.taken === true ? { taken: true } : {}), ...(screen.binaryCursor === true && !peek ? { binaryCursor: true } : {}), ...(screen.customCursor === true && !peek ? { customCursor: true } : {}), ...(Number.isInteger(screen.datagrams) && screen.datagrams > 0 && screen.datagrams <= 0xffff_ffff && !peek ? { datagrams: screen.datagrams as number } : {}), ...(screen.privateClip === true && !peek ? { privateClip: true } : {}), ...(screen.chroma444 === true && quality === "original" ? { chroma444: true } : {}) };
}

/// A word a client says of itself, as far as it is shown: a line's worth, none when it said none.
function said<K extends string>(field: K, v: unknown, most: number): { [F in K]?: string } {
  const word = typeof v === "string" ? v.replace(/[\p{Cc}\p{Cf}]/gu, "").trim().slice(0, most) : "";
  return (word === "" ? {} : { [field]: word }) as { [F in K]?: string };
}

/// A stream whose head says `"screen"` (serve.ts dispatches it): a view of a screen, for as long as both sides keep it.
/// `carry`: what came after the head line; `conn`: the connection it came on, whose paths say what of the view's link was
/// lost (none: nothing said of it) and where it goes (what the view starts at: `startRate`). Resolves once the view ended.
export async function answerScreen(hub: ScreenHub, stream: Stream, carry: Buffer, head: any, viewer: Viewer, up: () => boolean, clock: Clock.Clock = liveClock, conn?: Pick<Connection, "paths">): Promise<void> {
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(head.headers ?? {})) if (typeof v === "string") headers[k] = v;
  const lang = langOfCore(headers);
  const refuse = async (status: number, error: string, more: Record<string, unknown> = {}) => {
    await writeLine(stream, { status, headers: { "content-type": "application/json" } });
    await stream.write(Buffer.from(JSON.stringify({ error, ...more })));
    await stream.finish();
  };
  const method = typeof head.method === "string" ? head.method.toUpperCase() : "GET";
  const path = typeof head.path === "string" ? head.path : "";
  const found = PATH.exec(path);
  if (found === null || method !== "POST") return refuse(404, "a screen is viewed with POST /admin/api/screens/<id>/view");
  if (!up()) return refuse(502, "station unreachable: not started");
  let id: string;
  try {
    id = decodeURIComponent(found[1]!);
  } catch {
    return refuse(404, tr(lang, "station.screen.notFound"));
  }
  const source = hub.get(id);
  if (source === undefined) return refuse(404, tr(lang, "station.screen.notFound"));
  const ask = asked(head.screen);
  if (ask.codecs.length === 0) return refuse(400, `screen.codecs: one of ${CODECS.join(", ")}`);
  if (ask.peek && !source.peek) return refuse(501, "this screen is not previewed");
  if (readOnly(viewer) && source.sleeping?.()) return refuse(403, tr(lang, "station.screen.readOnlySleeping"));
  // A viewer (read-only member) sees, and does not drive; nor does anyone where the machine does not let the station
  // take input (a Mac without the Accessibility grant): said once it is open, when the source has looked again (what it
  // said before may be from before the grant was given).
  const name = viewer.name || viewer.email;
  const drives = ask.control && !readOnly(viewer);
  const driven = drives ? hub.drive(id, viewer.device, ask.taken === true, name) : { control: false, took: [] };
  // Asked once before the view opens: a front's connection reads its paths anew as it is asked, so what the view's loss
  // is counted from is the link's as the view begins, not as it was when last asked.
  const initialPaths = conn?.paths?.();
  // (a preview's at START_RATE: two pictures a second, no higher than the source's own)
  const initialRate = ask.peek ? START_RATE : startRate(initialPaths);
  const noPasskeys = ask.passkeys === false || (ask.passkeys === undefined && (ask.app === "ios" || ask.app === "android" || ask.app === "web"));
  let view: ScreenView;
  try {
    view = await source.open({ maxWidth: ask.maxWidth, maxHeight: ask.maxHeight, codecs: ask.codecs, ...(ask.audio ? { audio: true, ...(ask.opus ? { opus: true } : {}) } : {}), bitrate: initialRate, ...(ask.fps ? { fps: ask.fps } : {}), ...(ask.peek ? { peek: true } : {}), ...(ask.fit && driven.control ? { fit: ask.fit } : {}), ...(ask.gamut ? { gamut: ask.gamut } : {}), ...(driven.control && noPasskeys ? { passkeys: false } : {}), ...(ask.chroma444 ? { chroma: "444" as const } : {}), ...(ask.quality ? { quality: ask.quality } : {}) });
  } catch (error) {
    if (error instanceof ScreenRefused) {
      // What is missing says it all, and where it is granted.
      const access = accessShown(error.access, lang);
      return refuse(error.status, access?.message ?? tr(lang, error.key, error.args), access ? { access } : {});
    }
    return refuse(503, tr(lang, "station.screen.failed", { said: (error as Error).message }));
  }
  // Gone while it opened.
  if (hub.get(id) !== source) {
    view.close();
    return refuse(404, tr(lang, "station.screen.notFound"));
  }
  // Its picture and sound as datagrams where the client takes them under its token and the link carries them (the
  // reply says so: `x-screen-dgram`), else on the stream as before.
  const datagrams = ask.datagrams !== undefined && stream.mediaDatagrams ? await stream.mediaDatagrams(ask.datagrams).catch(() => false) : false;
  try {
    await writeLine(stream, { status: 200, headers: { "content-type": SCREEN_TYPE, ...(datagrams ? { [DGRAM_HEADER]: String(ask.datagrams) } : {}) } });
  } catch {
    view.close();
    return;
  }
  const access = accessShown(source.access?.(), lang);
  // (as the source has it now it is open: a grant it found missing as it opened drives nothing)
  const control = driven.control && access?.control !== false;
  const took = control ? driven.took : [];
  const now = () => Number(clock.monotonicTimeNanosUnsafe()) / 1e6;
  // How long the loop stood still, on the host's own clock: what the pacer's times on the view's clock leave out only
  // when that clock is the host's (the live one). On another (a TestClock) the host's stands are no part of its time,
  // and taken from it they let a frame go past a queue the view's own time says is there (screens.test.ts, main
  // 167113d7, 40953448608: 18 frames asked for, not 17, on a loaded runner).
  const stall = clock === liveClock ? loopStall.use() : { stalled: () => 0, done: () => {} };
  const pacer = new Pacer(now, initialRate, ask.fps, stall.stalled);
  const sizer = new Sizer(now, { maxWidth: ask.maxWidth, maxHeight: ask.maxHeight }, ask.quality);
  const sleep = (ms: number) => Effect.runPromise(clock.sleep(Duration.millis(ms)));
  await new ViewSession({ hub, id, source, view, stream, frames: new FrameIn(stream, carry), name, device: viewer.device, ...(ask.self ? { self: ask.self } : {}), ...(ask.client ? { client: ask.client } : {}), ...(ask.app ? { app: ask.app } : {}), control, took, peek: ask.peek, audio: ask.audio, access, lang, pacer, sizer, bounds: { maxWidth: ask.maxWidth, maxHeight: ask.maxHeight }, ...(ask.quality ? { quality: ask.quality } : {}), ...(ask.fps ? { fps: ask.fps } : {}), now, sleep, ...(conn?.paths ? { conn } : {}), startRate: initialRate, binaryCursor: ask.binaryCursor === true, customCursor: ask.customCursor === true, privateClip: ask.privateClip === true })
    .run()
    .finally(stall.done);
}

/// One view while it lasts.
class ViewSession {
  #closed = false;
  #done!: () => void;
  readonly #over = new Promise<void>((resolve) => (this.#done = resolve));
  /// Writes, in order; one that fails breaks the view.
  #writes: Promise<void> = Promise.resolve();
  /// Inputs, in order, each once the one before was posted; unsent pointer moves of the same buttons coalesce to the latest.
  #inputs: Promise<void> = Promise.resolve();
  #pendingMove: { buttons: number; run: () => Promise<void> } | null = null;
  #wake: () => void = () => {};
  /// The source's next frame, asked while the last one was being written (`#pump`): at most one.
  #ahead: Promise<Frame | null> | null = null;
  /// Whether the link's round trip is known (the first frame acknowledged): the sound waits for it.
  #timed = false;
  /// The client's sound is on (`sound`: it muted it, none goes till it is on again).
  #soundOn = true;
  #leave: () => void = () => {};
  #unwatch: () => void = () => {};
  #unclip: () => void = () => {};
  #unlock: () => void = () => {};
  /// The person shares their microphone (`micOn`), and the virtual one's state as the view said it last.
  #micOn = false;
  #mic: ScreenMic | null = null;
  #unmic: () => void = () => {};
  /// The controllers its input drove (their slots): let go of as it is made to only look (as it ends, its source's
  /// close lets go of all its input holds).
  readonly #pads = new Set<number>();
  /// The client reads `privateClipboard` frames (asked `privateClip`).
  readonly #privateClip: boolean;
  /// What the screen's clipboard last held as this view knows it (said to it, or set by it): the same again is no new
  /// copy. Windows bumps its clipboard's number several times for one copy (an app's delayed rendering, clipboard
  /// history), each read the same text: said once, not a toast each (pengxiao, 2026-11-12).
  #clipKnown: Buffer | null = null;
  #unlogin: () => void = () => {};
  #unpasskey: () => void = () => {};
  #unchild: () => void = () => {};
  #unpoint: () => void = () => {};
  #unturn: () => void = () => {};
  #unwindows: () => void = () => {};
  #title: string;
  #site: string | undefined;
  #address: string | undefined;
  /// The keys down and the pointer as its input last left them: let go of if it is made to only look.
  readonly #keys = new Map<string, Extract<ScreenInput, { t: "key" }>>();
  #pointer: Extract<ScreenInput, { t: "pointer" }> | null = null;
  /// The bit rate the source was last asked for, and the one it was opened at.
  #rate: number | null = null;
  readonly #startRate: number;
  /// The client reads the pointer as `cursor` frames (asked `binaryCursor`), not a state's JSON.
  readonly #binaryCursor: boolean;
  /// The client draws the pointers of apps' own (asked `customCursor`), and those whose pictures it was sent.
  readonly #customCursor: boolean;
  readonly #cursorImagesSent = new Set<string>();
  /// A still screen's picture sent again sharper (screen-pace.ts Sharpener), on the view's clock.
  readonly #sharpen = new Sharpener();
  #stillWait = false;
  readonly #now: () => number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #lang: Lang;

  readonly hub: ScreenHub;
  readonly id: string;
  readonly source: ScreenSource;
  readonly view: ScreenView;
  readonly stream: Stream;
  readonly frames: FrameIn;
  /// Whose it is, on which device, whether their input is taken (until another member makes it only look: `watchOnly`),
  /// and what is missing of the source's access (as they read it).
  readonly name: string;
  readonly device: string;
  readonly self: string | undefined;
  readonly client: string | undefined;
  readonly app: string | undefined;
  control: boolean;
  /// Whose views it took the screen from as it opened (its first state's `took`).
  readonly took: string[];
  /// A preview's: not among those on the screen.
  readonly peek: boolean;
  readonly audio: boolean;
  readonly access: AccessShown | undefined;
  readonly pacer: Pacer;
  readonly sizer: Sizer;
  /// The 画质 the view asked (none: 自动, or a client before it), and its 帧率 (none: 自动): the most its bit rate goes to
  /// (screen-pace.ts rateCeiling).
  readonly quality: Quality | undefined;
  readonly fps: number | undefined;
  /// How late its frames are (the statistics' 帧延时).
  readonly latency = new FrameLatency();
  /// How much of what went over its link was lost (the statistics' 丢包率), from its connection's paths.
  readonly loss: LinkLoss;
  readonly #conn: Pick<Connection, "paths"> | undefined;
  /// The picture's size, as its latest config said (H.264, H.265: what the bounds go by).
  #size: { width: number; height: number } | null = null;
  /// Whether the latest frame config is JPEG (no Sharpener keyframe resend).
  #jpeg = false;
  /// The bounds the view opened with (the whole screen's), and the part of the screen the client looks at now (null:
  /// the whole).
  readonly #own: { maxWidth: number; maxHeight: number };
  #region: Region | null = null;

  constructor(o: { hub: ScreenHub; id: string; source: ScreenSource; view: ScreenView; stream: Stream; frames: FrameIn; name: string; device: string; self?: string; client?: string; app?: string; control: boolean; took?: string[]; peek?: boolean; audio?: boolean; access: AccessShown | undefined; lang: Lang; pacer: Pacer; sizer: Sizer; bounds: { maxWidth: number; maxHeight: number }; quality?: Quality; fps?: number; now: () => number; sleep: (ms: number) => Promise<void>; conn?: Pick<Connection, "paths">; startRate?: number; binaryCursor?: boolean; customCursor?: boolean; privateClip?: boolean }) {
    this.hub = o.hub;
    this.id = o.id;
    this.source = o.source;
    this.view = o.view;
    this.stream = o.stream;
    this.frames = o.frames;
    this.name = o.name;
    this.device = o.device;
    this.self = o.self;
    this.client = o.client;
    this.app = o.app;
    this.control = o.control;
    this.took = o.took ?? [];
    this.peek = o.peek === true;
    this.audio = o.audio === true && !this.peek;
    this.access = o.access;
    this.pacer = o.pacer;
    this.sizer = o.sizer;
    this.quality = o.quality;
    this.fps = o.fps;
    this.#own = o.bounds;
    this.#now = o.now;
    this.#sleep = o.sleep;
    this.#lang = o.lang;
    this.#conn = o.conn;
    this.#startRate = o.startRate ?? START_RATE;
    this.#binaryCursor = o.binaryCursor === true;
    this.#customCursor = o.customCursor === true;
    this.#privateClip = o.privateClip === true;
    this.loss = new LinkLoss(o.now);
    // Its counters as the view begins: what went before is no part of it.
    if (this.#conn?.paths) this.loss.step(this.#conn.paths() ?? []);
    this.#title = o.source.title();
    this.#site = o.source.site?.();
    this.#address = addressShown(o.source.address?.());
  }

  /// A frame went: once the screen has been still for STILL_MS and cooled down for SHARPEN_COOLDOWN_MS, if the link is
  /// completely healthy and the last frame was encoded below SHARPEN_LOW_RATIO (< 60%) of the recovered rate, request a
  /// gentle refresh keyframe without spiking bitrate.
  #still(key = false) {
    this.#sharpen.sent(this.#now(), this.view.rate && !this.#jpeg ? (this.#rate ?? this.#startRate) : null, key);
    if (this.#stillWait) return;
    this.#stillWait = true;
    const wait = (ms: number) =>
      void this.#sleep(ms).then(() => {
        if (this.#closed) return;
        const left = this.#sharpen.left(this.#now());
        if (left > 0) return wait(left);
        this.#stillWait = false;
        if (this.#sharpen.due(this.#now(), this.#rate, this.pacer.healthy())) this.view.keyframe();
      });
    wait(STILL_MS);
  }

  #send(kind: number, payload: Buffer): Promise<void> {
    const written = this.#writes.then(() => this.stream.write(frame(kind, payload)));
    this.#writes = written.catch(() => this.#stop(null));
    return written.catch(() => {});
  }

  /// The pointer as the client is told it: one of an app's own, its picture sent first (once a view), to a client that
  /// draws them; else, and where its source has no picture of it, "default".
  #cursorShown(cursor: ScreenCursor | null): ScreenCursor | null {
    const shape = cursor?.shape;
    if (cursor === null || typeof shape !== "string" || !shape.startsWith("custom:") || (this.#customCursor && this.#cursorImagesSent.has(shape))) return cursor;
    const image = this.#customCursor ? this.view.cursorImage?.(shape) : undefined;
    if (image === undefined) return { ...cursor, shape: "default" };
    if (this.#cursorImagesSent.size >= CURSOR_IMAGES_MOST) this.#cursorImagesSent.clear();
    this.#cursorImagesSent.add(shape);
    void this.#send(KIND.cursorImage, Buffer.from(image));
    return cursor;
  }

  #state(state: Record<string, unknown>): Promise<void> {
    return this.#send(KIND.state, Buffer.from(JSON.stringify(state)));
  }

  /// Ends the view once: its capture stops, its people are told. `reason` null: the stream broke, nothing is written.
  #stop(reason: string | null) {
    if (this.#closed) return;
    this.#closed = true;
    this.#unclip();
    this.#unlock();
    this.#unmic();
    this.#unlogin();
    this.#unpasskey();
    this.#unchild();
    this.#unpoint();
    this.#unturn();
    this.#unwindows();
    this.view.close();
    this.#leave();
    this.#unwatch();
    this.#wake();
    if (reason === null) {
      this.#done();
      return;
    }
    void this.#state({ ended: reason })
      .then(() => this.#writes)
      .then(() => this.stream.finish())
      .catch(() => {})
      .finally(() => this.#done());
  }

  /// Another member made it only look (`by`: took it): what is a driver's alone goes, the pictures go on.
  #watchOnly(by?: string) {
    if (this.#closed || !this.control) return;
    this.control = false;
    this.#unclip();
    this.#unlock();
    this.#micOn = false;
    this.#unmic();
    this.#unmic = () => {};
    this.#mic = null;
    this.#unlogin();
    this.#unpasskey();
    this.#unchild();
    // What it holds down is let go of: the key or button's own release would be dropped now.
    const held = [...this.#keys.values()].map((e): ScreenInput => ({ ...e, kind: "up" }));
    const at = this.#pointer;
    this.#keys.clear();
    this.#pointer = null;
    if (at !== null && at.buttons !== 0) held.push({ ...at, kind: "up", buttons: 0 });
    for (const index of this.#pads) held.push(gamepadReleased(index));
    this.#pads.clear();
    for (const e of held) this.#then(() => this.view.input(e));
    // (an app's hold on the pointer is a driver's: said gone, to a view that was told it)
    void this.#state({ control: false, login: null, passkey: null, ...(this.view.watchPointerLock ? { pointerLock: false } : {}), ...(this.view.watchMic ? { mic: null } : {}), ...(by !== undefined ? { takenBy: by } : {}) });
  }

  async run(): Promise<void> {
    // How it starts: what it is and whether this view drives it; then who is on it (the hub tells everyone on it).
    // How its pictures are made (the statistics' 采集方式 and 编码器), where the source says.
    const video = this.view.video?.();
    void this.#state({
      title: this.#title,
      control: this.control,
      ...(this.#site ? { site: this.#site } : {}),
      ...(this.#address ? { address: this.#address } : {}),
      ...(this.source.openUrl ? { openUrl: true } : {}),
      ...(this.source.userTab ? { userTab: true } : {}),
      ...(this.took.length > 0 ? { took: this.took } : {}),
      ...(this.access ? { access: this.access } : {}),
      ...(video ? { video } : {}),
    });
    if (!this.peek) this.#leave = this.hub.join(this.id, { name: this.name, device: this.device, ...(this.self ? { self: this.self } : {}), ...(this.client ? { client: this.client } : {}), ...(this.app ? { app: this.app } : {}), control: this.control, tell: (people) => void this.#state(people), end: (by) => this.#stop(tr(this.#lang, "station.screen.endedBy", { by })), watchOnly: (by) => this.#watchOnly(by) });
    const unwatch = this.hub.watch(() => {
      if (this.hub.get(this.id) !== this.source) return this.#stop("gone");
      const title = this.source.title();
      const site = this.source.site?.();
      const address = addressShown(this.source.address?.());
      if (title !== this.#title || site !== this.#site || address !== this.#address) {
        const patch: Record<string, unknown> = {};
        if (title !== this.#title) {
          this.#title = title;
          patch.title = title;
        }
        if (site !== this.#site) {
          this.#site = site;
          patch.site = site ?? "";
        }
        if (address !== this.#address) {
          this.#address = address;
          patch.address = address ?? "";
        }
        void this.#state(patch);
      }
    });
    const unstop = this.hub.whenStopping(() => this.#stop("stopping"));
    this.#unwatch = () => (unwatch(), unstop());
    // The screen's clipboard, as it changes, to a person who drives it (never to one who only looks).
    const types = this.control ? (this.source.clipboard?.() ?? []) : [];
    if (types.length > 0 && this.view.watchClipboard) {
      this.#unclip = this.view.watchClipboard((clip) => {
        if (this.#closed || !types.includes(clip.type) || !clipFits(clip)) return;
        const payload = clipPayload(clip);
        if (this.#clipKnown !== null && this.#clipKnown.equals(payload)) return;
        this.#clipKnown = payload;
        // Marked private (a password manager's): with its mark to a client that reads it, else as any copy.
        if (clip.privacy !== undefined && this.#privateClip) void this.#send(KIND.privateClipboard, privateClipPayload({ ...clip, privacy: clip.privacy }));
        else void this.#send(KIND.clipboard, payload);
      });
    }
    // Whether an app on the screen holds the pointer (a game's), to a person who drives it: their app then sends moves
    // as relative ones.
    if (this.control && this.view.watchPointerLock) {
      this.#unlock = this.view.watchPointerLock((pointerLock) => {
        if (!this.#closed) void this.#state({ pointerLock });
      });
    }
    // The screen's virtual microphone, to a person who drives it: whether something there records it now, and which
    // recording, so their app sends their microphone only then (its packets dropped here otherwise).
    if (this.control && this.view.watchMic) {
      this.#unmic = this.view.watchMic((mic) => {
        this.#mic = mic;
        if (!this.#closed) void this.#state({ mic });
      });
    }
    // The login field in focus, to a person who drives it (their app offers to fill it from their password manager).
    if (this.control && this.view.watchLogin) {
      this.#unlogin = this.view.watchLogin((login) => {
        if (!this.#closed) void this.#state({ login });
      });
    }
    // A page's passkey sign-in, to a person who drives it (their app signs it with a passkey of their own device).
    if (this.control && this.view.watchPasskey) {
      this.#unpasskey = this.view.watchPasskey((passkey) => {
        if (!this.#closed) void this.#state({ passkey });
      });
    }
    // A child tab (`target="_blank"` or OAuth popup) opened while driving this tab.
    if (this.control && this.view.watchChild) {
      this.#unchild = this.view.watchChild((childScreen) => {
        if (!this.#closed) void this.#state({ childScreen });
      });
    }
    // The pointer, where the source's pictures leave it out (a video of the desktop): the client draws it.
    if (this.view.watchCursor) {
      this.#unpoint = this.view.watchCursor((cursor) => {
        if (this.#closed) return;
        const shown = this.#cursorShown(cursor);
        if (this.#binaryCursor) void this.#send(KIND.cursor, cursorPayload(shown));
        else void this.#state({ cursor: shown });
      });
    }
    // A desktop's windows, and the one shown alone: the viewer's tabs (the user, 2026-11-13: 「远程控制也支持按窗口查看」).
    if (this.view.watchWindows) {
      this.#unwindows = this.view.watchWindows((w) => {
        if (!this.#closed) void this.#state({ windows: w.windows, window: w.window });
      });
    }
    // How a simulator's picture is turned: its case is drawn turned with it.
    if (this.view.watchTurn) {
      this.#unturn = this.view.watchTurn((turn) => {
        if (!this.#closed) void this.#state({ turn });
      });
    }
    // The display's scale, to a person who drives it (a source whose scale is changed: Windows' desktop).
    if (this.control && this.source.scale) {
      void this.source.scale().then((scale) => {
        if (scale !== null && !this.#closed) void this.#state({ scale });
      });
    }
    // Its media volume, to a person who drives it (a source whose volume is read: an Android device's).
    if (this.control && this.source.volume) {
      void this.source.volume().then((volume) => {
        if (volume !== null && !this.#closed) void this.#state({ volume });
      }, () => {});
    }
    // Its resolution too (a source whose resolution is changed: Windows' desktop, the Mac's).
    if (this.control && this.source.resolution) {
      void this.source.resolution().then((resolution) => {
        if (resolution !== null && !this.#closed) void this.#state({ resolution });
      });
    }
    void this.stream.stopped().then(
      () => this.#stop(null),
      () => this.#stop(null),
    );
    void this.#read();
    if (this.audio && this.view.nextAudio) void this.#audio();
    // (a preview's card shows no figures)
    if (this.#conn?.paths && !this.peek) void this.#watchLoss();
    await this.#pump();
    await this.#over;
  }

  /// One audio packet in flight: network backpressure never builds an audio queue behind video. A packet is left out
  /// while the pictures wait in front of the link (`Pacer.backlogged`): the stream takes it at once whatever the link
  /// carries, and its 1.5 Mbit/s (48 kHz stereo PCM) on a link of a few hundred kbit/s held every picture seconds behind
  /// it, 88–90% of what came sound (2026-11-11, station/side/screen-net.ts AUDIO=1). None goes before the first
  /// picture's round trip is known (sound from the start made that round trip the queue's, and nothing waited past it),
  /// what comes meanwhile taken and left out: the source keeps up to 300 ms not taken (still.fail Helper's AudioPackets,
  /// stillfail-screen's AudioQueue), which would go all at once and the sound stay that far behind. Its leaving out is
  /// meant: the sound breaks up on a link too slow for it, the pictures going on. Opus (about 64 kbit/s) is not left out
  /// for the pictures: on 800 and 400 kbit/s left out so it went with gaps of 1–1.5 s, and sent always it came whole with
  /// the pictures' rate and lateness as they were (2026-11-12, AUDIO=opus). Its format is said once, as the first
  /// packet has it (Opus where the client said it decodes it and the source encodes it, else PCM). Muted on the client
  /// (`sound` 0), what comes is taken and left out the same way, so the sound is as late as before once it is on again.
  async #audio(): Promise<void> {
    let configured = false;
    // PCM's packets of digital silence in a row so far.
    let zeros = 0;
    try {
      while (!this.#closed) {
        const next = await this.view.nextAudio!();
        if (this.#closed || next === null) break;
        if (!configured) {
          await this.#send(KIND.audioConfig, Buffer.from(JSON.stringify({ codec: next.codec, sampleRate: 48000, channels: 2 })));
          configured = true;
        }
        zeros = next.codec === "pcm_s16le" && silent(next.data) ? zeros + 1 : 0;
        if (!this.#timed || !this.#soundOn || (next.codec === "pcm_s16le" && (this.pacer.backlogged() || zeros >= QUIET))) continue;
        const payload = Buffer.alloc(8 + next.data.length);
        payload.writeBigUInt64BE(BigInt(Math.round(next.ts)), 0);
        payload.set(next.data, 8);
        await this.#send(KIND.audio, payload);
      }
    } catch (error) {
      log.info("screens", "system audio ended", { error: String(error) });
    }
  }

  /// What of the link was lost, said as it changes (a share each LOSS_EVERY_MS, the same not said again): sampled whether
  /// or not the client's acknowledgements come, so a link that loses most of what goes is said so while nothing comes.
  async #watchLoss(): Promise<void> {
    while (!this.#closed) {
      await Promise.race([this.#sleep(LOSS_EVERY_MS), this.#over]); // timer: a sample of this machine (the connection's packet counters)
      if (this.#closed) return;
      const loss = this.loss.step(this.#conn?.paths?.() ?? []);
      if (loss !== null) {
        this.pacer.setLoss(loss);
        void this.#state({ loss });
      }
    }
  }

  /// The source asked for the bit rate the link carries, when it changed by more than a little; and for as small a
  /// picture as that rate makes sharpest (a source that changes its size).
  #pace() {
    const rate = this.pacer.rate();
    if (rate === null || !this.view.rate) return;
    if (this.#rate === null || Math.abs(rate - this.#rate) >= this.#rate * 0.05) {
      this.#rate = rate;
      this.view.rate(Math.round(rate));
    }
    if (this.#size && this.view.bounds) {
      const bounds = this.sizer.step(rate, this.pacer.through(), this.#size);
      if (bounds) this.#bounds(bounds);
    }
  }

  /// The source asked for its pictures in these bounds, of the part of the screen looked at (where it frames parts).
  #bounds(b: { maxWidth: number; maxHeight: number }) {
    if (!this.view.bounds) return;
    if (this.#region !== null) this.view.bounds(b.maxWidth, b.maxHeight, this.#region);
    else this.view.bounds(b.maxWidth, b.maxHeight);
  }

  /// The client looks at a part of the screen (or the whole again): a source that frames parts frames it, as large as
  /// asked (a config first, saying which part); one that does not goes on with the whole screen, which the client
  /// draws as it did.
  #look(look: { region: Region | null; maxWidth: number; maxHeight: number }) {
    if (!this.view.bounds || this.view.regions?.() !== true) return;
    if (JSON.stringify(look) === JSON.stringify({ region: this.#region, ...this.sizer.asked })) return;
    this.#region = look.region;
    this.#bounds(this.sizer.ask({ maxWidth: look.maxWidth, maxHeight: look.maxHeight }));
  }

  /// Frames out, while the client keeps up.
  async #pump() {
    while (!this.#closed) {
      if (!this.pacer.may()) {
        this.#pace();
        await new Promise<void>((resolve) => (this.#wake = resolve));
        continue;
      }
      // No sooner than the 帧率 asked lets it (the source asked it too, where it captures at a rate).
      const wait = this.pacer.wait();
      if (wait > 0) {
        // (woken as the view ends, too)
        await new Promise<void>((resolve) => {
          this.#wake = resolve;
          void this.#sleep(wait).then(resolve);
        });
        continue;
      }
      let next: Frame | null;
      try {
        const ahead = this.#ahead;
        this.#ahead = null;
        next = await (ahead ?? this.view.next());
      } catch (error) {
        if (error instanceof ScreenRefused) {
          this.#stop(accessShown(error.access, this.#lang)?.message ?? tr(this.#lang, error.key, error.args));
          return;
        }
        log.warn("screens", "a screen's frame was not had", { screen: this.id, error: (error as Error).message });
        next = null;
      }
      if (this.#closed) return;
      if (next === null) {
        // Its source gone or going (a tab closed, a simulator shut down): over for good. A desktop does not go while
        // its station runs, so its capture ending (a Linux desktop's ffmpeg or portal helper exiting) is said with its
        // words, the view to be opened again, never "gone" (the app's 此屏幕已不存在 with no way on).
        if (this.hub.get(this.id) !== this.source || this.source.kind !== "desktop") return this.#stop("gone");
        const why = this.view.why?.() ?? "";
        log.warn("screens", "a screen's capture ended", { screen: this.id, why });
        return this.#stop(tr(this.#lang, "station.screen.captureEnded", { said: why || tr(this.#lang, "station.screen.captureEndedUnsaid") }));
      }
      if (next.config) {
        this.#jpeg = next.config.codec === "jpeg";
        if (next.config.codec !== "jpeg") {
          // A preview (a card, two pictures a second) no higher than the source's own.
          this.pacer.ceiling(this.peek ? ownRate(next.config.width, next.config.height) : rateCeiling(next.config.width, next.config.height, this.quality, this.fps));
          this.pacer.setSize(next.config.width, next.config.height);
          this.#size = { width: next.config.width, height: next.config.height };
        } else if (!this.peek && this.view.rate) {
          this.pacer.ceiling(JPEG_RATE_CEILING);
        }
        void this.#send(KIND.config, configPayload(next.config));
      }
      this.pacer.sent(next.ts, next.data.length, next.key);
      this.latency.sent(next.ts);
      // The next frame asked of the source as this one is written, where the pace would let it go (one at most, going
      // no sooner than the pace lets it): its capture and encoding are not left to wait for the writing, nor for the
      // 帧率's slot (an encoder at 2K takes much of a 120 a second's 8 ms). What it has not given by the time the view
      // ends is let be.
      if (!this.#closed && this.pacer.free()) {
        const ahead = this.view.next();
        ahead.catch(() => {});
        this.#ahead = ahead;
      }
      await this.#send(KIND.video, videoPayload(next));
      this.#still(next.key);
      // A screen that keeps changing: gently refresh a key frame only when the link is healthy, cooled down, and the
      // previous key frame was encoded below SHARPEN_LOW_RATIO of the recovered rate.
      if (!this.#closed && !this.#jpeg && this.view.rate && this.#sharpen.dueMoving(this.#now(), this.#rate, this.pacer.healthy())) this.view.keyframe();
    }
  }

  /// What the client asks of the source, after what it asked before (a paste comes after the keys before it); unsent
  /// pointer moves of the same buttons coalesce to the latest so a slow dispatch never builds a move backlog ahead of a click.
  #then(f: () => Promise<void>, move: number | null = null) {
    if (move !== null) {
      if (this.#pendingMove !== null && this.#pendingMove.buttons === move) {
        this.#pendingMove.run = f;
        return;
      }
      const slot = { buttons: move, run: f };
      this.#pendingMove = slot;
      this.#inputs = this.#inputs
        .then(() => {
          if (this.#pendingMove === slot) this.#pendingMove = null;
          return slot.run();
        })
        .catch((error) => log.info("screens", "input not posted", { screen: this.id, error: (error as Error).message }));
      return;
    }
    this.#pendingMove = null;
    this.#inputs = this.#inputs.then(f).catch((error) => log.info("screens", "input not posted", { screen: this.id, error: (error as Error).message }));
  }

  /// What the client says, until it finishes.
  async #read() {
    try {
      for (;;) {
        const got = await this.frames.next();
        if (this.#closed) return;
        if (got === null) return this.#stop("finished");
        switch (got.kind) {
          case KIND.ack: {
            if (got.payload.length < 8) break;
            const acked = Number(got.payload.readBigUInt64BE(0));
            const waitUs = got.payload.length >= 12 ? got.payload.readUInt32BE(8) : 0;
            this.pacer.acked(acked, waitUs / 1000);
            if (this.pacer.rtt() !== null) this.#timed = true;
            this.latency.acked(acked, this.pacer.rtt() ?? 0);
            const latency = this.latency.take();
            if (latency) void this.#state({ latency });
            this.#pace();
            this.#wake();
            break;
          }
          case KIND.keyframe:
            this.pacer.lost();
            this.latency.lost();
            this.#pace();
            this.view.keyframe();
            this.#wake();
            break;
          case KIND.sound:
            if (got.payload.length === 1) this.#soundOn = got.payload[0] !== 0;
            break;
          case KIND.micOn:
            if (this.control && got.payload.length === 1) this.#micOn = got.payload[0] === 1;
            break;
          case KIND.mic: {
            // Only a driver's, shared, while something records the virtual microphone in the epoch the packet says.
            const mic = parseMic(got.payload);
            if (mic === null || !this.control || !this.#micOn || this.#mic?.active !== true || mic.epoch !== this.#mic.epoch >>> 0) break;
            this.view.feedMic?.(mic.pcm, mic.epoch);
            break;
          }
          case KIND.look: {
            const look = parseLook(got.payload, this.#own);
            if (look !== null) this.#look(look);
            break;
          }
          case KIND.input: {
            let raw: unknown = null;
            try {
              raw = JSON.parse(got.payload.toString("utf8"));
            } catch {}
            // A window shown alone, or the whole display again: this view's own, looking or driving (`{t: "window", id}`).
            const shown = parseWindowPick(raw);
            if (shown !== undefined) {
              if (this.view.window) this.#then(async () => this.view.window!(shown));
              break;
            }
            if (!this.control) break;
            const percent = parseScale(raw);
            if (percent !== null) {
              const source = this.source;
              if (source.setScale) {
                this.#then(() =>
                  source.setScale!(percent).then(
                    (scale) => void this.#state({ scale }),
                    (error) => log.info("screens", "the display's scale was not set", { screen: this.id, percent, error: (error as Error).message }),
                  ),
                );
              }
              break;
            }
            const size = parseResolution(raw);
            if (size !== null) {
              const source = this.source;
              if (source.setResolution) {
                this.#then(() =>
                  source.setResolution!(size.width, size.height).then(
                    (resolution) => void this.#state({ resolution }),
                    (error) => log.info("screens", "the display's resolution was not set", { screen: this.id, ...size, error: (error as Error).message }),
                  ),
                );
              }
              break;
            }
            const level = parseVolume(raw);
            if (level !== undefined) {
              const source = this.source;
              if (level === null && source.volume) {
                this.#then(() => source.volume!().then((volume) => void (volume !== null && this.#state({ volume })), () => {}));
              } else if (level !== null && source.setVolume) {
                this.#then(() =>
                  source.setVolume!(level).then(
                    (volume) => void this.#state({ volume }),
                    (error) => log.info("screens", "the device's volume was not set", { screen: this.id, level, error: (error as Error).message }),
                  ),
                );
              }
              break;
            }
            const reveal = parseReveal(raw);
            if (reveal !== null) {
              if (this.source.reveal && this.view.reveal) this.#then(() => this.view.reveal!(reveal));
              break;
            }
            const fill = parseFill(raw);
            if (fill !== null) {
              // Only a view that drives it fills it.
              if (this.control && this.view.fill) this.#then(() => this.view.fill!(fill));
              break;
            }
            const passkey = parsePasskey(raw);
            if (passkey !== null) {
              if (this.control && this.view.passkey) this.#then(() => this.view.passkey!(passkey));
              break;
            }
            const e = parseInput(raw);
            if (e !== null) {
              if (e.t === "pointer") this.#pointer = e;
              else if (e.t === "gamepad") {
                if (e.connected) this.#pads.add(e.index);
                else this.#pads.delete(e.index);
              } else if (e.t === "key" && e.kind === "down") this.#keys.set(e.code || e.key, e);
              else if (e.t === "key") this.#keys.delete(e.code || e.key);
              // (relative moves add up, none coalesced away)
              this.#then(() => this.view.input(e), e.t === "pointer" && e.kind === "move" && e.relative !== true ? e.buttons : null);
            }
            break;
          }
          case KIND.setClipboard: {
            // Only a view that drives it sets it, of a type the source carries, within bounds.
            if (!this.control || !this.view.setClipboard) break;
            const asked = parseClip(got.payload);
            if (asked === null || !(this.source.clipboard?.() ?? []).includes(asked.clip.type)) break;
            this.#clipKnown = clipPayload(asked.clip);
            this.#then(() => this.view.setClipboard!(asked.clip, asked.paste));
            break;
          }
          // Kinds of later clients: let be.
          default:
            break;
        }
      }
    } catch {
      this.#stop(null);
    }
  }
}
